# Winamp 5.x Modern Skins (`.wal`) — open backlog

This is the only live backlog for the Winamp Modern subsystem. A skin is a test case, not a
milestone. Closed entries move to
[`docs/winamp-modern/backlog-archive.md`](../docs/winamp-modern/backlog-archive.md) in the same change
that closes them. A row that is stale, a question rather than work, or self-described as not worth
doing moves to [`LOW_QUALITY_TASKS.md`](LOW_QUALITY_TASKS.md). This file holds tasks; how the engine
works belongs in `skills/winamp-modern-skin-guide/`.

**The work is the *Corpus plan queue* below, top down**, by the loop in
[`docs/winamp-modern/corpus-runner-plan.md`](../docs/winamp-modern/corpus-runner-plan.md):
implement, re-measure, close into the archive. No new instruments.

## Columns

Reach is corpus demand, not severity. Live-reported draw defects are kept in their own tier because a screenshot or runtime
observation is not comparable to a static declaration count.

Effort bands: **S** = one attribute/method/local draw fix; **M** = behavior spanning multiple files
without a seam change; **L** = a host seam, protocol change, or new fixture harness.

### Measured capability gaps

| Id | Item | Reach | Effort | Tier |
|---|---|---:|:---:|---|
| B161 | **A press in the outer few points of a resizable `.wal` window is AppKit's, and it moves one edge even at a corner.** The skin's auxiliary windows are `[.borderless, .resizable]`, so AppKit's own edge band takes the press before `WinampModernMainView.mouseDown` and the skin's `resize="bottomright"` layer never sees it. Measured 2026-09-30 with `WINAMP_MODERN_RESIZE_TRACE=1` on Itemskin: a press 8pt in from the playlist frame's bottom-right corner, dragged +60,+30, logged `live=true handle=false` and changed the width only; 13pt in on the PeppyMeter frame, dragged +30,+60, changed the height only. 20pt in, the same drags logged `handle=clear.bottom.right` and moved both axes. Decide whether the band should defer to a skin handle under the pointer, or the windows should drop `.resizable` where the layout declares handles. Found during B160; not changed by it | `xml-attr '@resize$'` (a skin resize handle, an upper bound — the index does not say which window): gold 43/56, silver 46/54, bronze 743/827, quarantine 44/54 (manifest 9e68ffe0) | S | 2 |
| B213 | **No tooltip ever shows in Winamp Modern mode.** The view sets no `toolTip` and the host never builds the skin's tooltip window, so a control's `tooltip=` is never shown and the stock `tooltips.m` (`tipText.onTextChanged`, which places the tip with `getViewport*FromPoint`, B195) never runs. Found running B195's in-app check on Shield_Amp: hovering the play button for 2 s shows nothing. Winamp shows the skin's `wasabi.tooltip.group` (or its own default) at the pointer after a hover delay and sets its `tooltip.text`. Done when hovering Shield_Amp's play button shows its tip, drawn by the skin's group, on the pointer's display | `xml-attr '@tooltip$'`: gold 47/56, silver 47/54, bronze 740/827, quarantine 48/54 (manifest 9e68ffe0); the stock tooltip script, `maki-call '[.]getviewportleftfrompoint$'`: gold 13/56, silver 3/54, bronze 9/827, quarantine 4/54 | L | 2 |
| B215 | **A skin's own playlist-editor group is never built; the host's list fills the playlist component instead.** The Bio-Nid lineage defines `pledit.main.group` (the editor, the `pledit.poppler` splitter, the sidecar tab sheet, `scripts/playlisteditor.maki`), and the layout's content is the playlist component `guid:{45F3F7C1-A6F3-4ee6-A15E-125E92FC3F8D}`. In NullPlayer the component is the host's list, so the group, its script and the poppler never exist (venom: no `pledit.poppler` call in the trace with the playlist open). Bio-Nid itself pulls the group from `@DEFAULTSKINPATH@`, which no archive ships. Found running B182's and B198's in-app checks, which this blocks. First establish what Winamp's playlist component does with a skin-defined `pledit.main.group`, then decide whether the host instantiates it around its list | skins shipping `playlisteditor.maki` (zip listing): gold 3/56, silver 2/58, bronze 20/827 | L | 2 |

### Corpus plan queue — work in progress

Order is the plan's S4 severity ladder, then its `skins × severity × visibility ÷ cost` within a
class. First, skin-dead: the quarantine's loader gaps (B173), most skins first. Then the MAKI demand
queue (B174), by priority, whose scoring is in B174's archive entry. Each severity rests on one or two
call sites, so re-check it when a row is taken.

| Id | Item | Reach | Effort | Tier |
|---|---|---:|:---:|---|
| B212 | **Run B41's in-app check, which needs a second display.** Load Big Bento Modern, move the player to the second display, open the right-side playlist and toggle **Enlarge Playlist**; the column must size against the player's display, with no 2x oversizing on Retina. Repeat back on the primary display. `winhelper screens` shows one display, so this waits on the hardware. The other twenty checks were run 2026-10-20 (archive, *B212*). Done when B41 has a pass, or a filed row for what it found | B41 | S | 2 |

## Agent-verifiable without user input

Triaged 2026-09-27 against the `app-control` tools: `launch.sh`, `winhelper`
(`click`/`dblclick`/`drag`/`move`/`scroll`/`clickdiff`/`capture`/`screens`), `menu.applescript`,
the window census and the render-dump harness.

**Hardware.** B212 (B41's check) needs a second display (`winhelper screens` shows one). Every
other in-app check is agent work: a contextual menu is `winhelper rclick` plus Accessibility, and a
script-built menu Accessibility does not expose is read with `capture-region` and clicked by position.

## Reach

A measured row's Reach is one query over the static feature index, pasted as printed:

```bash
scripts/wal_reach.sh <kind> <feature-regex>   # -> gold a/A, silver n/N, bronze m/M, quarantine q/Q (manifest <rev>)
```

The manifest rev is the denominator's identity: figures under different revs are not comparable. A
skin is its content, so the four silver re-adds of gold skins count once, as gold. The index is
`WinampModernCorpus/index/features.tsv`; rebuild it over every tier after an intake
(`harness.md` → *The static feature index*), and the script fails on an index the manifest has
outgrown. Code-health and corpus-scale rows have no corpus demand and say so instead. A row whose
Reach needs more than the query (a grep over an extract, a runtime count) keeps that command in its
cell, and the command moves into its archive entry when the row closes.

## Backlog hygiene check

Run before committing backlog changes:

```bash
scripts/validate_winamp_modern_backlog.sh WINAMP5_TASKS.md
```
