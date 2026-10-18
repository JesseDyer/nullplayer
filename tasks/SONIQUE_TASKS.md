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
| S14 | The navigator drawer open against the oracle, and the pitch knob's speed range and whether Sonique's pitch shifted with it; replace the 0.5×–2× stand-in in `SoniqueSkinAudioEngineHost.setDial`. Then drive the drawer, its knobs and sliders in the app | 511 | The open drawer is reachable by command (screen 6 slides it open, found in S7); the pitch range needs the knob dragged in the oracle (`winhelper click`), which a locked screen refuses. S9 stopped there |
| S7 | Navigator menu screen and status line drawn in the skin's colours; the other screens host NullPlayer's views per the decision record | all | The status line is done (`format.md` § *The navigator's status line*). Left: (1) the menu screen, which only clicking the oracle's rocker reaches (`harness.md` § *The oracle*), so it waits for an unlocked screen like S14; Sonique's own menu carries Lycos's logo and links, which NullPlayer does not copy, so its layout is matched, not its content. (2) **The user's call:** how NullPlayer's playlist, visual mode and library show inside the display — drawn by the renderer in skin colours, or NullPlayer's own views embedded in the window — and what the menu offers in place of Sonique's quick links |
