"""
YAML configuration loader for the smart LLM router.

Loads router-config.yaml with ${ENV_VAR} interpolation and validates
the structure into typed dataclasses.
"""

import logging
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

logger = logging.getLogger("llm-proxy.config")

_ENV_VAR_PATTERN = re.compile(r"\$\{([^}]+)\}")


def _interpolate_env(value: str) -> str:
    """Replace ${ENV_VAR} placeholders with environment variable values."""
    def replacer(match: re.Match) -> str:
        var_name = match.group(1)
        env_val = os.environ.get(var_name, "")
        if not env_val:
            logger.warning("Environment variable %s is not set", var_name)
        return env_val
    return _ENV_VAR_PATTERN.sub(replacer, value)


def _interpolate_recursive(obj):
    """Recursively interpolate env vars in strings within dicts/lists."""
    if isinstance(obj, str):
        return _interpolate_env(obj)
    if isinstance(obj, dict):
        return {k: _interpolate_recursive(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_interpolate_recursive(item) for item in obj]
    return obj


@dataclass
class ProviderConfig:
    name: str
    type: str  # "anthropic" or "openai"
    base_url: str
    api_key: str


@dataclass
class TierModel:
    provider: str
    model: str
    extra_params: dict | None = None  # e.g. {"max_tokens": 1024, "thinking": {"budget_tokens": 5000}}


@dataclass
class ClassifierConfig:
    router: str = "mf"
    # Descending thresholds: [0.7, 0.3] with tiers [t1, t2, t3] means
    # score > 0.7 → t1, score > 0.3 → t2, else → t3.
    # N-1 thresholds for N tiers.
    thresholds: list[float] = field(default_factory=lambda: [0.7, 0.3])
    heuristic_bypass: bool = True


@dataclass
class BudgetWindow:
    limit_usd: float
    warn_at_pct: int = 80
    downgrade_at_pct: int = 90


@dataclass
class BudgetConfig:
    hourly: BudgetWindow | None = None
    daily: BudgetWindow | None = None
    monthly: BudgetWindow | None = None
    downgrade_steps: int = 1
    over_budget_action: str = "allow"  # "allow" | "reject"


@dataclass
class RouterConfig:
    enabled: bool = True
    providers: dict[str, ProviderConfig] = field(default_factory=dict)
    classifier: ClassifierConfig = field(default_factory=ClassifierConfig)
    tiers: dict[str, list[TierModel]] = field(default_factory=dict)
    tier_order: list[str] = field(default_factory=list)  # derived from tiers keys, highest→lowest
    budgets: BudgetConfig = field(default_factory=BudgetConfig)
    default_tier: str = "tier1"


def _parse_provider(name: str, raw: dict) -> ProviderConfig:
    return ProviderConfig(
        name=name,
        type=raw.get("type", "openai"),
        base_url=raw.get("base_url", "").rstrip("/"),
        api_key=raw.get("api_key", ""),
    )


def _parse_classifier(raw: dict) -> ClassifierConfig:
    # Support both new list format and legacy two-threshold format
    if "thresholds" in raw:
        thresholds = [float(t) for t in raw["thresholds"]]
    else:
        # Legacy: tier1_threshold / tier3_threshold → [t1, t3]
        thresholds = [
            float(raw.get("tier1_threshold", 0.7)),
            float(raw.get("tier3_threshold", 0.3)),
        ]
    return ClassifierConfig(
        router=raw.get("router", "mf"),
        thresholds=thresholds,
        heuristic_bypass=raw.get("heuristic_bypass", True),
    )


def _parse_budget_window(raw: dict) -> BudgetWindow:
    return BudgetWindow(
        limit_usd=float(raw["limit_usd"]),
        warn_at_pct=int(raw.get("warn_at_pct", 80)),
        downgrade_at_pct=int(raw.get("downgrade_at_pct", 90)),
    )


def _parse_budgets(raw: dict) -> BudgetConfig:
    config = BudgetConfig(
        downgrade_steps=int(raw.get("downgrade_steps", 1)),
        over_budget_action=raw.get("over_budget_action", "allow"),
    )
    if "hourly" in raw and isinstance(raw["hourly"], dict):
        config.hourly = _parse_budget_window(raw["hourly"])
    if "daily" in raw and isinstance(raw["daily"], dict):
        config.daily = _parse_budget_window(raw["daily"])
    if "monthly" in raw and isinstance(raw["monthly"], dict):
        config.monthly = _parse_budget_window(raw["monthly"])
    return config


def _parse_tiers(raw: dict) -> dict[str, list[TierModel]]:
    tiers = {}
    for tier_name, models in raw.items():
        if not isinstance(models, list):
            continue
        parsed = []
        for m in models:
            if not isinstance(m, dict) or "provider" not in m or "model" not in m:
                continue
            extra = m.get("extra_params")
            parsed.append(TierModel(
                provider=m["provider"],
                model=m["model"],
                extra_params=extra if isinstance(extra, dict) else None,
            ))
        tiers[tier_name] = parsed
    return tiers


def load_config(config_path: str | None = None) -> RouterConfig | None:
    """Load and validate router configuration from YAML file.

    Returns None if the config file doesn't exist or is invalid,
    allowing the proxy to fall back to legacy mode.
    """
    if config_path is None:
        config_path = os.environ.get(
            "ROUTER_CONFIG_PATH", "/app/router-config.yaml"
        )

    path = Path(config_path)
    if not path.exists():
        logger.info("Router config not found at %s — smart routing disabled", config_path)
        return None

    try:
        with open(path) as f:
            raw = yaml.safe_load(f)
    except Exception as e:
        logger.error("Failed to parse router config %s: %s", config_path, e)
        return None

    if not isinstance(raw, dict):
        logger.error("Router config must be a YAML mapping")
        return None

    # Interpolate environment variables
    raw = _interpolate_recursive(raw)

    try:
        config = RouterConfig(
            enabled=raw.get("enabled", True),
            default_tier=raw.get("default_tier", "tier1"),
        )

        # Parse providers
        for name, prov_raw in raw.get("providers", {}).items():
            if isinstance(prov_raw, dict):
                config.providers[name] = _parse_provider(name, prov_raw)

        # Parse classifier
        if "classifier" in raw and isinstance(raw["classifier"], dict):
            config.classifier = _parse_classifier(raw["classifier"])

        # Parse tiers
        if "tiers" in raw and isinstance(raw["tiers"], dict):
            config.tiers = _parse_tiers(raw["tiers"])

        # Parse budgets
        if "budgets" in raw and isinstance(raw["budgets"], dict):
            config.budgets = _parse_budgets(raw["budgets"])

        # Derive tier_order from tiers keys (preserves YAML insertion order)
        config.tier_order = list(config.tiers.keys())

        # Validate: thresholds count must be len(tiers) - 1
        expected_thresholds = max(len(config.tier_order) - 1, 0)
        if len(config.classifier.thresholds) != expected_thresholds:
            logger.warning(
                "Classifier has %d thresholds but %d tiers (expected %d thresholds) "
                "— classification may not cover all tiers",
                len(config.classifier.thresholds),
                len(config.tier_order),
                expected_thresholds,
            )

        # Validate: all tier models reference known providers
        for tier_name, models in config.tiers.items():
            for tm in models:
                if tm.provider not in config.providers:
                    logger.warning(
                        "Tier %s references unknown provider %s",
                        tier_name, tm.provider,
                    )

        logger.info(
            "Router config loaded: %d providers, %d tiers (%s), classifier=%s",
            len(config.providers), len(config.tiers),
            " → ".join(config.tier_order), config.classifier.router,
        )
        return config

    except Exception as e:
        logger.error("Failed to build router config: %s", e)
        return None


def resolve_target(
    config: RouterConfig,
    tier: str,
    exclude_providers: set[str] | None = None,
) -> tuple[ProviderConfig, str, dict | None] | None:
    """Pick the first available provider+model for the given tier.

    Skips providers in exclude_providers (used for fallback after failures).
    Returns (provider_config, model_name, extra_params) or None.
    """
    exclude = exclude_providers or set()
    models = config.tiers.get(tier, [])
    for tm in models:
        if tm.provider in exclude:
            continue
        provider = config.providers.get(tm.provider)
        if provider and provider.api_key:
            return provider, tm.model, tm.extra_params
    return None


def downgrade_tier(config: RouterConfig, tier: str, steps: int = 1) -> str:
    """Move a tier down by the given number of steps using the config's tier order.

    Cannot go below the last tier. If tier is unknown, returns it unchanged.
    """
    order = config.tier_order
    if not order:
        return tier
    try:
        idx = order.index(tier)
    except ValueError:
        return tier
    new_idx = min(idx + steps, len(order) - 1)
    return order[new_idx]


def lowest_tier(config: RouterConfig) -> str:
    """Return the lowest (cheapest) tier name."""
    if config.tier_order:
        return config.tier_order[-1]
    return config.default_tier
