# ADR-0016: In-memory sessions, double-submit CSRF header, argon2

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §9

## Decision
- Single admin from `.env`: `ADMIN_USERNAME`, `ADMIN_PASSWORD_HASH` (argon2, made with
  `python -m app.security`). An empty hash means login returns 503 with instructions.
- Session = random 256-bit token in cookie `gc_session` (httpOnly, SameSite=Strict, Path=/,
  `secure=False` because it's plain http on 127.0.0.1). Stored **in memory**, so a server restart
  logs everyone out. TTL `SESSION_TTL_HOURS`.
- CSRF: each session has a random token returned by `/login` and `/me`. Every state-changing POST
  must send it as `X-CSRF-Token` (constant-time compare).
- Login rate limit: 5 failures per IP per 5 min → 429.
- WebSocket requires a valid session cookie (else close code 4401).
- Every action and login attempt is written to the `audit` table.
- Security headers: X-Frame-Options DENY, nosniff, no-referrer. `/docs` and `/openapi.json` are disabled.

## Alternatives considered
- Signed stateless cookies: can't be revoked on logout.

## Consequences
If remote access is added (Tailscale), set `secure=True` behind HTTPS and keep SameSite=Strict.

## Code / tests
- [security.py](../../backend/app/security.py), [api/auth.py](../../backend/app/api/auth.py), [main.py](../../backend/app/main.py)
- Tests: [test_api.py](../../backend/tests/test_api.py)
