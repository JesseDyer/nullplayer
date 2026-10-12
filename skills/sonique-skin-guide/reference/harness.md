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

Run when the corpus or the format reading changes.

```bash
python3 -I scripts/sonique_census.py > /tmp/sgf-census.txt; head -3 /tmp/sgf-census.txt
```

**Confirm it took:** the first line reads `files=… unique=… parsed=… failed=0 malformed_regions=0`.

Measured 2026-10-11: `files=524 unique=524 parsed=524 failed=0 malformed_regions=0`; spec version
none 274, 105 233, 100 10, other 7. `greenwitch.sgf` was truncated in the source archive and is not
in the corpus. This is pre-engine tooling; the engine's own census replaces it (S2).

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

### Rebuilding the oracle install

Unpack `SoniquePortable.zip` from the archive, create a prefix with
`WINEPREFIX=<SoniqueOracle>/prefix wineboot -i`, copy `SoniquePortable/App/Sonique/` to
`drive_c/Sonique/`, and copy the corpus into `drive_c/Sonique/skins/`.

## What the harness cannot see

It has no renderer to compare yet. Until the engine exists, the oracle captures are the reference
the engine is built against, not a gate. Animation (the mode morph, the drawer slide, the progress
rings filling) is invisible to a still capture.
