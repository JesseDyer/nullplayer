# Sonique Skins — open backlog

The only live backlog for the Sonique (`.sgf`) skin family, and a list of open rows — nothing else.
Read `skills/sonique-skin-guide/SKILL.md` before picking anything up.

- The locked decisions are [`docs/sonique/phase-0-decision-record.md`](../docs/sonique/phase-0-decision-record.md).
- Closed rows move to [`docs/sonique/backlog-archive.md`](../docs/sonique/backlog-archive.md) in the
  change that closes them. That file's § *Issuing a number* holds the next free number.
- `.wmz` work goes in [`WMP_TASKS.md`](WMP_TASKS.md), `.wal` work in [`WINAMP5_TASKS.md`](WINAMP5_TASKS.md),
  Audion in [`AUDION_TASKS.md`](AUDION_TASKS.md).

**Agent-verifiable rows** (marked *autonomous*) are closed by the agent against their exit criteria.
**UI rows** stop for an on-screen check by the user before tests, docs or changelog entries are added.
Every row that touches `App/` ends with Classic, Original, `.wal`, `.wmz` and Audion sweeps
byte-identical to the capture before it.

## Phase 2 — the rest of the UI

| ID | Item | Reach | Notes |
|---|---|---|---|
| S17 | The navigator's up/down rocker: Sonique moves a selection through the menu screen; NullPlayer's menu has none, so the rocker does nothing. Decide what it does in NullPlayer's terms (the control mapping's "moves the menu selection") and measure Sonique's highlight on the oracle | 511 | Found closing S7 |
| S16 | The visual mode screen: extract WMP's `<EFFECTS>` surface (`WMPEffectsSurfaceView`: Spikes, Bars, Ambience, Cava, vis_classic) into a shared component and host it in the navigator's display; WMP keeps a thin wrapper | all | Touches `.wmz`: its sweeps byte-identical before and after. `skin-subsystem-blueprint` for the shared seam |
