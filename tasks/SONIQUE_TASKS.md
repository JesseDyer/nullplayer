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

No open rows. The family shipped with Phase 2 (decision record Amendment 5); new work is filed here
when a skin or a report reproduces it.

## Maintenance

S18–S21, filed from the Phase 2 code review, closed 2026-10-18. S22 was filed 2026-10-18 from the
branch's second review. It is a restructuring beyond Sonique: weigh it with the user before it
starts. It touches `App/`, so the sweeps above apply.

| ID | Item | Reach | Notes |
|---|---|---|---|
| S22 | Have `WindowManager` ask the main window controller for a capability instead of switching on `PlayerUIControllerFamily`. Adding Sonique took 41 `case .sonique` lines, and 21 sites list `.audion, .sonique` together. The eight `hostedSurface*` switches (`hostedSurfaceFrameArtwork`, `…RenderedFrameArtwork`, `…HasSettledFrameAnswer`, `demandHostedSurfaceFrame`, `hostedSurfaceLiveResize`, `…BordersAreSettled`, `…BorderInsets`, `prewarmHostedSurfaceFrames`) only ask one thing: is this WMP, which lends frame artwork? A `HostedFrameLender` protocol on `WMPMainWindowController`, asked with `as?` the way `SkinDrawnEqualizer` already is, deletes those switches. Then look at the `audionSurfaceStyle`/`soniqueSurfaceStyle` pair: `surfaceStyle` can become a `SingleCanvasMainWindow` requirement, as `loadedSkinURL` already is, once the two families' fallbacks (Audion's neutral palette, Sonique's default skin) have one home. The exhaustive switches exist on purpose, so a new family is forced to decide. The protocol has to keep that guarantee, or say why it no longer needs to | all | Touches `.wmz` hosted frames and Audion: their sweeps must be byte-identical, and Classic/Original gated as today. `skin-subsystem-blueprint` for the seam |
