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

## Phase 1 — the spike

The few-day spike that decides whether the rest is worth it: if the three modes match the oracle for
a dozen skins, the remainder is steady work.

| ID | Item | Reach | Notes |
|---|---|---|---|
| S4 | Default lookup: an omitted entry resolves to the default skin's (S11), an omitted `skin.ini` key to `misc.txt`'s default; `NAME ± n` expressions; first `[skin]` wins, checked against the oracle | 276 | Decision record § *Omitted entries and the default skin*, § *INI rules* |
| S12 | Each mode's window outline as Sonique draws it: navigator = frame + the closed drawer (where, from `MISC_DRAWER_POS` and the drawer regions); small = when Sonique draws its fixed default outline (`67659b3a`) instead of the skin's frame (Pino, Splash, dm-candella have a frame and get the default); mid = what adds or removes pixels at necks and tips (Splash 290 px, k2 ~2,800); *autonomous* | 524 | Evidence and command: `harness.md` § *Outline comparison*. Exit: `sonique_outline_compare.py`, extended to the assembled outline, exact for every mode of the 12-skin sample, or each remaining difference explained. Feeds S5's window shapes |
| S5 | `PlayerUIControllerFamily.sonique` behind a DEBUG `AppFeature`, letting the compiler list the seams; the three mode windows with real shapes, transport hit regions and lit states | all | UI row. Exit: nav, mid and small for the 12-skin sample side by side with `SoniqueOracle/captures/sample-2026-10-11` |
| S6 | Small mode complete: bar picture, track and time text in skin colours, drawers | 513 | UI row |
| S11 | NullPlayer's default Sonique skin: own artwork on Sonique's default layout (frames, regions, `[misc locations]`), `misc.txt` default colours, all three modes and every part. Also the family's unskinned fallback | 276 | Artwork row: the user signs off the look. Layout measured from the oracle with no skin loaded and the skinpack's `*_default.bmp` masks; neither is committed. S4 can land against a placeholder before it |

## Phase 2 — the rest of the UI

| ID | Item | Reach | Notes |
|---|---|---|---|
| S7 | Navigator menu screen and status line drawn in the skin's colours; the other screens host NullPlayer's views per the decision record | all | Capture every screen through the oracle first (`-showwindow 3 1..7`) |
| S8 | Mid mode: display placement, song and list progress rings (`mid_playlistmode` 270°/360°), shuttle | 520 | How the display's position is derived per skin is not yet known; the oracle sample shows it moving |
| S9 | Knob animation strips (volume, amp/bal/pitch, shuttle) and the EQ drawer | 511 | The pitch knob drives playback speed; read from the oracle the speed range its travel spans and whether Sonique's pitch shifted with it |
| S10 | Render sweep and committed baseline against the full oracle capture of the corpus (~70 min unattended) | 524 | Harness row, after S5 |
