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
| B216 | **The `.wal` tiler's last-resort placement now moves `.wmz` windows too, and nobody has looked.** `WindowManager.tiledOrigin(for:avoiding:)` is also WMP's placement (`WMPViewWindowMaterializer`, and the `hostsForeignSkin` branch of the sub-window opener), and the tiler behind it now weighs the region's corners and picks the least-covered candidate, with the player counted 4×, instead of rescuing the last slot. Run the window census over the `.wmz` corpus before and after that change (`window-census`), and file any window that moved onto the player or off its old spot for the worse. Done when the census diff is read and every moved window is either accepted or filed. Afterwards move `WinampModernTiler` (a nested struct in the 8.4k-line `App/WindowManager.swift`) into its own file under `App/`, and give `leastCovered`'s player weighting a named player rect instead of `placed[0]` | code health; no corpus demand | S | 3 |
| B217 | **One accessor for a Wasabi type's local name.** `typeName.lowercased().components(separatedBy: ":").last` appears 14 times across `WinampModern/` and `Windows/WinampModern/`, and comparisons next to it sometimes use the full lowercased `typeName` instead (`WasabiSkinInitializer`'s embedded `text` vs `button` checks), so `Wasabi:Button` and `button` match differently from one line to the next. Add `WasabiObject.localTypeName`, route every copy through it, and decide case by case whether the full-name compares should use it too. Fold `WasabiSceneRenderer.isTextButton`/`drawTextButton` into the plain-button label path at the same time: an `embed_xui` text button (WinampAzenis2's `Wasabi:Button`) currently draws its fallback label on the wrapper *and* its real label on the embedded `<button>`, and only the grid painted between them hides the first one. Done when one rule draws a button's label and the corpus render sweep is byte-identical | code health; no corpus demand | M | 3 |
| B218 | **Resolve a track-folder cover at one seam, the bitmap lookup.** `WinampModernTrackFolderImage` is consulted at nine call sites: `WinampModernScriptRuntime` `bitmapSize`, `animationFrameCount`, `mapImage`; `WasabiRenderer`'s layer draw; and `WinampModernScriptRuntimeObject`'s `setXmlParam` guard, its `noteCoverRequest` on `setXmlParam`/`getLength`/`loadMap`, and `getValue`. The matching also sits in a `WinampModernHost` protocol extension. A cover is a bitmap with a dynamic source: answer it from the lookup that `resources.bitmap(identifier:)`, `mapImage` and `bitmapSize` already share, and record the seeker there, so drawing, `getLength`, `getWidth` and `setXmlParam` need no branch of their own. Only `getValue`'s ≥1 floor and the 0-frame "not found" count stay special, behind the same seam. Done when no caller outside that seam names the cover, the cover tests pass, and Mac OS X Panther, Ebonite and Drone still show the playing track's art in-app | code health; no corpus demand | M | 3 |
| B220 | **Make the script runtime's window-side hooks a typed delegate.** `WinampModernScriptRuntime` carries 31 optional `…Requested` closures, and its teardown list nils them by hand and has drifted: `equalizerPreampSetterRequested`, `equalizerEnabledSetterRequested`, `applicationRaiseRequested`, `applicationMinimizedRequested` and `windowMenuRequested` are never cleared. Move them onto a protocol that `WinampModernMainView`/the window controller implement, held weakly, so a missing hook is a compile error and teardown is one assignment. Done when the closures are gone, teardown clears one reference, and `swift test` plus a skin switch in-app pass | code health; no corpus demand | L | 3 |
| B221 | **Break up `WasabiSkinInitializer.createObjects`.** About 430 lines, with nested `buildHostedWidgetBody` and `inherit` closures, and a `skinClaimedObjects` instance set that is never cleared and only carries one node's claim to a later recursion. Move the `embed_xui` forwarding into its own type driven by a table of key groups by embedded type (range, commands, text styling, button label, structure), mark a skin's claim with an attribute as `nullplayer.embedxui` already does, and make the hosted-widget body a method. Done when the function no longer nests helpers, the set is gone, and the corpus render sweep is byte-identical | code health; no corpus demand | M | 3 |
| B222 | **Add the playlist command bar only where it is wanted, instead of adding it everywhere then hiding it.** `createObjects` builds the bar into every playlist `<LayoutStatus>` with a `nullplayer.pe.` id prefix, then `WasabiStandardFrames.hidePlaylistCommandBarsBesideSkinButtons` sets `visible=0` wherever the layout has the skin's own `PE_Add`. Build it in that post-pass, only where no `PE_Add` exists; the prefix marker, the hide and the per-node check in `createObjects` go. Done when JRS still shows the bar, the 89 own-button skins show none, and the render sweep is byte-identical | code health; no corpus demand | S | 3 |
| B223 | **Model a script-made GUI object before `init` as a `DynamicRole`.** `DynamicObjectState.guiType` is an optional beside `role`, and `invokeDynamic` opens with three `state.guiType != nil` checks for `setXmlParam`, `getXmlParam` and queued calls. Make it `DynamicRole.pendingGUI(type:attributes:calls:)`, so the pre-`init` state is one case of the switch. Done when `guiType`/`pendingAttributes`/`pendingCalls` are gone from the state and the `new Text`/`init` tests and Nitrous Audio's playlist and 1010 Fullscreen's analyzer still build in-app | code health; no corpus demand | S | 3 |
| B225 | **Bring the script-runtime files back toward 1k lines.** `WinampModernScriptRuntimeSystem.swift` crossed 1k (929 → 1,100) with the date/clock fields, viewport/monitor answers and `showWindow`/`getWac`/`getMainBrowser`; `…RuntimeObject.swift` grew 1,252 → 1,500 with about forty `invokeGUI` cases (snap-adjust, layout enumeration, bring-above/below, vis mode, edit, tab sheet). Split them along those lines, as `…RuntimeWidgets.swift` was. While there, build the `nullplayer.snapadjust.` key in one place (it is built in three) and replace the frame-events and target-animation timer ids' magic high bits with one enum of timer-id namespaces. Done when no runtime extension file is past 1k lines and `swift test` passes | code health; no corpus demand | M | 3 |
| B226 | **Defer the main menu without a flag around `performAction`.** `WinampModernMainView.holdsMenuForDoubleClick` is set before `performAction` and read inside `showMainMenu`, so the menu's timing depends on state set two calls away (B187). Decide the deferral at the release site and pass it to the action instead. Done when the flag is gone and cPro2 minimal's system button still opens the menu on one click and shuts down on two | code health; no corpus demand | S | 3 |

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
