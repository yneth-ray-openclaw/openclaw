"""
Rolling-window cost tracking and budget enforcement.

Tracks spending across hourly, daily, and monthly windows.
Signals tier downgrade when approaching budget limits.
"""

import asyncio
import logging
from collections import deque
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta

from cost_table import get_cost
from router_config import BudgetConfig

logger = logging.getLogger("llm-proxy.budget")


@dataclass
class CostEntry:
    timestamp: datetime
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float


class BudgetManager:
    """Tracks rolling-window spending and signals when to downgrade tiers."""

    def __init__(self, config: BudgetConfig):
        self._config = config
        self._entries: deque[CostEntry] = deque()
        self._lock = asyncio.Lock()

    async def record_cost(
        self, model: str, input_tokens: int, output_tokens: int
    ) -> float:
        """Record token usage and return the computed cost in USD."""
        cost = get_cost(model, input_tokens, output_tokens)
        entry = CostEntry(
            timestamp=datetime.now(timezone.utc),
            model=model,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cost_usd=cost,
        )
        async with self._lock:
            self._entries.append(entry)
            self._prune()
        logger.debug("Recorded cost: model=%s cost=$%.6f", model, cost)
        return cost

    def _prune(self):
        """Remove entries older than the longest window (31 days)."""
        cutoff = datetime.now(timezone.utc) - timedelta(days=31)
        while self._entries and self._entries[0].timestamp < cutoff:
            self._entries.popleft()

    def _window_spend(self, window: timedelta) -> float:
        """Sum spend within a rolling time window."""
        cutoff = datetime.now(timezone.utc) - window
        return sum(
            e.cost_usd for e in self._entries if e.timestamp >= cutoff
        )

    @property
    def hourly_spend(self) -> float:
        return self._window_spend(timedelta(hours=1))

    @property
    def daily_spend(self) -> float:
        return self._window_spend(timedelta(days=1))

    @property
    def monthly_spend(self) -> float:
        return self._window_spend(timedelta(days=30))

    def should_downgrade(self) -> bool:
        """Check if any budget window has crossed its downgrade threshold."""
        checks = [
            (self._config.hourly, self.hourly_spend),
            (self._config.daily, self.daily_spend),
            (self._config.monthly, self.monthly_spend),
        ]
        for window_config, spend in checks:
            if window_config is None:
                continue
            threshold = window_config.limit_usd * window_config.downgrade_at_pct / 100
            if spend >= threshold:
                return True
        return False

    def is_warning(self) -> bool:
        """Check if any budget window has crossed its warning threshold."""
        checks = [
            (self._config.hourly, self.hourly_spend),
            (self._config.daily, self.daily_spend),
            (self._config.monthly, self.monthly_spend),
        ]
        for window_config, spend in checks:
            if window_config is None:
                continue
            threshold = window_config.limit_usd * window_config.warn_at_pct / 100
            if spend >= threshold:
                return True
        return False

    def is_over_budget(self) -> bool:
        """Check if any budget window has exceeded its limit."""
        checks = [
            (self._config.hourly, self.hourly_spend),
            (self._config.daily, self.daily_spend),
            (self._config.monthly, self.monthly_spend),
        ]
        for window_config, spend in checks:
            if window_config is None:
                continue
            if spend >= window_config.limit_usd:
                return True
        return False

    @property
    def over_budget_action(self) -> str:
        return self._config.over_budget_action

    @property
    def downgrade_steps(self) -> int:
        return self._config.downgrade_steps

    def status(self) -> dict:
        """Return budget status for the /router/status endpoint."""
        result = {}
        if self._config.hourly:
            result["hourly"] = {
                "spend_usd": round(self.hourly_spend, 4),
                "limit_usd": self._config.hourly.limit_usd,
                "pct": round(self.hourly_spend / self._config.hourly.limit_usd * 100, 1)
                if self._config.hourly.limit_usd > 0 else 0,
            }
        if self._config.daily:
            result["daily"] = {
                "spend_usd": round(self.daily_spend, 4),
                "limit_usd": self._config.daily.limit_usd,
                "pct": round(self.daily_spend / self._config.daily.limit_usd * 100, 1)
                if self._config.daily.limit_usd > 0 else 0,
            }
        if self._config.monthly:
            result["monthly"] = {
                "spend_usd": round(self.monthly_spend, 4),
                "limit_usd": self._config.monthly.limit_usd,
                "pct": round(self.monthly_spend / self._config.monthly.limit_usd * 100, 1)
                if self._config.monthly.limit_usd > 0 else 0,
            }
        result["should_downgrade"] = self.should_downgrade()
        result["is_warning"] = self.is_warning()
        result["over_budget"] = self.is_over_budget()
        result["over_budget_action"] = self._config.over_budget_action
        return result


# --- Anthropic quota tracking (rate-limit headers) ---


@dataclass
class QuotaSnapshot:
    tokens_limit: int
    tokens_remaining: int
    tokens_reset: datetime
    requests_limit: int
    requests_remaining: int
    requests_reset: datetime
    updated_at: datetime


class QuotaTracker:
    """Tracks Anthropic session quota from rate-limit response headers.

    When the token quota resets soon and tokens remain, signals that the
    proxy should push requests to the highest (most capable) tier to
    maximize value before the window resets unused.
    """

    def __init__(self, push_within_minutes: int = 15):
        self._latest: QuotaSnapshot | None = None
        self._push_within_minutes = push_within_minutes

    def update(self, headers: Mapping[str, str]) -> None:
        """Update from anthropic-ratelimit-* response headers."""
        tokens_reset_raw = headers.get("anthropic-ratelimit-tokens-reset")
        if not tokens_reset_raw:
            return  # no quota headers present

        try:
            tokens_reset = datetime.fromisoformat(tokens_reset_raw)
            requests_reset_raw = headers.get("anthropic-ratelimit-requests-reset", tokens_reset_raw)
            requests_reset = datetime.fromisoformat(requests_reset_raw)

            self._latest = QuotaSnapshot(
                tokens_limit=int(headers.get("anthropic-ratelimit-tokens-limit", 0)),
                tokens_remaining=int(headers.get("anthropic-ratelimit-tokens-remaining", 0)),
                tokens_reset=tokens_reset,
                requests_limit=int(headers.get("anthropic-ratelimit-requests-limit", 0)),
                requests_remaining=int(headers.get("anthropic-ratelimit-requests-remaining", 0)),
                requests_reset=requests_reset,
                updated_at=datetime.now(timezone.utc),
            )
            logger.debug(
                "Quota updated: %d tokens remaining, resets at %s",
                self._latest.tokens_remaining,
                self._latest.tokens_reset.isoformat(),
            )
        except (ValueError, TypeError) as e:
            logger.warning("Failed to parse quota headers: %s", e)

    def should_max_push(self) -> bool:
        """True when reset is within push_within_minutes AND tokens remain."""
        if not self._latest:
            return False
        now = datetime.now(timezone.utc)
        time_until_reset = (self._latest.tokens_reset - now).total_seconds()
        minutes_left = time_until_reset / 60
        return (
            0 < minutes_left <= self._push_within_minutes
            and self._latest.tokens_remaining > 0
        )

    def status(self) -> dict:
        """Return quota status for the /router/status endpoint."""
        if not self._latest:
            return {"available": False}
        now = datetime.now(timezone.utc)
        minutes_left = (self._latest.tokens_reset - now).total_seconds() / 60
        return {
            "available": True,
            "tokens_limit": self._latest.tokens_limit,
            "tokens_remaining": self._latest.tokens_remaining,
            "tokens_reset": self._latest.tokens_reset.isoformat(),
            "requests_limit": self._latest.requests_limit,
            "requests_remaining": self._latest.requests_remaining,
            "requests_reset": self._latest.requests_reset.isoformat(),
            "minutes_until_reset": round(max(minutes_left, 0), 1),
            "should_max_push": self.should_max_push(),
            "updated_at": self._latest.updated_at.isoformat(),
        }
