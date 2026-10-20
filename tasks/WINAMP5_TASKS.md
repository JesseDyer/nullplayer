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

### Code health

| Id | Item | Reach | Effort | Tier |
|---|---|---:|:---:|---|
| B162 | **Move the script-glue code out of `WinampModernMainWindowController.swift`.** The file is ~2,900 lines, and the glued-window code sits in two places ~800 lines apart. One part is `moveCarryingGluedWindow`, `gluedPartner(of:)`, `gluedWindow(over:)` and `gluedWindowPairs`. The other is `restackGluedWindows`, `attachGluedWindowsForDrag`/`detachGluedWindowsAfterDrag`, their `dragObservers` and `dragAttachedGluedWindows`, and the `tracesGlue`/`carriesGluedWindowsInDrag` switches. An extension file cannot carry the stored state and cannot reach the controller's private `skinView`/`viewsByContainer`. So give the glue its own small type that owns the drag observers and linked pairs and gets the pairs from the controller, leaving one property on the controller. No behaviour change. Done when `swift test` passes and a drag of Pure Inspired's docked playlist under `WINAMP_MODERN_GLUE_TRACE=1` still prints `drag carries` and `restacked` lines. Deferred from PR #468 to keep that diff a behaviour fix | none on screen; the glue-pair skins (Ebonite, Itemskin, Pure Inspired, K-jr, MoonLight) exercise it | M | 3 |

### Corpus plan queue — work in progress

Order is the plan's S4 severity ladder, then its `skins × severity × visibility ÷ cost` within a
class. First, skin-dead: the quarantine's loader gaps (B173), most skins first. Then the MAKI demand
queue (B174), by priority, whose scoring is in B174's archive entry. Each severity rests on one or two
call sites, so re-check it when a row is taken.

| Id | Item | Reach | Effort | Tier |
|---|---|---:|:---:|---|
| B212 | **Run the closed rows' in-app checks with `app-control`.** Each was closed on its headless numbers; the check in the app is agent work (`launch.sh`, `winhelper`, Accessibility for menus, `capture-region` for a script menu Accessibility does not expose). Already run: B196 (Ebonite's timer reads the time when stopped), B184 (BLAKK's remote album-art menu, then `getAlbumArt` → 1), B207 (Ebonite's timer right-click opens its clock menu). Left: **B41** Needs a second display. Load Big Bento Modern, move the player to it, open the right-side playlist and toggle **Enlarge Playlist**; the column must size against the player's display, with no 2x oversizing on Retina. Repeat back on the primary display; **B85** On a cPro skin: drawer menu -> *Widgets Manager*, then **show in main / drawer / side** on a row. Uninstall and support are expected to stay inert; **B66** On Styx's Config, pick a `Position` drop-down entry, reopen the window, confirm the pick survived; **B110** Reporter's confirmation that Ebonite's frames draw, stay glued and stack correctly; **B183** Minimize the player on jvc.tape, let a track change raise its notifier, click the notifier; the player must come back in front; **B186** Right-click Winamp 3.0 Default's Thinger; the window list must open at the pointer; **B187** Double-click cPro2 minimal's system-menu button; the app must quit; **B188** Nitrous Audio CTI 2 Glass's next button must skip the track; **B194** With the EQ off, turn mmd3's bass knob; the EQ must switch on; **B197** `_Scythe`'s eject button must open the file dialog; **B199** Big Bento Modern's scripted minimize must minimize the player; **B200** Dreliction's winshade menu must tick the current layout; **B182** Resize Bio-Nid's playlist editor; the `poppler` handle must follow the pointer; **B185** Symplicipod's attribute toggles must show their saved state; **B195** Hover a Shield_Amp control; its tooltip must appear on the same display; **B201** Open one of 1010 Fullscreen's frame windows; it must open centred; **B189** Open 1010 Fullscreen's cover config page; its path and value fields must fill; **B198** Bio-Nid's search toggle must switch the playlist sidecar's page; **B193** Open cPro Venus's drawer on a component; its tab must show the component's name. Blocked 2026-10-19 by a locked screen (`CGSSessionScreenIsLocked`). Done when each has a pass, or a filed row for what it found | the 21 rows listed | M | 2 |

## Agent-verifiable without user input

Triaged 2026-09-27 against the `app-control` tools: `launch.sh`, `winhelper`
(`click`/`dblclick`/`drag`/`move`/`scroll`/`clickdiff`/`capture`/`screens`), `menu.applescript`,
the window census and the render-dump harness.

**Verifiable.** B162: `swift test` plus a `winhelper drag` of Pure Inspired's player with the
playlist docked, reading the glue trace. B163: `swift test`.

**In the app, by the agent.** Every check in B212, including B66's drop-down and B85's drawer menu:
a contextual menu is `winhelper rclick` plus Accessibility, and a script-built menu Accessibility
does not expose is read with `capture-region` and clicked by position. B41 alone needs hardware: a
second display (`winhelper screens` shows one).

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
