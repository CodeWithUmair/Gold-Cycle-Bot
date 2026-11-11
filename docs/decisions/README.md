# Decision records (ADRs)

One file per design decision: what was decided, why, and where it lives in the code.
The **spec** ([CLAUDE.md](../../CLAUDE.md)) says *what* the bot must do. These files record
*how* we chose to do it wherever the spec left room, contradicted itself, or said nothing.

**Rules**
- Never edit an accepted decision to change it. Write a new ADR and mark the old one
  `Superseded by ADR-00NN`.
- Client answers to open questions (Q1/Q2/Q5) → new ADR + update CLAUDE.md §12 + HANDOFF.md.
- Copy [TEMPLATE.md](TEMPLATE.md) and take the next number.

## Index

| # | Decision | Status | Area |
|---|---|---|---|
| [0001](0001-open-questions-as-config.md) | Open questions Q1/Q2/Q5 shipped as config switches with spec defaults | Accepted | Rules |
| [0002](0002-touch-trigger-semantics.md) | Touch trigger: side recorded at arm, never fire on arm | Accepted | Engine |
| [0003](0003-opening-retry-and-tolerance.md) | OPENING retries in tolerance, re-arms out of tolerance | Accepted | Engine |
| [0004](0004-stop-price-after-first-fill.md) | Stop price only acts after the first fill | Accepted | Engine |
| [0005](0005-pending-close-not-a-state.md) | Bot-initiated close is a flag inside IN_POSITION, not a state | Accepted | Engine |
| [0006](0006-close-reason-classification.md) | Close reason: deal reason first, price inference second | Accepted | Engine |
| [0007](0007-single-mode-ends-idle.md) | SINGLE ends in IDLE on TP or SL; CYCLE SL → STOPPED | Accepted | Engine |
| [0008](0008-stop-now-vs-close-all.md) | "Stop now" leaves the trade; "Close all & stop" closes it | Accepted | Controls |
| [0009](0009-idempotency-and-attach.md) | Never open while any bot position exists; attach own session's | Accepted | Safety |
| [0010](0010-restart-resume-model.md) | Restart → STOPPED + resumable; survives repeated restarts | Accepted | Recovery |
| [0011](0011-daily-loss-definition.md) | Daily loss = realized today (all sessions) + floating | Accepted | Safety |
| [0012](0012-mt5-single-thread-executor.md) | MT5 calls via a 1-worker ThreadPoolExecutor | Accepted | Broker |
| [0013](0013-dry-run-as-paper-broker.md) | DRY_RUN = paper fills on real MT5 prices | Accepted | Broker |
| [0014](0014-zero-price-is-disconnect.md) | A zero/negative tick is treated as "no price" | Accepted | Broker |
| [0015](0015-server-side-validation-preview.md) | Preview ladder + validation computed server-side only | Accepted | UI |
| [0016](0016-auth-sessions-csrf.md) | In-memory sessions, double-submit CSRF header, argon2 | Accepted | Security |
| [0017](0017-ws-coalescing.md) | WebSocket coalesces high-rate messages, 100 ms flush | Accepted | UI |
