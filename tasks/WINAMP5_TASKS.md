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
| B216 | **The `.wal` tiler's last-resort placement now moves `.wmz` windows too, and nobody has looked.** `WindowManager.tiledOrigin(for:avoiding:)` is also WMP's placement (`WMPViewWindowMaterializer`, and the `hostsForeignSkin` branch of the sub-window opener), and the tiler behind it now weighs the region's corners and picks the least-covered candidate, with the player counted 4×, instead of rescuing the last slot. Run the window census over the `.wmz` corpus before and after that change (`window-census`), and file any window that moved onto the player or off its old spot for the worse. Done when the census diff is read and every moved window is either accepted or filed. **Deferred 2026-10-20**: the census is a multi-hour machine-takeover run, so it waits for the user's go-ahead. The cleanup that followed it is done: `WinampModernTiler` is a top-level struct in `App/WinampModernTiler.swift`, `leastCovered` weighs a named `player` rect and takes a non-empty candidate list | code health; no corpus demand | S | 3 |
| B233 | **One presentation path for `.wal` frames, owned by `WinampModernFrames`.** Today:<br>• **Two paths to the layer.** `setNeedsDisplay` requests a frame *and* calls `super`, so every invalidation also runs `updateLayer → showFrame`, which re-assigns the picture already shown.<br>• **Two whole-frame triggers.** `canvas.isFresh` decides the synchronous render in `pumpFrame`; a picture-size compare decides another in `showFrame`, which ignores `isInFlight`. Only that bypass needs the three frame numbers (`pictureNumber`, `outlineNumber`, `nextNumber`).<br>• **A builder that switches modes.** `makeJob` flips `drawsDirectly`, clears `layer.contents`, calls `super.setNeedsDisplay` and returns nil both for "oversized" and for "nothing to draw".<br>• **The logic lives on the view.** `WinampModernFrames` is eleven mutable fields whose state machine is a view extension, which is why `pressedObject`, `hoveredObject` and `repaintDeferredWhileHidden` lost `private`.<br>The fix: present only from `show()`. Handle size, backing and the oversized switch at `setFrameSize`/`viewDidChangeBackingProperties`, pumping one whole frame through the same queue. Give `WinampModernFrames` the scheduling, with `record` and `present` closures. Done when frames land strictly in order with at most one number, `makeJob` has no side effects, scheduling has unit tests (partial equals whole, outline change), and a live resize, a display move and Anunaki's drawer slide still show no stale frame | code health; no corpus demand | M | 3 |
| B235 | **The harness's `WasabiSceneRenderer.draw(in:)` assembles its canvas job apart from the window's.** B231 made the sweep render through `WinampModernCanvas`, but the job is built twice: `draw(in:)` computes its own scale, pixel snap and `Job`, and the view's `makeJob` (`WinampModernMainView+Frames.swift`) does the same from the bounds, and adds `skinScale` and the host chrome the harness never applies. The oversized fallback is written twice as well (`draw(in:)`'s direct list and `drawDirectly`). So the sweep checks the canvas, not the recording the window does. The fix: one job builder (scale, pixel rect, clip, colour space, optional chrome list) that both call, which lands with B233's side-effect-free `makeJob`. Done when `draw(in:)` and the view share that builder and the oversized path, and the gold+silver render sweep at 1x, 2x and 2.5x matches its baseline bar the noise listed in `harness.md` | code health; no corpus demand | S | 3 |
| B236 | **B230's split widened about fifty script-runtime members from `private` to internal, mutable state included.** `mapImages`, `bitmapSizes`, `eventsBeingDispatched`, `runtimeScriptStartDepth` and the per-concern caps are now writable from any file in the module, because a cross-file extension cannot see `private`. The concerns that own their state should be types the runtime holds: the Map image cache (`WinampModernScriptRuntimeMap.swift`), the XmlDoc reader, and the signature tables (pure static data, a plain `enum`). `WinampModernScriptRuntime.swift` is still 1,340 lines; `…Object.swift` (997) and `…System.swift` (973) sit at the limit. Done when each extracted concern keeps its state `private` behind its own type, no runtime state is internal only for an extension's sake, and the interaction sweep matches its baseline | code health; no corpus demand | M | 3 |
| B237 | **Thirteen sites ask `tag.kind ==`, which matches any namespace, carried over from `localTypeName` without a decision.** `WasabiGuiList.isList` counts a `<ColorThemes:List>` as a script list (so `addItem` and the rest dispatch on it), while the draw dispatch's `tag.is(.list)` does not; the same any-namespace match sits in the edit, menu, text, album-art and custom-object checks. Decide per site whether a foreign namespace belongs (Wasabi's own answer is the registered class, not the spelling), and write it as `tag.is(_:in:)`. Done when no `tag.kind ==` remains outside `WasabiTag`, and the render and interaction sweeps match their baselines or every diff is judged | `xml-tag '^colorthemes:list$'`: gold 23/56, silver 20/54, bronze 187/827, quarantine 18/54 (manifest 9e68ffe0) | S | 3 |

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
