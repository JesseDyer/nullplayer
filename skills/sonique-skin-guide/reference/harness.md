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
| Oracle captures | `SoniqueOracle/captures/` |
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
findings {'SQ0009': 18, 'SQ0010': 11}
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
`drive_c/Sonique/`, and copy the corpus into `drive_c/Sonique/skins/`.

## What the harness cannot see

It has no renderer to compare yet. Until the engine exists, the oracle captures are the reference
the engine is built against, not a gate. Animation (the mode morph, the drawer slide, the progress
rings filling) is invisible to a still capture.
