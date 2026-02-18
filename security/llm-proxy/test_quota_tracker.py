"""Tests for QuotaTracker and related config parsing."""

import sys
import os
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

import pytest

# Ensure the llm-proxy directory is on the path so bare imports work
sys.path.insert(0, os.path.dirname(__file__))

from budget import QuotaTracker, QuotaSnapshot


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_headers(
    tokens_remaining: int = 50000,
    tokens_limit: int = 100000,
    tokens_reset: datetime | None = None,
    requests_remaining: int = 100,
    requests_limit: int = 200,
    requests_reset: datetime | None = None,
) -> dict[str, str]:
    """Build a dict that mimics Anthropic rate-limit response headers."""
    now = datetime.now(timezone.utc)
    if tokens_reset is None:
        tokens_reset = now + timedelta(minutes=10)
    if requests_reset is None:
        requests_reset = tokens_reset
    return {
        "anthropic-ratelimit-tokens-limit": str(tokens_limit),
        "anthropic-ratelimit-tokens-remaining": str(tokens_remaining),
        "anthropic-ratelimit-tokens-reset": tokens_reset.isoformat(),
        "anthropic-ratelimit-requests-limit": str(requests_limit),
        "anthropic-ratelimit-requests-remaining": str(requests_remaining),
        "anthropic-ratelimit-requests-reset": requests_reset.isoformat(),
    }


# ---------------------------------------------------------------------------
# QuotaTracker.update
# ---------------------------------------------------------------------------

class TestQuotaTrackerUpdate:
    def test_update_parses_headers(self):
        tracker = QuotaTracker()
        reset_time = datetime(2026, 3, 1, 12, 0, 0, tzinfo=timezone.utc)
        headers = _make_headers(
            tokens_remaining=42000,
            tokens_limit=100000,
            tokens_reset=reset_time,
            requests_remaining=80,
            requests_limit=200,
            requests_reset=reset_time,
        )
        tracker.update(headers)

        snap = tracker._latest
        assert snap is not None
        assert snap.tokens_remaining == 42000
        assert snap.tokens_limit == 100000
        assert snap.tokens_reset == reset_time
        assert snap.requests_remaining == 80
        assert snap.requests_limit == 200
        assert snap.requests_reset == reset_time

    def test_update_ignores_missing_headers(self):
        tracker = QuotaTracker()
        tracker.update({})  # no anthropic-ratelimit-tokens-reset
        assert tracker._latest is None

    def test_update_ignores_malformed_timestamp(self):
        tracker = QuotaTracker()
        headers = {"anthropic-ratelimit-tokens-reset": "not-a-date"}
        tracker.update(headers)
        assert tracker._latest is None

    def test_update_overwrites_previous_snapshot(self):
        tracker = QuotaTracker()
        t1 = datetime(2026, 3, 1, 12, 0, 0, tzinfo=timezone.utc)
        t2 = datetime(2026, 3, 1, 12, 30, 0, tzinfo=timezone.utc)

        tracker.update(_make_headers(tokens_remaining=1000, tokens_reset=t1))
        assert tracker._latest.tokens_remaining == 1000

        tracker.update(_make_headers(tokens_remaining=500, tokens_reset=t2))
        assert tracker._latest.tokens_remaining == 500
        assert tracker._latest.tokens_reset == t2

    def test_update_defaults_requests_reset_to_tokens_reset(self):
        """When requests-reset header is absent, fall back to tokens-reset."""
        tracker = QuotaTracker()
        reset_time = datetime(2026, 3, 1, 12, 0, 0, tzinfo=timezone.utc)
        headers = {
            "anthropic-ratelimit-tokens-limit": "100000",
            "anthropic-ratelimit-tokens-remaining": "50000",
            "anthropic-ratelimit-tokens-reset": reset_time.isoformat(),
            # no requests-reset header
            "anthropic-ratelimit-requests-limit": "200",
            "anthropic-ratelimit-requests-remaining": "100",
        }
        tracker.update(headers)
        assert tracker._latest.requests_reset == reset_time


# ---------------------------------------------------------------------------
# QuotaTracker.should_max_push
# ---------------------------------------------------------------------------

class TestShouldMaxPush:
    def test_false_when_no_snapshot(self):
        tracker = QuotaTracker(push_within_minutes=15)
        assert tracker.should_max_push() is False

    def test_true_when_reset_imminent_and_tokens_remain(self):
        tracker = QuotaTracker(push_within_minutes=15)
        reset_in_10_min = datetime.now(timezone.utc) + timedelta(minutes=10)
        tracker.update(_make_headers(tokens_remaining=5000, tokens_reset=reset_in_10_min))
        assert tracker.should_max_push() is True

    def test_false_when_reset_far_away(self):
        tracker = QuotaTracker(push_within_minutes=15)
        reset_in_60_min = datetime.now(timezone.utc) + timedelta(minutes=60)
        tracker.update(_make_headers(tokens_remaining=5000, tokens_reset=reset_in_60_min))
        assert tracker.should_max_push() is False

    def test_false_when_no_tokens_remaining(self):
        tracker = QuotaTracker(push_within_minutes=15)
        reset_in_10_min = datetime.now(timezone.utc) + timedelta(minutes=10)
        tracker.update(_make_headers(tokens_remaining=0, tokens_reset=reset_in_10_min))
        assert tracker.should_max_push() is False

    def test_false_when_reset_already_passed(self):
        tracker = QuotaTracker(push_within_minutes=15)
        reset_in_past = datetime.now(timezone.utc) - timedelta(minutes=5)
        tracker.update(_make_headers(tokens_remaining=5000, tokens_reset=reset_in_past))
        assert tracker.should_max_push() is False

    def test_boundary_exactly_at_push_window(self):
        """Reset exactly at push_within_minutes should trigger."""
        tracker = QuotaTracker(push_within_minutes=15)
        # Use 14.9 minutes to avoid float precision issues at the exact boundary
        reset_at_boundary = datetime.now(timezone.utc) + timedelta(minutes=14, seconds=54)
        tracker.update(_make_headers(tokens_remaining=100, tokens_reset=reset_at_boundary))
        assert tracker.should_max_push() is True

    def test_boundary_just_outside_push_window(self):
        tracker = QuotaTracker(push_within_minutes=15)
        reset_just_outside = datetime.now(timezone.utc) + timedelta(minutes=15, seconds=10)
        tracker.update(_make_headers(tokens_remaining=100, tokens_reset=reset_just_outside))
        assert tracker.should_max_push() is False

    def test_custom_push_window(self):
        tracker = QuotaTracker(push_within_minutes=5)
        reset_in_3_min = datetime.now(timezone.utc) + timedelta(minutes=3)
        tracker.update(_make_headers(tokens_remaining=1000, tokens_reset=reset_in_3_min))
        assert tracker.should_max_push() is True

        reset_in_10_min = datetime.now(timezone.utc) + timedelta(minutes=10)
        tracker.update(_make_headers(tokens_remaining=1000, tokens_reset=reset_in_10_min))
        assert tracker.should_max_push() is False


# ---------------------------------------------------------------------------
# QuotaTracker.status
# ---------------------------------------------------------------------------

class TestQuotaTrackerStatus:
    def test_status_when_no_snapshot(self):
        tracker = QuotaTracker()
        status = tracker.status()
        assert status == {"available": False}

    def test_status_with_snapshot(self):
        tracker = QuotaTracker(push_within_minutes=15)
        reset_time = datetime.now(timezone.utc) + timedelta(minutes=10)
        tracker.update(_make_headers(
            tokens_remaining=42000,
            tokens_limit=100000,
            tokens_reset=reset_time,
            requests_remaining=80,
            requests_limit=200,
        ))
        status = tracker.status()

        assert status["available"] is True
        assert status["tokens_remaining"] == 42000
        assert status["tokens_limit"] == 100000
        assert status["requests_remaining"] == 80
        assert status["requests_limit"] == 200
        assert status["should_max_push"] is True
        assert 0 < status["minutes_until_reset"] <= 15
        assert "tokens_reset" in status
        assert "updated_at" in status

    def test_status_minutes_until_reset_not_negative(self):
        tracker = QuotaTracker()
        past_reset = datetime.now(timezone.utc) - timedelta(minutes=5)
        tracker.update(_make_headers(tokens_remaining=100, tokens_reset=past_reset))
        status = tracker.status()
        assert status["minutes_until_reset"] == 0


# ---------------------------------------------------------------------------
# BudgetConfig parsing (max_push fields)
# ---------------------------------------------------------------------------

class TestBudgetConfigParsing:
    def test_parse_budgets_with_max_push_fields(self):
        from router_config import _parse_budgets

        raw = {
            "hourly": {"limit_usd": 5.0},
            "downgrade_steps": 2,
            "over_budget_action": "reject",
            "max_push_within_minutes": 20,
            "max_push_tier": "tier1",
        }
        config = _parse_budgets(raw)
        assert config.max_push_within_minutes == 20
        assert config.max_push_tier == "tier1"
        assert config.downgrade_steps == 2
        assert config.over_budget_action == "reject"

    def test_parse_budgets_defaults_max_push_fields(self):
        from router_config import _parse_budgets

        raw = {"hourly": {"limit_usd": 5.0}}
        config = _parse_budgets(raw)
        assert config.max_push_within_minutes == 15
        assert config.max_push_tier == ""

    def test_budget_config_dataclass_defaults(self):
        from router_config import BudgetConfig

        config = BudgetConfig()
        assert config.max_push_within_minutes == 15
        assert config.max_push_tier == ""


# ---------------------------------------------------------------------------
# Validation against official Anthropic API header format
# (per https://docs.anthropic.com/en/api/rate-limits#response-headers)
# ---------------------------------------------------------------------------

class TestAnthropicAPIHeaderFormat:
    """Validate parsing against realistic Anthropic API responses.

    Official docs state:
    - Timestamps are RFC 3339 format (e.g. "2026-02-18T12:30:00Z")
    - tokens-remaining is "rounded to the nearest thousand"
    - Token bucket algorithm: reset = when bucket is fully replenished
    - Additional input-tokens/output-tokens headers may be present
    """

    def test_rfc3339_z_suffix_timestamp(self):
        """Anthropic returns timestamps with 'Z' suffix (UTC in RFC 3339)."""
        tracker = QuotaTracker(push_within_minutes=15)
        headers = {
            "anthropic-ratelimit-tokens-limit": "100000",
            "anthropic-ratelimit-tokens-remaining": "80000",
            "anthropic-ratelimit-tokens-reset": "2026-03-01T12:00:00Z",
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "950",
            "anthropic-ratelimit-requests-reset": "2026-03-01T12:00:00Z",
        }
        tracker.update(headers)
        snap = tracker._latest
        assert snap is not None
        assert snap.tokens_reset == datetime(2026, 3, 1, 12, 0, 0, tzinfo=timezone.utc)

    def test_rfc3339_offset_timestamp(self):
        """Some RFC 3339 timestamps use +00:00 instead of Z."""
        tracker = QuotaTracker()
        headers = {
            "anthropic-ratelimit-tokens-limit": "100000",
            "anthropic-ratelimit-tokens-remaining": "80000",
            "anthropic-ratelimit-tokens-reset": "2026-03-01T12:00:00+00:00",
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "950",
            "anthropic-ratelimit-requests-reset": "2026-03-01T12:00:00+00:00",
        }
        tracker.update(headers)
        assert tracker._latest is not None
        assert tracker._latest.tokens_reset == datetime(2026, 3, 1, 12, 0, 0, tzinfo=timezone.utc)

    def test_rfc3339_with_fractional_seconds(self):
        """RFC 3339 allows fractional seconds."""
        tracker = QuotaTracker()
        headers = {
            "anthropic-ratelimit-tokens-limit": "100000",
            "anthropic-ratelimit-tokens-remaining": "80000",
            "anthropic-ratelimit-tokens-reset": "2026-03-01T12:00:00.123456Z",
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "950",
            "anthropic-ratelimit-requests-reset": "2026-03-01T12:00:00.123456Z",
        }
        tracker.update(headers)
        assert tracker._latest is not None
        assert tracker._latest.tokens_reset.year == 2026

    def test_realistic_tier2_headers(self):
        """Simulate a Tier 2 Sonnet response with realistic values.

        Tier 2 Sonnet: 1,000 RPM, 450,000 ITPM, 90,000 OTPM.
        tokens-remaining is rounded to nearest thousand per docs.
        """
        tracker = QuotaTracker(push_within_minutes=15)
        reset_soon = datetime.now(timezone.utc) + timedelta(minutes=8)
        headers = {
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "985",
            "anthropic-ratelimit-requests-reset": reset_soon.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "anthropic-ratelimit-tokens-limit": "450000",
            "anthropic-ratelimit-tokens-remaining": "423000",  # rounded to nearest 1000
            "anthropic-ratelimit-tokens-reset": reset_soon.strftime("%Y-%m-%dT%H:%M:%SZ"),
            # Additional granular headers Anthropic sends (we don't use these but
            # they should not interfere with parsing)
            "anthropic-ratelimit-input-tokens-limit": "450000",
            "anthropic-ratelimit-input-tokens-remaining": "430000",
            "anthropic-ratelimit-input-tokens-reset": reset_soon.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "anthropic-ratelimit-output-tokens-limit": "90000",
            "anthropic-ratelimit-output-tokens-remaining": "88000",
            "anthropic-ratelimit-output-tokens-reset": reset_soon.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        tracker.update(headers)

        snap = tracker._latest
        assert snap is not None
        assert snap.tokens_limit == 450000
        assert snap.tokens_remaining == 423000
        assert snap.requests_limit == 1000
        assert snap.requests_remaining == 985
        # Reset is ~8 min away, within 15 min window, tokens remain → should push
        assert tracker.should_max_push() is True

    def test_realistic_tier4_headers_far_from_reset(self):
        """Tier 4 with plenty of time remaining — should NOT push."""
        tracker = QuotaTracker(push_within_minutes=15)
        reset_far = datetime.now(timezone.utc) + timedelta(minutes=55)
        headers = {
            "anthropic-ratelimit-requests-limit": "4000",
            "anthropic-ratelimit-requests-remaining": "3800",
            "anthropic-ratelimit-requests-reset": reset_far.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "anthropic-ratelimit-tokens-limit": "2000000",
            "anthropic-ratelimit-tokens-remaining": "1850000",
            "anthropic-ratelimit-tokens-reset": reset_far.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        tracker.update(headers)

        assert tracker._latest is not None
        assert tracker._latest.tokens_limit == 2000000
        assert tracker.should_max_push() is False

    def test_rate_limited_response_zero_remaining(self):
        """When fully rate-limited (0 remaining), should NOT push even if reset is soon."""
        tracker = QuotaTracker(push_within_minutes=15)
        reset_soon = datetime.now(timezone.utc) + timedelta(minutes=2)
        headers = {
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "0",
            "anthropic-ratelimit-requests-reset": reset_soon.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "anthropic-ratelimit-tokens-limit": "450000",
            "anthropic-ratelimit-tokens-remaining": "0",
            "anthropic-ratelimit-tokens-reset": reset_soon.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        tracker.update(headers)
        assert tracker.should_max_push() is False

    def test_extra_headers_do_not_interfere(self):
        """Unrelated response headers mixed in should be ignored."""
        tracker = QuotaTracker()
        reset = datetime.now(timezone.utc) + timedelta(minutes=10)
        headers = {
            "content-type": "text/event-stream",
            "x-request-id": "req_abc123",
            "retry-after": "30",
            "anthropic-ratelimit-tokens-limit": "100000",
            "anthropic-ratelimit-tokens-remaining": "90000",
            "anthropic-ratelimit-tokens-reset": reset.isoformat(),
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "999",
            "anthropic-ratelimit-requests-reset": reset.isoformat(),
        }
        tracker.update(headers)
        assert tracker._latest is not None
        assert tracker._latest.tokens_remaining == 90000

    def test_non_anthropic_provider_headers_ignored(self):
        """Headers from OpenAI-style providers (no anthropic-ratelimit-*) are silently ignored."""
        tracker = QuotaTracker()
        headers = {
            "x-ratelimit-limit-tokens": "100000",
            "x-ratelimit-remaining-tokens": "90000",
            "x-ratelimit-reset-tokens": "30s",
        }
        tracker.update(headers)
        assert tracker._latest is None
