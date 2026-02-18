"""
Transparent LLM API reverse proxy with guard hook point and smart routing.

Forwards all requests to the configured LLM API backend, injecting the real
API key. The proxy strips incoming auth headers so the real key never needs
to be stored in OpenClaw's config.

A guard hook point (check_guard) is included but disabled by default.
To enable, set GUARD_ENABLED=true and GUARD_URL in .env.security.

Built-in hidden Unicode detection runs when GUARD_ENABLED=true.

Smart routing (optional): classifies request complexity and routes to
appropriate model tiers. Enable with SMART_ROUTER_ENABLED=true.
"""

import asyncio
import json
import logging
import os
import unicodedata
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

logger = logging.getLogger("llm-proxy")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

# --- Configuration from environment ---

LLM_API_BASE = os.environ.get("LLM_API_BASE", "https://api.anthropic.com").rstrip("/")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "")
LLM_API_PROVIDER = os.environ.get("LLM_API_PROVIDER", "anthropic").lower()
IS_OAUTH_TOKEN = LLM_API_KEY.startswith("sk-ant-oat")

GUARD_URL = os.environ.get("GUARD_URL", "")
GUARD_ENABLED = os.environ.get("GUARD_ENABLED", "false").lower() == "true"
GUARD_THRESHOLD = float(os.environ.get("GUARD_THRESHOLD", "0.8"))
GUARD_STRIP_HIDDEN_UNICODE = os.environ.get("GUARD_STRIP_HIDDEN_UNICODE", "true").lower() == "true"

SMART_ROUTER_ENABLED = os.environ.get("SMART_ROUTER_ENABLED", "false").lower() == "true"

if not LLM_API_KEY:
    logger.warning("LLM_API_KEY is not set — upstream requests will fail authentication")

# --- Smart router state (initialized lazily in lifespan) ---

_router_config = None  # router_config.RouterConfig | None
_budget_manager = None  # budget.BudgetManager | None
_budget_config = None   # router_config.BudgetConfig | None
_quota_tracker = None   # budget.QuotaTracker | None
_smart_router_ready = False


class SSETokenExtractor:
    """Incremental SSE parser that extracts token usage from streaming responses.

    Handles both Anthropic (message_start/message_delta) and OpenAI
    (final chunk with usage) formats. Only JSON-parses lines that
    contain '"usage"' for efficiency.
    """

    def __init__(self):
        self._line_buffer = b""
        self.input_tokens = 0
        self.output_tokens = 0
        self.cache_read_input_tokens = 0
        self.cache_creation_input_tokens = 0
        self.model: str | None = None

    def feed(self, chunk: bytes):
        """Process a chunk of SSE data."""
        data = self._line_buffer + chunk
        # Split on newlines, keeping incomplete last line in buffer
        lines = data.split(b"\n")
        self._line_buffer = lines[-1]
        for line in lines[:-1]:
            self._process_line(line)

    def finalize(self):
        """Process any remaining data in the buffer."""
        if self._line_buffer:
            self._process_line(self._line_buffer)
            self._line_buffer = b""

    def _process_line(self, line: bytes):
        # SSE lines start with "data: "
        if not line.startswith(b"data: "):
            return
        payload = line[6:]
        if payload == b"[DONE]":
            return
        # Fast filter: only parse lines that might contain usage info or model
        needs_parse = b'"usage"' in payload or b'"model"' in payload
        if not needs_parse:
            return
        try:
            obj = json.loads(payload)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return
        self._extract(obj)

    def _extract(self, obj: dict):
        # Extract model name
        if not self.model:
            # Anthropic: message_start has message.model
            msg = obj.get("message")
            if isinstance(msg, dict) and "model" in msg:
                self.model = msg["model"]
            # OpenAI: top-level model field
            elif "model" in obj:
                self.model = obj.get("model")

        # Anthropic message_start: input token counts
        msg = obj.get("message")
        if isinstance(msg, dict):
            usage = msg.get("usage")
            if isinstance(usage, dict):
                self.input_tokens += usage.get("input_tokens", 0)
                self.cache_read_input_tokens += usage.get("cache_read_input_tokens", 0)
                self.cache_creation_input_tokens += usage.get("cache_creation_input_tokens", 0)

        # Anthropic message_delta: output token counts
        usage = obj.get("usage")
        if isinstance(usage, dict) and "message" not in obj:
            self.output_tokens += usage.get("output_tokens", 0)

        # OpenAI final chunk: prompt_tokens / completion_tokens
        usage = obj.get("usage")
        if isinstance(usage, dict) and "prompt_tokens" in usage:
            self.input_tokens += usage.get("prompt_tokens", 0)
            self.output_tokens += usage.get("completion_tokens", 0)

    def has_usage(self) -> bool:
        return self.input_tokens > 0 or self.output_tokens > 0


def _init_smart_router():
    """Initialize smart router components. Called during lifespan startup."""
    global _router_config, _budget_manager, _budget_config, _quota_tracker, _smart_router_ready

    if not SMART_ROUTER_ENABLED:
        logger.info("Smart router disabled (SMART_ROUTER_ENABLED=false)")
        return

    try:
        from router_config import load_config
        from classifier import init_classifier
        from budget import BudgetManager, QuotaTracker
        from litellm_bridge import init_litellm

        _router_config = load_config()
        if _router_config is None or not _router_config.enabled:
            logger.warning("Smart router config not loaded or disabled — operating in legacy mode")
            return

        # Initialize RouteLLM classifier
        init_classifier(_router_config.classifier, _router_config.tier_order)

        # Initialize budget manager
        _budget_manager = BudgetManager(_router_config.budgets)
        _budget_config = _router_config.budgets

        # Initialize quota tracker for Anthropic rate-limit headers
        _quota_tracker = QuotaTracker(
            push_within_minutes=_router_config.budgets.max_push_within_minutes,
        )

        # Initialize LiteLLM for cross-provider routing
        init_litellm(_router_config.providers)

        _smart_router_ready = True
        logger.info(
            "Smart router initialized: %d providers, %d tiers",
            len(_router_config.providers), len(_router_config.tiers),
        )

    except Exception as e:
        logger.error("Failed to initialize smart router: %s — operating in legacy mode", e)
        _smart_router_ready = False


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage background tasks for the app lifecycle."""
    # Initialize smart router (runs synchronously at startup)
    _init_smart_router()
    yield


# --- Hidden Unicode detection ---

HIDDEN_UNICODE_RANGES = [
    (0x200B, 0x200F),  # zero-width chars + LRM/RLM
    (0x202A, 0x202E),  # bidi overrides
    (0x2060, 0x2064),  # invisible operators
    (0x2066, 0x2069),  # bidi isolates
    (0x00AD, 0x00AD),  # soft hyphen
    (0x061C, 0x061C),  # arabic letter mark
    (0xFEFF, 0xFEFF),  # BOM / zero-width no-break space
    (0xE0001, 0xE007F),  # tag characters
]


def detect_hidden_unicode(text: str) -> list[dict]:
    """Returns list of {codepoint, position, name} for hidden chars found."""
    findings = []
    for i, ch in enumerate(text):
        cp = ord(ch)
        for start, end in HIDDEN_UNICODE_RANGES:
            if start <= cp <= end:
                findings.append({
                    "codepoint": f"U+{cp:04X}",
                    "position": i,
                    "name": unicodedata.name(ch, "UNKNOWN"),
                })
                break
    return findings


def strip_hidden_unicode(text: str) -> str:
    """Remove all hidden Unicode characters from text."""
    result = []
    for ch in text:
        cp = ord(ch)
        hidden = False
        for start, end in HIDDEN_UNICODE_RANGES:
            if start <= cp <= end:
                hidden = True
                break
        if not hidden:
            result.append(ch)
    return "".join(result)


# --- FastAPI app ---

app = FastAPI(title="LLM Security Proxy", docs_url=None, redoc_url=None, lifespan=lifespan)

# Paths that carry token usage in responses
_TRACKABLE_PATHS = ("/v1/messages", "/v1/chat/completions")

# Headers that should never be forwarded to the upstream API
STRIPPED_HEADERS = {"host", "content-length", "authorization", "x-api-key"}


async def extract_messages(body: dict) -> list[str]:
    """Extract user-facing text from the request body.

    Supports both Anthropic and OpenAI message formats.
    Used by the guard hook to scan content before forwarding.
    """
    texts: list[str] = []

    # Anthropic format: top-level "system" field
    system = body.get("system")
    if isinstance(system, str):
        texts.append(system)
    elif isinstance(system, list):
        for block in system:
            if isinstance(block, dict) and block.get("type") == "text":
                texts.append(block.get("text", ""))

    # Messages array (both Anthropic and OpenAI)
    for msg in body.get("messages", []):
        role = msg.get("role", "")
        # Anthropic: scan user messages; OpenAI: scan user + system
        if role == "user" or (LLM_API_PROVIDER == "openai" and role == "system"):
            content = msg.get("content", "")
            if isinstance(content, str):
                texts.append(content)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        texts.append(block.get("text", ""))

    return texts


async def check_hidden_unicode(messages: list[str]) -> dict | None:
    """Built-in pre-check for hidden Unicode characters.

    Runs before the external guard hook, always active when GUARD_ENABLED=true.
    Returns block info if hidden chars found and stripping is disabled, else None.
    """
    if not GUARD_ENABLED:
        return None

    all_findings = []
    for msg in messages:
        findings = detect_hidden_unicode(msg)
        all_findings.extend(findings)

    if not all_findings:
        return None

    codepoints = [f["codepoint"] for f in all_findings[:10]]
    logger.warning(
        "Hidden Unicode detected: %d chars found (%s)",
        len(all_findings),
        ", ".join(codepoints),
    )

    if GUARD_STRIP_HIDDEN_UNICODE:
        # Stripping mode — log but don't block
        return None

    # Block mode
    return {
        "blocked": True,
        "reason": f"Hidden Unicode characters detected: {', '.join(codepoints)}",
        "count": len(all_findings),
    }


def strip_hidden_unicode_from_body(body: dict) -> dict:
    """Strip hidden Unicode from all text fields in the request body."""
    # System field
    system = body.get("system")
    if isinstance(system, str):
        body["system"] = strip_hidden_unicode(system)
    elif isinstance(system, list):
        for block in system:
            if isinstance(block, dict) and block.get("type") == "text":
                block["text"] = strip_hidden_unicode(block.get("text", ""))

    # Messages
    for msg in body.get("messages", []):
        content = msg.get("content", "")
        if isinstance(content, str):
            msg["content"] = strip_hidden_unicode(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    block["text"] = strip_hidden_unicode(block.get("text", ""))

    return body


async def check_guard(messages: list[str]) -> dict | None:
    """Hook point for future guard integration.

    When GUARD_ENABLED=true and GUARD_URL is set, sends messages
    to the guard service for scanning. Returns block info or None.
    Currently disabled — all requests pass through.
    """
    if not GUARD_ENABLED or not GUARD_URL:
        return None

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(GUARD_URL, json={"messages": messages})
            if resp.status_code == 200:
                result = resp.json()
                score = result.get("score", 0.0)
                if score >= GUARD_THRESHOLD:
                    return {
                        "blocked": True,
                        "score": score,
                        "reason": result.get("reason", "Content blocked by guard"),
                    }
    except Exception as e:
        logger.error("Guard service error: %s", e)

    return None


def build_upstream_headers(request: Request) -> dict[str, str]:
    """Build headers for the upstream request.

    Strips incoming auth headers and injects the real API key.
    """
    headers = {}
    for key, value in request.headers.items():
        if key.lower() not in STRIPPED_HEADERS:
            headers[key] = value

    # Inject real API key
    if LLM_API_PROVIDER == "openai":
        headers["authorization"] = f"Bearer {LLM_API_KEY}"
    elif IS_OAUTH_TOKEN:
        # OAuth setup tokens require Bearer auth + beta flags
        headers["authorization"] = f"Bearer {LLM_API_KEY}"
        headers["anthropic-version"] = "2023-06-01"
        # Merge oauth betas with any existing anthropic-beta from the request
        existing_beta = headers.get("anthropic-beta", "")
        beta_parts = [b.strip() for b in existing_beta.split(",") if b.strip()]
        for required in ("oauth-2025-04-20", "claude-code-20250219"):
            if required not in beta_parts:
                beta_parts.append(required)
        headers["anthropic-beta"] = ",".join(beta_parts)
        # Identity headers required by Anthropic for OAuth
        headers["user-agent"] = "claude-cli/2.1.2 (external, cli)"
        headers["x-app"] = "cli"
    else:
        # Regular API key
        headers["x-api-key"] = LLM_API_KEY
        headers["anthropic-version"] = "2023-06-01"

    return headers


def build_provider_headers(provider, request: Request) -> dict[str, str]:
    """Build headers for a routed request to a specific provider.

    Used by the smart router when forwarding to a same-format provider.
    """
    headers = {}
    for key, value in request.headers.items():
        if key.lower() not in STRIPPED_HEADERS:
            headers[key] = value

    if provider.type == "anthropic":
        headers["x-api-key"] = provider.api_key
        headers["anthropic-version"] = "2023-06-01"
    else:
        # OpenAI-compatible providers (OpenAI, Google Gemini, etc.)
        headers["authorization"] = f"Bearer {provider.api_key}"

    return headers


# --- Endpoints ---


@app.get("/health")
async def health():
    result = {
        "status": "healthy",
        "guard_enabled": GUARD_ENABLED,
        "guard_strip_hidden_unicode": GUARD_STRIP_HIDDEN_UNICODE,
        "llm_api_base": LLM_API_BASE,
    }
    if SMART_ROUTER_ENABLED:
        result["smart_router"] = {
            "enabled": SMART_ROUTER_ENABLED,
            "ready": _smart_router_ready,
        }
    return result


@app.get("/router/status")
async def router_status():
    """Return smart router status, classifier info, and budget status."""
    if not SMART_ROUTER_ENABLED or not _smart_router_ready:
        return JSONResponse({
            "enabled": SMART_ROUTER_ENABLED,
            "ready": _smart_router_ready,
        })

    from classifier import classifier_status

    result = {
        "enabled": True,
        "ready": True,
        "classifier": classifier_status(),
        "providers": {
            name: {"type": p.type, "base_url": p.base_url, "has_key": bool(p.api_key)}
            for name, p in _router_config.providers.items()
        } if _router_config else {},
        "tiers": {
            name: [{"provider": m.provider, "model": m.model} for m in models]
            for name, models in (_router_config.tiers if _router_config else {}).items()
        },
        "default_tier": _router_config.default_tier if _router_config else "tier1",
    }
    if _budget_manager is not None:
        result["budget"] = _budget_manager.status()
    if _quota_tracker is not None:
        result["quota"] = _quota_tracker.status()
    return JSONResponse(result)


# --- Smart routing helpers ---


def _detect_client_format(path: str) -> str:
    """Detect the client's API format from the request path."""
    if "/v1/messages" in f"/{path}":
        return "anthropic"
    return "openai"


async def _forward_via_httpx(
    method: str,
    upstream_url: str,
    headers: dict[str, str],
    body_bytes: bytes,
    query_string: str,
    is_trackable: bool,
    request_model: str,
    routing_headers: dict[str, str] | None = None,
) -> Response:
    """Forward a request to an upstream provider via httpx (existing logic).

    This handles both streaming and non-streaming responses, with token usage
    extraction for trackable paths.
    """
    if query_string:
        upstream_url = f"{upstream_url}?{query_string}"

    client = httpx.AsyncClient(timeout=httpx.Timeout(300.0, connect=10.0))

    try:
        upstream_request = client.build_request(
            method=method,
            url=upstream_url,
            headers=headers,
            content=body_bytes,
        )
        upstream_response = await client.send(upstream_request, stream=True)
    except httpx.ConnectError as e:
        await client.aclose()
        logger.error("Failed to connect to upstream %s: %s", upstream_url, e)
        return Response(
            content='{"error": "upstream_connection_failed"}',
            status_code=502,
            media_type="application/json",
        )
    except Exception as e:
        await client.aclose()
        logger.error("Upstream request error: %s", e)
        return Response(
            content='{"error": "upstream_error"}',
            status_code=502,
            media_type="application/json",
        )

    # Extract Anthropic rate-limit headers for quota tracking
    if _quota_tracker is not None:
        _quota_tracker.update(upstream_response.headers)

    # Build response headers, excluding hop-by-hop headers
    response_headers = {}
    hop_by_hop = {"transfer-encoding", "connection", "keep-alive"}
    for key, value in upstream_response.headers.items():
        if key.lower() not in hop_by_hop:
            response_headers[key] = value

    # Add routing metadata headers
    if routing_headers:
        response_headers.update(routing_headers)

    content_type = upstream_response.headers.get("content-type", "")
    is_streaming = "text/event-stream" in content_type

    # --- Three-way branch for token tracking ---

    if is_trackable and is_streaming:
        extractor = SSETokenExtractor()

        async def stream_with_usage():
            try:
                async for chunk in upstream_response.aiter_bytes():
                    extractor.feed(chunk)
                    yield chunk
            finally:
                extractor.finalize()
                if extractor.has_usage() and _budget_manager is not None:
                    model = extractor.model or request_model
                    await _budget_manager.record_cost(model, extractor.input_tokens, extractor.output_tokens)
                await upstream_response.aclose()
                await client.aclose()

        return StreamingResponse(
            content=stream_with_usage(),
            status_code=upstream_response.status_code,
            headers=response_headers,
        )

    if is_trackable and not is_streaming:
        try:
            resp_body = await upstream_response.aread()
            await upstream_response.aclose()
            await client.aclose()

            if upstream_response.status_code == 200:
                try:
                    resp_json = json.loads(resp_body)
                    usage_data = resp_json.get("usage", {})
                    model = resp_json.get("model", request_model)
                    if usage_data and _budget_manager is not None:
                        input_tk = usage_data.get("input_tokens", usage_data.get("prompt_tokens", 0))
                        output_tk = usage_data.get("output_tokens", usage_data.get("completion_tokens", 0))
                        await _budget_manager.record_cost(model, input_tk, output_tk)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    pass

            return Response(
                content=resp_body,
                status_code=upstream_response.status_code,
                headers=response_headers,
            )
        except Exception:
            await upstream_response.aclose()
            await client.aclose()
            raise

    # Everything else: pass through unchanged
    async def stream_response():
        try:
            async for chunk in upstream_response.aiter_bytes():
                yield chunk
        finally:
            await upstream_response.aclose()
            await client.aclose()

    return StreamingResponse(
        content=stream_response(),
        status_code=upstream_response.status_code,
        headers=response_headers,
    )


async def _handle_cross_provider_route(
    body_dict: dict,
    client_format: str,
    target_model: str,
    provider,
    is_streaming: bool,
    routing_headers: dict[str, str],
) -> Response:
    """Handle cross-provider routing via LiteLLM."""
    import litellm_bridge

    if is_streaming:
        async def stream_cross_provider():
            async for chunk in litellm_bridge.forward_streaming(
                body_dict, client_format, target_model, provider,
            ):
                yield chunk

        resp_headers = {"content-type": "text/event-stream"}
        resp_headers.update(routing_headers)
        return StreamingResponse(
            content=stream_cross_provider(),
            status_code=200,
            headers=resp_headers,
        )
    else:
        status, headers, body_bytes = await litellm_bridge.forward_non_streaming(
            body_dict, client_format, target_model, provider,
        )
        headers.update(routing_headers)
        return Response(
            content=body_bytes,
            status_code=status,
            headers=headers,
        )


# --- Main proxy handler ---


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
async def proxy(request: Request, path: str):
    upstream_url = f"{LLM_API_BASE}/{path}"

    # Parse body for POST requests (guard hook + message extraction)
    body_bytes = await request.body()
    body_dict = None

    if request.method == "POST" and body_bytes:
        try:
            body_dict = json.loads(body_bytes)
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass

    # Guard hooks (hidden Unicode check runs first, then external guard)
    if body_dict is not None:
        messages = await extract_messages(body_dict)
        if messages:
            # Built-in hidden Unicode check
            unicode_block = await check_hidden_unicode(messages)
            if unicode_block:
                logger.warning("Request blocked by hidden Unicode check: %s", unicode_block)
                return Response(
                    content=f'{{"error": "blocked", "reason": "{unicode_block.get("reason", "")}"}}',
                    status_code=400,
                    media_type="application/json",
                )

            # Strip hidden Unicode if enabled (modifies body in-place)
            if GUARD_ENABLED and GUARD_STRIP_HIDDEN_UNICODE:
                had_hidden = any(detect_hidden_unicode(msg) for msg in messages)
                if had_hidden:
                    body_dict = strip_hidden_unicode_from_body(body_dict)
                    body_bytes = json.dumps(body_dict).encode()
                    logger.info("Stripped hidden Unicode characters from request")

            # External guard hook
            block_info = await check_guard(messages)
            if block_info:
                logger.warning("Request blocked by guard: %s", block_info)
                return Response(
                    content=f'{{"error": "blocked", "reason": "{block_info.get("reason", "")}"}}',
                    status_code=400,
                    media_type="application/json",
                )

    # Determine if this request is trackable for token usage
    is_trackable = request.method == "POST" and any(
        f"/{path}".endswith(p) for p in _TRACKABLE_PATHS
    )
    request_model = body_dict.get("model", "unknown") if body_dict else "unknown"
    query_string = str(request.url.query) if request.url.query else ""

    # --- Smart routing (between guard hooks and upstream forwarding) ---

    if _smart_router_ready and is_trackable and body_dict is not None:
        try:
            from classifier import classify_request
            from router_config import resolve_target, downgrade_tier, lowest_tier

            client_format = _detect_client_format(path)

            # 1. Classify request complexity
            tier = classify_request(body_dict, _router_config.default_tier)

            # 2. Time-based max push: reset is imminent, use remaining quota on best model
            if _quota_tracker is not None and _quota_tracker.should_max_push():
                push_tier = _budget_config.max_push_tier or _router_config.tier_order[0]
                tier = push_tier
                logger.info("Quota resets soon: pushing to max tier %s", tier)

            # 3. Budget check → possibly force downgrade (skipped if already max-pushed)
            elif _budget_manager is not None:
                if _budget_manager.is_over_budget():
                    if _budget_manager.over_budget_action == "reject":
                        return Response(
                            content='{"error": "budget_exceeded", "message": "Cost budget exceeded"}',
                            status_code=429,
                            media_type="application/json",
                        )
                    # over_budget_action == "allow": force to lowest tier
                    tier = lowest_tier(_router_config)
                elif _budget_manager.should_downgrade():
                    tier = downgrade_tier(_router_config, tier, _budget_manager.downgrade_steps)
                    logger.info("Budget pressure: downgraded to %s", tier)

            # 4. Resolve provider + model for this tier (with fallback)
            exclude_providers: set[str] = set()
            target = resolve_target(_router_config, tier, exclude_providers)

            if target is None:
                # No providers available in this tier — fall through to legacy
                logger.warning("No providers available for %s — using legacy forwarding", tier)
            else:
                provider, target_model, extra_params = target
                target_format = provider.type

                # Determine if request is streaming
                is_streaming = body_dict.get("stream", False)

                routing_headers = {
                    "x-llm-router-tier": tier,
                    "x-llm-router-model": target_model,
                    "x-llm-router-provider": provider.name,
                }

                logger.info(
                    "Routing: tier=%s provider=%s model=%s (client=%s, target=%s)",
                    tier, provider.name, target_model, client_format, target_format,
                )

                # 5. Route: same-provider or cross-provider
                if client_format == target_format:
                    # SAME FORMAT: change model, forward directly via httpx
                    routed_body = body_dict.copy()
                    routed_body["model"] = target_model

                    # Apply per-tier extra_params (e.g., thinking budget, max_tokens)
                    if extra_params:
                        for key, value in extra_params.items():
                            if isinstance(value, dict) and isinstance(routed_body.get(key), dict):
                                # Deep merge one level (e.g., thinking.budget_tokens)
                                routed_body[key] = {**routed_body[key], **value}
                            else:
                                routed_body[key] = value

                    routed_bytes = json.dumps(routed_body).encode()

                    # Build upstream URL for the target provider
                    if target_format == "anthropic":
                        target_url = f"{provider.base_url}/v1/messages"
                    else:
                        target_url = f"{provider.base_url}/v1/chat/completions"

                    headers = build_provider_headers(provider, request)

                    return await _forward_via_httpx(
                        method=request.method,
                        upstream_url=target_url,
                        headers=headers,
                        body_bytes=routed_bytes,
                        query_string=query_string,
                        is_trackable=True,
                        request_model=target_model,
                        routing_headers=routing_headers,
                    )
                else:
                    # CROSS FORMAT: use LiteLLM for format translation
                    return await _handle_cross_provider_route(
                        body_dict=body_dict,
                        client_format=client_format,
                        target_model=target_model,
                        provider=provider,
                        is_streaming=is_streaming,
                        routing_headers=routing_headers,
                    )

        except Exception as e:
            # Fail-open: if anything goes wrong with routing, fall through to legacy
            logger.error("Smart routing error: %s — falling through to legacy forwarding", e)

    # --- Legacy forwarding (default path) ---

    headers = build_upstream_headers(request)
    return await _forward_via_httpx(
        method=request.method,
        upstream_url=upstream_url,
        headers=headers,
        body_bytes=body_bytes,
        query_string=query_string,
        is_trackable=is_trackable,
        request_model=request_model,
    )
