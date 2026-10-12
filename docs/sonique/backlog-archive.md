# Sonique Skins backlog archive

Closed entries moved out of [`SONIQUE_TASKS.md`](../../tasks/SONIQUE_TASKS.md) so the live backlog stays
a list of work that is still open. Every row below is preserved **verbatim**, including the evidence it
was closed on.

## Issuing a number

**The next free number is S12.** S1–S10 were issued 2026-10-11, seeded from the family's planning
session, and S11 the same day, when the default skin was decided. S1 and S2 closed 2026-10-11.
Check this file before reusing any number — the live backlog is a list of *open* work and says
nothing about which numbers are spent.

## Closed

| ID | Item | Closed on |
|---|---|---|
| S1 | Decision record [`docs/sonique/phase-0-decision-record.md`](phase-0-decision-record.md): loading limits and `SQ####` codes, the navigator-screen policy, the auxiliary-window answer, the default-artwork answer for omitted entries, and the phase order | 2026-10-11. Locked by the user's sign-off on all five open questions: pitch knob → playback speed; repeat on/off only; omitted entries → NullPlayer's own default skin on Sonique's default layout (new row S11); navigator screens are NullPlayer's views in the skin's colours; DEBUG-only until the spike passes. `SQ0001`–`SQ0011`, each bound checked against the 524-skin corpus (tightest: `SQ0005` side at 1.8×, Eletro's 9,241 px knob strip). Corpus facts measured on the way and carried into `skills/sonique-skin-guide/reference/format.md`: the entry table is 4 bytes shorter than `count × 0x64`; 276 skins omit an entry; 6 skins write a `NAME + n` expression; 15 have more than one `[skin]` section. Docs only; no code. |
| S2 | Bounded `.sgf` loader and model in `SoniqueSkin/` with a DEBUG census probe replacing `sonique_census.py`; *autonomous* | 2026-10-11. `SoniqueSkinPolicy` (limits and `SQ####` codes), `SoniqueSkinArchive`, `SoniqueSkinRegion`, `SoniqueSkinINI`, `SoniqueSkin` and `SoniqueSkinLoader` in `Sources/NullPlayer/SoniqueSkin/`, off the main thread, every JPEG header and the pixel budget checked before any decode. `SoniqueSkinLoaderTests` (14): one hostile test per fatal code at production bounds, and each warning. Census probe `SoniqueSkinCensusTests` (`SONIQUE_SKIN`) and `scripts/sonique_census.sh` replace `sonique_census.py`, which is deleted: 524 skins, 524 load, 0 fatal; `SQ0009` 18, `SQ0010` 11; `greenwitch.sgf` fails `SQ0004`. Diffed against the Python census: identical but for `version` (17 skins write it outside the first `[skin]`, which the locked INI rule does not read) and one section (Draco's lone `[`, which the Python regex matched across a line break). Amendment 1 in the decision record: `SQ0009` no longer fires on a missing frame (27 skins' small mode was discarded), and `SQ0010` exempts small mode's drawers (429 of 440 first clipped). Headroom now reproduced by the census; the entry maximum is 69, not 55. `swift test --build-system native`: 3,071 tests, 20 skipped, 0 failures. No `App/` file changed. |
