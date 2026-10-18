# Harness

The **only** place a Sonique probe flag, corpus command or oracle command is documented. Add one
here in the change that adds it.

## Where things are

Nothing below is committed: not skins, not Sonique, not Lycos's docs, not captures.

| What | Path |
|---|---|
| Corpus | `~/Library/Application Support/NullPlayer/SoniqueSkins/` (flat; a same-name variant keeps a `-<sha6>` suffix) |
| Oracle install | `~/Library/Application Support/NullPlayer/SoniqueOracle/prefix/` (a Wine prefix; Sonique 1.96 portable in `C:\Sonique`, the corpus copied into `C:\Sonique\skins`) |
| Lycos's format docs | `SoniqueOracle/docs/` (`misc.txt`, `how-to-make-skins-1.09.txt`, `pathdesc.txt`, `cmndline.htm`, `hotkeys.htm`, `tutorial/`) |
| Oracle captures | `SoniqueOracle/captures/`: `sample-2026-10-11` (12 skins), `corpus-2026-10-17` (all 524, the sweep's) |
| Wine | Gcenx `Wine Devel.app` 11.18 in `~/Applications/` |

The corpus came from the archive.org item `sonique_media_player` (`Sonique.zip`). That archive also
ships keygens and cracks under `plug-ins/DSP`; strip them before unpacking anything else, and never
run any of its other executables outside the Wine prefix.

## The census

Every skin through `SoniqueSkinLoader`, the app's own loader. Run when the corpus, the format
reading or the loader changes. About 11 s for the corpus.

1. Run the census into a fresh directory; `--corpus` takes a directory, one `.sgf` or a list file.
2. Read the summary it prints; the raw probe lines are `<outdir>/raw.txt`.

```bash
scripts/sonique_census.sh /tmp/sonique-census | grep -v '^entry'
```

**Confirm it took:** the first line reads `files=… unique=… parsed=… failed=…`, and `files` equals
the corpus count. A shorter run prints `the run died` and exits 1.

| Flag | Meaning |
|---|---|
| `SONIQUE_SKIN` | an `.sgf`, a directory of them, or a file listing them one per line. Read by `SoniqueSkinCensusTests.testCensusSkinOrCorpus`, which skips without it |

The probe prints, per skin: `SKIN <file>` (or `SKIN <file> FAILED [SQ####] …`), `DIGEST`, `SIZE`
(the inputs to the locked limits), one `ENTRY` per distinct stored name, one `SECTION` per `skin.ini`
header, `VERSION`, `MODES default=…`, and one `FINDING` per warning.

Measured 2026-10-11:

```text
files=524 unique=524 parsed=524 failed=0 malformed_regions=0
version {'none': 291, '105': 222, '100': 5, '1': 2, 'no-ini': 2, '130': 2}
findings {'SQ0009': 18, 'SQ0010': 11, 'SQ0011': 3}
default_modes {'small': 11, 'navigator': 5, 'mid': 2}
headroom bytes max 1376591 (BoneKnot.sgf) against SQ0002 16 MiB
headroom entries max 69 (Phos (P205).sgf) against SQ0003 256
headroom side max 9241 (Eletro.sgf) against SQ0005 16,384 px
headroom pixels max 5724136 (RedWood_Update.sgf) against SQ0006 64 Mpx
headroom ini max 28434 (project_arms.sgf) against SQ0007 256 KiB
```

- `version` is read from the first `[skin]` section only (decision record § *INI rules*). 17 skins
  write `version=` elsewhere and read as `none`: 15 in a second `[skin]` section, one in
  `[preferences]`, one in `[misc values]`. Whether Sonique reads the second `[skin]` is S4's oracle
  check.
- `greenwitch.sgf`, truncated in the source archive and kept out of the corpus, fails with
  `[SQ0004] /jpeg/skinthumb runs past the end of the file.`

## The oracle

Real Sonique 1.96 under Wine, driven by its own command line (`cmndline.htm`): `-loadskin <path>`
switches the running instance's skin and `-showwindow <1 small|2 mid|3 nav> <screen>` the mode.
Nothing is clicked, so captures are repeatable.

1. Name skins as they appear in the corpus directory.
2. Run the capture. Sonique starts if needed and its windows appear over the screen while it runs;
   about 8 s a skin.
3. Quit when done.

```bash
scripts/sonique_oracle_capture.sh /tmp/sonique-oracle Trigun.sgf BlueEyes.sgf
scripts/sonique_oracle_capture.sh --quit
```

**Confirm it took:** one line per skin reading `<skin> nav=1 mid=1 small=1`, and three PNGs per skin.
A `0` means no Wine window was on screen: Sonique failed to start, or a dialog replaced it.

- **A skin already captured is skipped**, so rerunning the same command resumes an interrupted
  corpus run. Delete a skin's PNGs to capture it again.
- **The skin must be in the prefix's `C:\Sonique\skins`**; the script refuses one that is not.
  Sonique draws its default skin for a path that does not exist, and that reads as a real capture:
  the first corpus run caught four skins missing from the prefix this way.
- **Every navigator capture shows the *setup › skins* screen** (the skin's thumbnail, title and
  author), not screen 1: loading a skin opens that screen, and `-showwindow 3 1` leaves it. The
  menu screen and the others are captured separately with `-showwindow 3 <n>`.

- Captures are window-only (`screencapture -l <id>`). Never capture the full screen: it is the
  user's screen.
- The first launch in a fresh prefix shows a *Register Sonique* dialog; dismiss it once by hand.
- Never pipe the script: the wineserver it starts holds the pipe open, so `| tail` never returns
  though the captures are done. Redirect to a file.
- `-showwindow 3 <n>` reaches the navigator's screens: 1 online tools, 2 playlist, 3 visual mode,
  4 setup, 5 about, 6 audio controls, 7 search. The script captures `1`.

### Outline comparison

Each mode's outline assembled from the skin (`format.md` § *Window outline*) against the window
outline the oracle drew. Run when region reading or window-shape assembly changes.

```bash
python3 -I scripts/sonique_outline_compare.py | grep -E '^SUMMARY|no-frame|default-drawer'
```

**Confirm it took:** three `SUMMARY` lines, one per mode, each with an outline count above zero.
Optional arguments are a captures directory and a corpus directory.

Per capture it prints `region=` (the assembled outline against the capture), `wine=` (after Wine's
distortion, below) and `unexplained=` (what is left that is not an unpainted white pixel). Measured
2026-10-11 on `captures/sample-2026-10-11`, and on 8C8-HQ, Danzig and skreen (all `wine=0`):

```text
SUMMARY nav: 11 outlines, region exact 3, wine exact 8, explained 9, default drawer 2
SUMMARY mid: 12 outlines, region exact 3, wine exact 7, explained 12, default drawer 0
SUMMARY small: 10 outlines, region exact 4, wine exact 6, explained 10, default drawer 0
```

- **The oracle's outline is Wine's, not Sonique's.** Wine converts the region Sonique sets into a
  1-bpp shape for macOS, and a run of a row that starts and ends inside one byte comes out as
  `[right, end of that byte)` instead of `[left, right)` (empty when `right` is the byte's end).
  Multi-byte runs are right at both edges. The byte phase is fixed by the skin's x = 0 sitting 3 px
  into the captured window. This was S3's "k2 mid is a different outline" (1,615 px → 8) and small
  mode's "default outline" for Pino, Splash and dm-candella (66 px → 4): their own small frame is
  Sonique's default shape. `wine_shape` in the script is the rule.
- **What is left after it is unpainted.** Every remaining oracle-only pixel is pure white: inside the
  shape macOS shows but outside the region Sonique set, which Wine clips painting to. Most are a
  run's last partial byte drawn full, on a handful of rows (Splash mid, 32 px); the rule for that is
  not known and buys nothing, since the renderer uses the region, not Wine's shape.
- `default-drawer` marks a navigator skin with no `/rgn/nav/drawer` (Pino, rwsonitek); the oracle
  adds the default skin's drawer, the same shape at 29,229 in both (identical pixel for pixel
  outside their frames). Its shape is S11's to measure.
- A capture's window starts 29 rows above the skin's y = 0 in nav and mid, and per skin in small
  mode (the window spans the closed drawers); the script aligns tops.

### Rebuilding the oracle install

Unpack `SoniquePortable.zip` from the archive, create a prefix with
`WINEPREFIX=<SoniqueOracle>/prefix wineboot -i`, copy `SoniquePortable/App/Sonique/` to
`drive_c/Sonique/`, and copy the corpus into `drive_c/Sonique/skins/`. Copy a skin added to the
corpus there too; the capture refuses one that is missing.

## The oracle sweep

The render probe's every mode of every skin against the oracle's capture of the corpus, against a
committed ratchet. Run after any change to drawing or layout; it is how S7–S9 are measured.

1. Capture the corpus through the oracle, once per change to the corpus or the oracle (about 80 min
   unattended, resumable; run it in batches if a shell times out). Captures are never committed.
2. Render the corpus in the oracle's state (§ *The render probe*, `SONIQUE_RENDER_STATE` unset).
3. Compare. About 25 s on all cores.

```bash
C="$HOME/Library/Application Support/NullPlayer/SoniqueOracle/captures/corpus-2026-10-17"
ls "$HOME/Library/Application Support/NullPlayer/SoniqueSkins" | tr '\n' '\0' | xargs -0 scripts/sonique_oracle_capture.sh "$C" > /tmp/sonique-capture.txt 2>&1
scripts/sonique_oracle_capture.sh --quit
python3 -I scripts/sonique_oracle_compare.py "$C" /tmp/sonique-render | grep -v '^ORACLE'
```

**Confirm it took:** `VERDICT 1572 compared` (three times the skin count) and three `SUMMARY` lines.
A `MISSING` line is a capture with no render.

Per skin and mode, in skin pixels (the capture halved; it is exact pixel doubling), the render placed
on the capture by the two outlines' top-left corners and the best of a ±2 px search:

| Count | Meaning |
|---|---|
| `shape` | inside one outline only, after Wine's distortion of the render's (`wine_shape`, § *Outline comparison*) and leaving out the oracle's unpainted white |
| `colour` | inside both, a channel more than 48 levels apart: what Sonique paints that the renderer does not, or paints differently. Two JPEG decoders disagree by a few levels |
| `area` | the oracle's outline |

`docs/sonique/oracle-baseline.tsv` is the ratchet: a count above its row prints `REGRESSION` and
exits 1; one below it prints `BETTER`, and `--record` rewrites the file. Only counts and skin names
are in it, never artwork. Record after a change that improves the counts, never to silence a
regression.

Measured 2026-10-18 at the commit that closed S10:

```text
SUMMARY nav: 524 compared, shape exact 86, shape 1.49%, colour 12.29% of 67176100 px
SUMMARY mid: 524 compared, shape exact 93, shape 4.69%, colour 7.61% of 30591336 px
SUMMARY small: 524 compared, shape exact 146, shape 4.39%, colour 9.29% of 2350770 px
```

What the counts are made of, from the worst cells:

- **`shape`, every mode: pure black inside the outline.** Sonique paints a picture's `0x000000`
  pixels black inside the window; the renderer keys them out, so they are holes (Danzig nav
  23,783 px, carrot mid, DE_maul small). Only the outline is transparent.
- **mid: the display windows.** Sonique paints `/rgn/mid/top` and `bottom` opaque black, with the
  track number and time in one and its own lettering in the rings (k2, carrot). S8.
- **nav `colour`: the screen.** Sonique draws setup › skins over the display (§ *The oracle*); the
  renderer draws nothing there yet. S7.
- **`colour` where a skin leans on the default skin**: NullPlayer's default artwork is not Sonique's
  (decision record § *Omitted entries*), so `lycossearch`, `hotbotsearch` and every omitted entry
  differ by design.
- The sweep found the drawer rule in `format.md` § *Window outline*: `MISC_DRAWER_POS` 0,0 is
  unwritten (Barrels 19,051 → 36 px, winson99 7,753 → 651).

## The render probe

Every mode of every skin through `SoniqueSkinRenderer`, the window's own draw path, one skin pixel
per pixel. Run when drawing changes. About 22 s for the corpus.

1. Render into a fresh directory; `SONIQUE_SKIN` takes what the census takes.
2. Put a render beside the oracle's capture of the same skin and mode (the capture is 2x).

```bash
source scripts/lib/swiftpm.sh
SONIQUE_SKIN="$HOME/Library/Application Support/NullPlayer/SoniqueSkins" SONIQUE_RENDER_OUT=/tmp/sonique-render \
  swift test ${SWIFTPM_ARGS[@]+"${SWIFTPM_ARGS[@]}"} --filter SoniqueSkinRenderProbeTests > /tmp/sonique-render.txt 2>&1
grep RENDERED /tmp/sonique-render.txt
```

**Confirm it took:** `RENDERED <n> of <n>`, three times the skin count, and one
`<skin>__<nav|mid|small>.png` per line.

| Flag | Meaning |
|---|---|
| `SONIQUE_RENDER_OUT` | the output directory; the probe skips without it |
| `SONIQUE_RENDER_STATE` | unset: the oracle's state (stopped, track 1, knobs at frame 0, as the prefix has no sound device). `playing`: lit play/stop, shuffle and repeat, small mode's drawer open, lines half full, full volume |

## The default skin

`Resources/Skins/NullPlayer-Sonique.sgf` is drawn by `scripts/sonique_default_skin.py`: NullPlayer's
artwork on regions copied from the corpus's `sonique.sgf` (Lycos's own "Original"), whose nav frame
and drawer and mid frame match the oracle's default outlines with 0 px differing, and whose small
frame differs only by Wine's distortion. The oracle draws the default skin for `lycossearch.sgf`
and `hotbotsearch.sgf`, which supply no mode picture at all. Rerun the script after changing it:

```bash
python3 -I scripts/sonique_default_skin.py
```

**Confirm it took:** `wrote …/NullPlayer-Sonique.sgf: 44 entries`. The script asserts no pixel
decodes to pure black, which Sonique would draw transparent.

## Launching the app on a skin

`skills/app-control/scripts/launch.sh sonique:<name>` (DEBUG builds only). Launch arguments, which
leave the saved selection untouched:

| Argument | Meaning |
|---|---|
| `-soniqueSkinName <name>` | the installed `.sgf` to show, without `.sgf` |
| `-soniqueSkinMode navigator\|mid\|small` | the mode to open in |
| `SONIQUE_PLACE_TRACE=1` (environment) | logs `[place/tile] hosted <frame>` when a NullPlayer window is first placed beside the player |

**Both arguments pin their setting for the whole launch.** They shadow the saved keys
(`soniqueSkinName`, `soniqueSkinMode`) in the argument domain. Choosing another skin or mode from
the menu saves it, but every read still returns the argument, so the window shows the launched skin
and mode again on the next reload. Relaunch to test a menu selection.

## What the harness cannot see

The render probe draws the default state and one playing state; the oracle captures only the
default state. Animation (the mode morph, the drawer slide, the progress rings filling), hover and
the knobs turning are invisible to both.
