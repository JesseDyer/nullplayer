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
| S17 | The navigator's up/down rocker. In Sonique it pages the display up and down (Lycos's `pathdesc.txt`: `/rgn/nav/up` and `/rgn/nav/down` are the "page up arrow" and "page down arrow"), through the playlist screen's list and the setup pages; the oracle shows only that it never leaves a screen. NullPlayer opens those screens as its own windows, so the display has little to page. Options the user likes for now: page the Playlist Editor window when it is open; step the visual mode screen's effect; leave it inert | 511 | Found closing S7. **Deferred** (the user, 2026-10-18) until the app is complete enough to try what works best live |
| S16 | The visual mode screen: extract WMP's `<EFFECTS>` surface (`SkinEffectsSurfaceView`: Spikes, Bars, Ambience, Cava, vis_classic) into a shared component and host it in the navigator's display; WMP keeps a thin wrapper | all | Touches `.wmz`: its sweeps byte-identical before and after. `skin-subsystem-blueprint` for the shared seam |
