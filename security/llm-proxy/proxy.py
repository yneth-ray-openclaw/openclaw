"""
Transparent LLM API reverse proxy with guard hook point.

Forwards all requests to the configured LLM API backend, injecting the real
API key. The proxy strips incoming auth headers so the real key never needs
to be stored in OpenClaw's config.

A guard hook point (check_guard) is included but disabled by default.
To enable, set GUARD_ENABLED=true and GUARD_URL in .env.security.

Built-in hidden Unicode detection runs when GUARD_ENABLED=true.
"""

import logging
import os
import unicodedata

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

logger = logging.getLogger("llm-proxy")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

# --- Configuration from environment ---

LLM_API_BASE = os.environ.get("LLM_API_BASE", "https://api.anthropic.com").rstrip("/")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "")
LLM_API_PROVIDER = os.environ.get("LLM_API_PROVIDER", "anthropic").lower()

GUARD_URL = os.environ.get("GUARD_URL", "")
GUARD_ENABLED = os.environ.get("GUARD_ENABLED", "false").lower() == "true"
GUARD_THRESHOLD = float(os.environ.get("GUARD_THRESHOLD", "0.8"))
GUARD_STRIP_HIDDEN_UNICODE = os.environ.get("GUARD_STRIP_HIDDEN_UNICODE", "true").lower() == "true"

if not LLM_API_KEY:
    logger.warning("LLM_API_KEY is not set — upstream requests will fail authentication")

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

app = FastAPI(title="LLM Security Proxy", docs_url=None, redoc_url=None)

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
    else:
        headers["x-api-key"] = LLM_API_KEY
        headers["anthropic-version"] = "2023-06-01"

    return headers


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "guard_enabled": GUARD_ENABLED,
        "guard_strip_hidden_unicode": GUARD_STRIP_HIDDEN_UNICODE,
        "llm_api_base": LLM_API_BASE,
    }


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
async def proxy(request: Request, path: str):
    upstream_url = f"{LLM_API_BASE}/{path}"

    # Parse body for POST requests (guard hook + message extraction)
    body_bytes = await request.body()
    body_dict = None

    if request.method == "POST" and body_bytes:
        try:
            import json

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
                import json

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

    # Build upstream request
    headers = build_upstream_headers(request)
    query_string = str(request.url.query) if request.url.query else ""
    if query_string:
        upstream_url = f"{upstream_url}?{query_string}"

    # Stream the response from the upstream API
    client = httpx.AsyncClient(timeout=httpx.Timeout(300.0, connect=10.0))

    try:
        upstream_request = client.build_request(
            method=request.method,
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

    # Build response headers, excluding hop-by-hop headers
    response_headers = {}
    hop_by_hop = {"transfer-encoding", "connection", "keep-alive"}
    for key, value in upstream_response.headers.items():
        if key.lower() not in hop_by_hop:
            response_headers[key] = value

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
