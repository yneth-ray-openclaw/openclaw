"""
Model pricing data for cost tracking.

Prices are in USD per 1M tokens. Updated periodically.
If a model isn't listed, falls back to a conservative estimate.
"""

# (input_price_per_1m, output_price_per_1m)
MODEL_COSTS: dict[str, tuple[float, float]] = {
    # Anthropic
    "claude-opus-4-6": (15.00, 75.00),
    "claude-opus-4-20250514": (15.00, 75.00),
    "claude-sonnet-4-5-20250929": (3.00, 15.00),
    "claude-sonnet-4-20250514": (3.00, 15.00),
    "claude-sonnet-3-5-20241022": (3.00, 15.00),
    "claude-3-5-haiku-20241022": (0.80, 4.00),
    "claude-3-haiku-20240307": (0.25, 1.25),
    # OpenAI
    "gpt-4o": (2.50, 10.00),
    "gpt-4o-mini": (0.15, 0.60),
    "gpt-4-turbo": (10.00, 30.00),
    "gpt-4": (30.00, 60.00),
    "gpt-3.5-turbo": (0.50, 1.50),
    "o1": (15.00, 60.00),
    "o1-mini": (3.00, 12.00),
    "o3-mini": (1.10, 4.40),
    # Google
    "gemini-2.0-flash": (0.10, 0.40),
    "gemini-1.5-flash": (0.075, 0.30),
    "gemini-1.5-pro": (1.25, 5.00),
    "gemini-2.0-pro": (1.25, 5.00),
}

# Conservative fallback for unknown models
DEFAULT_INPUT_COST_PER_1M = 3.00
DEFAULT_OUTPUT_COST_PER_1M = 15.00


def get_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    """Calculate the cost in USD for a given model and token counts."""
    costs = MODEL_COSTS.get(model)
    if costs is None:
        # Try prefix matching (e.g., "claude-opus-4-6" matches "claude-opus-4-6-...")
        for known_model, known_costs in MODEL_COSTS.items():
            if model.startswith(known_model) or known_model.startswith(model):
                costs = known_costs
                break

    if costs is None:
        input_price, output_price = DEFAULT_INPUT_COST_PER_1M, DEFAULT_OUTPUT_COST_PER_1M
    else:
        input_price, output_price = costs

    return (input_tokens * input_price + output_tokens * output_price) / 1_000_000
