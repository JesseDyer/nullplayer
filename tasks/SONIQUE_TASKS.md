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

Filed 2026-10-18 from the Phase 2 code review. S18–S20 are restructurings beyond Sonique: each
is weighed with the user before it starts, and touches `App/` (the sweeps above apply).

| ID | Item | Reach | Notes |
|---|---|---|---|
| S18 | Share the single-canvas family's selection and load lifecycle. `SkinInstallFolder` took the file commit; the selection preference (`selectedXName`, `select`, `resetSelection`, clearing it on remove) is still written out in `WMPSkinImporter`, `AudionFaceImporter` and `SoniqueSkinImporter`, and `reloadSelectedSkin` / `loadTask` / import / `resetToUnskinned` are near line-for-line in `AudionFaceMainWindowController` and `SoniqueSkinMainWindowController`. A `SkinSelection(key:)` beside `SkinInstallFolder`, then a shared load-task helper on `SingleCanvasMainWindow` | all | Touches Audion and `.wmz`: their sweeps byte-identical. `skin-subsystem-blueprint` for the seam |
| S19 | Derive the per-scope preference keys from the scope. Each of `VisClassicBridge.PreferenceScope`'s five key properties is a `switch` of `"visClassicX.\(case)"`, and `CavaSettings.key(_:for:)` the same per scope; a `String` raw value makes each one line (~35 lines gone) and a new family adds none. Confirm every existing key is that uniform first: a renamed key loses users' saved settings | all | Visualization code, not Sonique's; touches every family's embedded visualizer |
| S20 | Split `SoniqueSkinRenderer.swift` (704 lines) before it nears 1,000: the three modes, the navigator's screens (menu, visual mode, status line), Sonique's own glyphs (balls, drawer icons, menu icons) and its lettering (four `text` overloads, `marquee`, `wrapped`, `lettering`, collapsible into one taking a `SoniqueSkinMenu.Text`-like spec) | 524 | *Autonomous*: the render probe byte-identical before and after |
