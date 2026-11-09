"""Optional, off-by-default secret redaction for correlate_batch.py / correlate_live.py.

This is deliberately opt-in (`--redact` on both correlators): the OS's own `<private>` annotations
already hide some values, but console output can still contain JWTs, bearer tokens, device tokens,
and other secret-shaped values that were never marked private by the source. Redaction is off by
default so a developer reading a transcript isn't silently missing diagnostic detail they actually
need — turn it on specifically when a transcript will be saved, shared, or pasted somewhere.

This is pattern-based, not a guarantee: it catches common shapes (JWTs, `Bearer <token>`, and
`key=value`/`key: value` pairs where the key name looks sensitive), not every possible secret.
Treat it as a reasonable default scrub, not a substitute for reviewing what you're about to share.
"""
from __future__ import annotations

import re

_JWT = re.compile(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\b')
_BEARER = re.compile(r'\bBearer\s+[A-Za-z0-9\-_.=]{8,}\b', re.IGNORECASE)
_SENSITIVE_KV = re.compile(
    r'(?i)\b(access[-_]?token|refresh[-_]?token|api[-_]?key|auth[-_]?token|secret|password|'
    r'session[-_]?id|device[-_]?token|cookie)\b\s*[:=]\s*["\']?([A-Za-z0-9\-_.+/=]{6,})["\']?'
)

PATTERN_NAMES = ('jwt', 'bearer_token', 'sensitive_key_value')


def redact_text(raw: str) -> tuple[str, int]:
    """Returns (redacted_text, redaction_count). Never called unless the caller opted in."""
    count = 0

    def _sub_jwt(m: re.Match) -> str:
        nonlocal count
        count += 1
        return '<redacted:jwt>'

    def _sub_bearer(m: re.Match) -> str:
        nonlocal count
        count += 1
        return 'Bearer <redacted:token>'

    def _sub_kv(m: re.Match) -> str:
        nonlocal count
        count += 1
        return f'{m.group(1)}=<redacted:value>'

    text = _JWT.sub(_sub_jwt, raw)
    text = _BEARER.sub(_sub_bearer, text)
    text = _SENSITIVE_KV.sub(_sub_kv, text)
    return text, count
