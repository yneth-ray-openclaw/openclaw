"""
Request complexity classifier using RouteLLM's matrix factorization router.

Supports N tiers with N-1 descending thresholds. Tier names come from the
config's tier_order list (derived from YAML tiers keys). For example:

  thresholds: [0.8, 0.5, 0.2]
  tier_order:  [tier1, tier2, tier3, tier4]
  → score > 0.8 → tier1, > 0.5 → tier2, > 0.2 → tier3, else → tier4

Includes a heuristic pre-filter to skip ML inference for obvious cases.
Fails open: any error returns the default tier.
"""

import logging
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from router_config import ClassifierConfig

logger = logging.getLogger("llm-proxy.classifier")

_controller = None
_config: "ClassifierConfig | None" = None
_tier_order: list[str] = []


def init_classifier(config: "ClassifierConfig", tier_order: list[str]) -> bool:
    """Initialize the RouteLLM controller with the mf router.

    Args:
        config: classifier configuration (thresholds, router type, etc.)
        tier_order: ordered tier names from config (highest to lowest priority)

    Returns True if initialization succeeded, False otherwise.
    The proxy should continue without classification on failure.
    """
    global _controller, _config, _tier_order
    _config = config
    _tier_order = tier_order

    try:
        from routellm.controller import Controller

        _controller = Controller(
            routers=[config.router],
            strong_model="anthropic/claude-opus-4-6",
            weak_model="anthropic/claude-3-5-haiku-20241022",
        )
        logger.info(
            "RouteLLM classifier initialized (router=%s, %d thresholds → %d tiers)",
            config.router, len(config.thresholds), len(tier_order),
        )
        return True
    except Exception as e:
        logger.error("Failed to initialize RouteLLM classifier: %s", e)
        _controller = None
        return False


def _extract_prompt_text(body: dict) -> str:
    """Extract the last user message text for classification."""
    messages = body.get("messages", [])

    # Find the last user message
    for msg in reversed(messages):
        if msg.get("role") != "user":
            continue
        content = msg.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            # Concatenate text blocks
            texts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    texts.append(block.get("text", ""))
            return " ".join(texts)

    return ""


def _heuristic_classify(body: dict) -> str | None:
    """Return tier if confident based on heuristics, None to invoke RouteLLM.

    Skips ML inference for obviously simple or complex requests.
    Uses first tier (highest) and last tier (lowest) from _tier_order.
    """
    if not _tier_order:
        return None

    highest_tier = _tier_order[0]
    lowest_tier = _tier_order[-1]

    messages = body.get("messages", [])
    tools = body.get("tools", [])
    msg_count = len(messages)
    tool_count = len(tools)

    # Get last user message length
    last_user_len = 0
    for msg in reversed(messages):
        if msg.get("role") == "user":
            content = msg.get("content", "")
            if isinstance(content, str):
                last_user_len = len(content)
            elif isinstance(content, list):
                last_user_len = sum(
                    len(b.get("text", ""))
                    for b in content
                    if isinstance(b, dict) and b.get("type") == "text"
                )
            break

    # Short conversation, no tools, short message → simplest tier
    if msg_count <= 3 and tool_count == 0 and last_user_len < 200:
        return lowest_tier

    # Many messages or many tools → highest tier
    if msg_count > 20 or tool_count > 5:
        return highest_tier

    # Extended thinking requested → highest tier
    if body.get("thinking") or body.get("extended_thinking"):
        return highest_tier

    return None  # needs RouteLLM classification


def classify_request(body: dict, default_tier: str = "tier1") -> str:
    """Classify a request into one of N tiers using N-1 thresholds.

    Thresholds are descending. For each threshold[i], if score > threshold[i],
    the request maps to tier_order[i]. If score is below all thresholds,
    it maps to tier_order[-1] (the lowest tier).

    Uses heuristic pre-filter first, then RouteLLM if needed.
    Returns default_tier on any error (fail-open).
    """
    if _config is None or not _tier_order:
        return default_tier

    # Heuristic pre-filter
    if _config.heuristic_bypass:
        heuristic_result = _heuristic_classify(body)
        if heuristic_result is not None:
            logger.debug("Heuristic classified as %s", heuristic_result)
            return heuristic_result

    # RouteLLM classification
    if _controller is None:
        logger.debug("No RouteLLM controller, using default tier")
        return default_tier

    try:
        prompt = _extract_prompt_text(body)
        if not prompt:
            return default_tier

        # Get the router's win-rate score (0-1, higher = needs stronger model)
        router = _controller.routers[_config.router]
        score = router.calculate_strong_win_rate(prompt)

        # Walk thresholds: first threshold exceeded → that tier
        tier = _tier_order[-1]  # default to lowest
        for i, threshold in enumerate(_config.thresholds):
            if score > threshold:
                tier = _tier_order[i]
                break

        logger.info("RouteLLM score=%.3f → %s", score, tier)
        return tier

    except Exception as e:
        logger.warning("RouteLLM classification failed: %s — using %s", e, default_tier)
        return default_tier


def classifier_status() -> dict:
    """Return classifier status for the /router/status endpoint."""
    return {
        "initialized": _controller is not None,
        "router": _config.router if _config else None,
        "thresholds": _config.thresholds if _config else [],
        "tier_order": _tier_order,
        "heuristic_bypass": _config.heuristic_bypass if _config else None,
    }
