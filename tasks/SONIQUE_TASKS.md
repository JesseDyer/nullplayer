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
| S14 | The navigator drawer open against the oracle, and the pitch knob's speed range and whether Sonique's pitch shifted with it; replace the 0.5×–2× stand-in in `SoniqueSkinAudioEngineHost.setDial`. Then drive the drawer, its knobs and sliders in the app | 511 | Needs an unlocked screen: no command opens the drawer, so the oracle is clicked (`winhelper click`), which a locked screen refuses. S9 stopped there |
| S7 | Navigator menu screen and status line drawn in the skin's colours; the other screens host NullPlayer's views per the decision record | all | Capture every screen through the oracle first (`-showwindow 3 1..7`) |

## After Phase 2 — shared code

| ID | Item | Reach | Notes |
|---|---|---|---|
| S13 | One shared skin importer for every family that installs into a folder of its own: the WMP, `.wal`, Audion and Sonique importers each repeat the directory, the selection key, the `.incoming-<UUID>` validate-then-commit and the off-main removal. Each family keeps only its file test and its loader call | 4 families | Its own scoped change, not folded into feature work: it touches every family's importer, so it ends with each family's import, select and remove driven in the app. Pull it ahead of Phase 2's end if a row changes how Sonique installs skins (a `.zip` of `.sgf` files, several at once), since that would fork the Sonique copy further |
