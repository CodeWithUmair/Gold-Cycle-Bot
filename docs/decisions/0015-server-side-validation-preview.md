# ADR-0015: Preview ladder + validation computed server-side only

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §8 (live validation, preview ladder), §9 (never trust the UI)

## Context
The form needs instant feedback and a 5-cycle preview. Copying the level math into TypeScript
would create two sources of truth that can drift.

## Decision
`POST /api/bot/validate` (auth, no CSRF: it's read-only) runs the same `CycleConfig` pydantic
model + `risk.validate_config` + `levels.preview_ladder` the engine uses. It always returns 200 with
`{errors, warnings, ladder}`. The form calls it debounced (250 ms) on every change. `arm` re-validates
server-side and returns 409/422 on failure.

## Consequences
The preview is guaranteed to match what the engine will do. It costs one local request per
keystroke pause, which is negligible on 127.0.0.1.

## Code
- [api/bot.py](../../backend/app/api/bot.py) `validate`, [ControlPanel.tsx](../../frontend/src/components/ControlPanel.tsx)
