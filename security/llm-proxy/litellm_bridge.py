"""
LiteLLM bridge for cross-provider request forwarding.

Only used when routing across different provider formats
(e.g., Anthropic client → OpenAI target). For same-provider routing,
the proxy forwards directly via httpx with zero overhead.
"""

import json
import logging
from typing import AsyncIterator

from router_config import ProviderConfig

logger = logging.getLogger("llm-proxy.litellm_bridge")

_initialized = False


def init_litellm(providers: dict[str, ProviderConfig]):
    """Configure LiteLLM with provider API keys."""
    global _initialized
    try:
        import litellm

        litellm.drop_params = True  # Drop unsupported params instead of erroring
        litellm.set_verbose = False

        # Set API keys for each provider
        for name, provider in providers.items():
            if provider.type == "anthropic" and provider.api_key:
                litellm.anthropic_key = provider.api_key
            elif provider.type == "openai" and provider.api_key:
                if "generativelanguage.googleapis.com" in provider.base_url:
                    # Google/Gemini via OpenAI-compatible API
                    pass  # Handled per-request via api_key param
                else:
                    litellm.openai_key = provider.api_key

        _initialized = True
        logger.info("LiteLLM bridge initialized")
    except Exception as e:
        logger.error("Failed to initialize LiteLLM: %s", e)
        _initialized = False


def is_initialized() -> bool:
    return _initialized


def _anthropic_to_openai_messages(body: dict) -> list[dict]:
    """Convert Anthropic message format to OpenAI format for LiteLLM."""
    messages = []

    # Anthropic system → OpenAI system message
    system = body.get("system")
    if isinstance(system, str) and system:
        messages.append({"role": "system", "content": system})
    elif isinstance(system, list):
        system_text = " ".join(
            block.get("text", "")
            for block in system
            if isinstance(block, dict) and block.get("type") == "text"
        )
        if system_text:
            messages.append({"role": "system", "content": system_text})

    # Convert message content blocks
    for msg in body.get("messages", []):
        role = msg.get("role", "user")
        content = msg.get("content", "")

        if isinstance(content, str):
            messages.append({"role": role, "content": content})
        elif isinstance(content, list):
            # Convert Anthropic content blocks to text
            text_parts = []
            for block in content:
                if isinstance(block, dict):
                    if block.get("type") == "text":
                        text_parts.append(block.get("text", ""))
                    elif block.get("type") == "tool_use":
                        # Pass tool calls through
                        messages.append({
                            "role": role,
                            "content": None,
                            "tool_calls": [{
                                "id": block.get("id", ""),
                                "type": "function",
                                "function": {
                                    "name": block.get("name", ""),
                                    "arguments": json.dumps(block.get("input", {})),
                                },
                            }],
                        })
                        continue
                    elif block.get("type") == "tool_result":
                        messages.append({
                            "role": "tool",
                            "tool_call_id": block.get("tool_use_id", ""),
                            "content": str(block.get("content", "")),
                        })
                        continue
            if text_parts:
                messages.append({"role": role, "content": " ".join(text_parts)})
        else:
            messages.append({"role": role, "content": str(content)})

    return messages


def _build_litellm_model_name(provider: ProviderConfig, model: str) -> str:
    """Build the LiteLLM model identifier (e.g., 'openai/gpt-4o-mini')."""
    if provider.type == "anthropic":
        return f"anthropic/{model}"
    elif "generativelanguage.googleapis.com" in provider.base_url:
        return f"gemini/{model}"
    else:
        return f"openai/{model}"


async def forward_streaming(
    body: dict,
    client_format: str,
    target_model: str,
    provider: ProviderConfig,
) -> AsyncIterator[bytes]:
    """Forward a request via LiteLLM with streaming, yielding SSE chunks.

    Translates the response back to the client's expected format (Anthropic SSE).
    """
    import litellm

    model_name = _build_litellm_model_name(provider, target_model)

    # Convert messages to OpenAI format (LiteLLM's native format)
    if client_format == "anthropic":
        messages = _anthropic_to_openai_messages(body)
    else:
        messages = body.get("messages", [])

    # Build LiteLLM params
    params = {
        "model": model_name,
        "messages": messages,
        "stream": True,
    }

    # Pass through common parameters
    if body.get("max_tokens"):
        params["max_tokens"] = body["max_tokens"]
    if body.get("temperature") is not None:
        params["temperature"] = body["temperature"]
    if body.get("top_p") is not None:
        params["top_p"] = body["top_p"]
    if body.get("stop"):
        params["stop"] = body["stop"]

    # Provider-specific API key and base URL
    if provider.api_key:
        params["api_key"] = provider.api_key
    if provider.base_url and provider.type == "openai":
        params["api_base"] = provider.base_url

    try:
        response = await litellm.acompletion(**params)

        if client_format == "anthropic":
            # Translate OpenAI streaming to Anthropic SSE format
            async for chunk in _openai_stream_to_anthropic_sse(response, target_model):
                yield chunk
        else:
            # Already OpenAI format, pass through
            async for chunk in response:
                chunk_dict = chunk.model_dump() if hasattr(chunk, "model_dump") else dict(chunk)
                yield f"data: {json.dumps(chunk_dict)}\n\n".encode()
            yield b"data: [DONE]\n\n"

    except Exception as e:
        logger.error("LiteLLM streaming forward failed: %s", e)
        # Yield an error event in the client's expected format
        if client_format == "anthropic":
            error_event = {
                "type": "error",
                "error": {"type": "api_error", "message": str(e)},
            }
            yield f"event: error\ndata: {json.dumps(error_event)}\n\n".encode()
        else:
            yield f'data: {{"error": "{str(e)}"}}\n\n'.encode()


async def forward_non_streaming(
    body: dict,
    client_format: str,
    target_model: str,
    provider: ProviderConfig,
) -> tuple[int, dict, bytes]:
    """Forward a request via LiteLLM without streaming.

    Returns (status_code, headers, body_bytes) translated back to client format.
    """
    import litellm

    model_name = _build_litellm_model_name(provider, target_model)

    if client_format == "anthropic":
        messages = _anthropic_to_openai_messages(body)
    else:
        messages = body.get("messages", [])

    params = {
        "model": model_name,
        "messages": messages,
        "stream": False,
    }

    if body.get("max_tokens"):
        params["max_tokens"] = body["max_tokens"]
    if body.get("temperature") is not None:
        params["temperature"] = body["temperature"]
    if body.get("top_p") is not None:
        params["top_p"] = body["top_p"]
    if body.get("stop"):
        params["stop"] = body["stop"]

    if provider.api_key:
        params["api_key"] = provider.api_key
    if provider.base_url and provider.type == "openai":
        params["api_base"] = provider.base_url

    try:
        response = await litellm.acompletion(**params)
        resp_dict = response.model_dump() if hasattr(response, "model_dump") else dict(response)

        if client_format == "anthropic":
            # Translate OpenAI response to Anthropic format
            anthropic_resp = _openai_response_to_anthropic(resp_dict, target_model)
            return 200, {"content-type": "application/json"}, json.dumps(anthropic_resp).encode()
        else:
            return 200, {"content-type": "application/json"}, json.dumps(resp_dict).encode()

    except Exception as e:
        logger.error("LiteLLM non-streaming forward failed: %s", e)
        error_body = {"error": {"type": "api_error", "message": str(e)}}
        return 502, {"content-type": "application/json"}, json.dumps(error_body).encode()


async def _openai_stream_to_anthropic_sse(
    stream, model: str
) -> AsyncIterator[bytes]:
    """Convert an OpenAI streaming response to Anthropic SSE format."""
    # Emit message_start
    message_start = {
        "type": "message_start",
        "message": {
            "id": "msg_router",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "usage": {"input_tokens": 0, "output_tokens": 0},
        },
    }
    yield f"event: message_start\ndata: {json.dumps(message_start)}\n\n".encode()

    # Emit content_block_start
    yield f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})}\n\n".encode()

    total_output_tokens = 0
    async for chunk in stream:
        chunk_dict = chunk.model_dump() if hasattr(chunk, "model_dump") else dict(chunk)
        choices = chunk_dict.get("choices", [])
        for choice in choices:
            delta = choice.get("delta", {})
            content = delta.get("content")
            if content:
                delta_event = {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": content},
                }
                yield f"event: content_block_delta\ndata: {json.dumps(delta_event)}\n\n".encode()

        # Check for usage in the chunk
        usage = chunk_dict.get("usage")
        if usage:
            total_output_tokens = usage.get("completion_tokens", 0)

    # Emit content_block_stop
    yield f"event: content_block_stop\ndata: {json.dumps({'type': 'content_block_stop', 'index': 0})}\n\n".encode()

    # Emit message_delta with usage
    message_delta = {
        "type": "message_delta",
        "delta": {"stop_reason": "end_turn"},
        "usage": {"output_tokens": total_output_tokens},
    }
    yield f"event: message_delta\ndata: {json.dumps(message_delta)}\n\n".encode()

    # Emit message_stop
    yield f"event: message_stop\ndata: {json.dumps({'type': 'message_stop'})}\n\n".encode()


def _openai_response_to_anthropic(resp: dict, model: str) -> dict:
    """Convert an OpenAI completion response to Anthropic message format."""
    content = []
    choices = resp.get("choices", [])
    if choices:
        message = choices[0].get("message", {})
        text = message.get("content", "")
        if text:
            content.append({"type": "text", "text": text})

    usage = resp.get("usage", {})
    return {
        "id": resp.get("id", "msg_router"),
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": "end_turn",
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }
