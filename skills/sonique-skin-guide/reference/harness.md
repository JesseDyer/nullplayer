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
- `-showwindow 3 <n>` reaches the navigator's screens: 1 online tools, 2 playlist, 3 visual mode,
  4 setup, 5 about, 6 audio controls, 7 search. The script captures `1`.

### Outline comparison

Each skin's `/rgn/<mode>/frame` against the window outline the oracle drew, reading `right`/`bottom`
as exclusive and as inclusive. Run when region reading or window-shape assembly changes.

```bash
python3 -I scripts/sonique_outline_compare.py | grep -E '^SUMMARY|no-frame'
```

**Confirm it took:** three `SUMMARY` lines, one per mode, each with a frame count above zero.
Optional arguments are a captures directory and a corpus directory.

Measured 2026-10-11 on `captures/sample-2026-10-11`:

```text
SUMMARY nav: 11 frames, exclusive closer 8, exclusive exact 0, inclusive exact 0
SUMMARY mid: 12 frames, exclusive closer 11, exclusive exact 3, inclusive exact 0
SUMMARY small: 10 frames, exclusive closer 10, exclusive exact 4, inclusive exact 0
```

- The outline's `oracle=` fingerprint is its cropped 1x mask. Small mode's `67659b3a` is the shape
  Sonique draws for a skin with no small frame (fluffy, rwsonitek), and it also draws it for Pino,
  Splash and dm-candella, which do have one. Why is S12.
- k2's mid mode is the one mid frame the exclusive reading does not win, and it misses by ~2,800
  pixels either way: a different outline, not a different edge rule.

### Rebuilding the oracle install

Unpack `SoniquePortable.zip` from the archive, create a prefix with
`WINEPREFIX=<SoniqueOracle>/prefix wineboot -i`, copy `SoniquePortable/App/Sonique/` to
`drive_c/Sonique/`, and copy the corpus into `drive_c/Sonique/skins/`.

## What the harness cannot see

It has no renderer to compare yet. Until the engine exists, the oracle captures are the reference
the engine is built against, not a gate. Animation (the mode morph, the drawer slide, the progress
rings filling) is invisible to a still capture.
