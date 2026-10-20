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
| B163 | **Make the hosted-window registry exhaustive.** `WinampModernHostedWindowRegistry.all` is an array searched by `entry(id:)`, which returns an Optional, and every definition's `makeSurface` is Optional too, although every `WinampModernHostedWindowID` has an entry and every entry builds a surface. Three production callers (`WindowManager`, `WinampModernComponentBridge.makeHostedWindowSurface`, `WinampModernHostedWindowMaterializer`) guard a nil that cannot happen, about fifteen test lines `XCTUnwrap` it, and `WinampModernHostedProviderTests` asserts the two promises the types do not make. Give `WinampModernHostedWindowID` a `definition` built by an exhaustive `switch`, make `makeSurface` non-optional, and keep `all` as `allCases.map(\.definition)` for the synthesizer. A new hosted id then fails to compile without an entry rather than falling back at run time. No behaviour change. Done when `swift test` passes with the nil guards and the registration assertions gone | none on screen; every hosted window routes through it | S | 3 |
| B165 | **Let the hosted-frame descriptor carry a `WasabiSurfaceSynthesizer.Frame` instead of mirroring it.** `WinampModernHostedFrameDescriptor` has exactly `Frame`'s fields (`groupIdentifier`, `xuiTag`, `hasArtwork`, `exemplar`, `clientInsets`), and a `Frame` is rebuilt from it field by field in `WinampModernHostedWindowInstantiation.raised`, `WasabiSkinInitializer.instantiateHostedWindowAtRuntime` and three places in `WinampModernB140Tests`. A rebuild that dropped the client rect is what B140's second screenshot was, and every new frame field has to be threaded through all of them. Store the `Frame` in the descriptor (or replace the descriptor with it) so the rebuilds go away. While there, move `hasContentScript` and `hasArtwork` onto `inheritanceChain(of:definitions:)`, which `clientInsets(of:definitions:)` already uses, so no frame helper walks `inherit_group` by hand. No behaviour change. Done when `swift test` passes and no code builds a `Frame` from a descriptor's fields. Deferred from PR #559's review | none on screen; every hosted window wearing a skin frame routes through it | S | 3 |
| B211 | **Keep the corpus harnesses' skin settings out of each other's runs.** Every harness process (`wal_render_sweep.sh`, `wal_feature_index.sh`, the census, the motion and interaction sweeps) builds `WinampModernConfiguration` on `UserDefaults.standard`, which for `xctest` is the shared `com.apple.dt.xctest.tool` domain, so what one run's scripts store with `setPrivateInt` is the next run's starting state. Since B192 made `isChecked` work, the opensource notifier writes its checkboxes back at `onScriptUnloading`: the render sweep at `b3d4a676` drew EPS's and Itemskin's notifier prefs checked, the feature index run after it stored them as 0, and the next sweep drew them unchecked with no code change between them (B193's sweep, `fcc8d1fc`→`f25bccc6`). Give each harness run a fresh defaults suite, so a sweep is a function of the tree and not of the runs before it. Done when two sweeps with an index run between them are byte-identical bar the known nondeterministic pair | the corpus regression gate; every skin that persists private ints (`defaults find OpenNote` lists 8 skins today) | S | 2 |

### Corpus plan queue — work in progress

Order is the plan's S4 severity ladder, then its `skins × severity × visibility ÷ cost` within a
class. First, skin-dead: the quarantine's loader gaps (B173), most skins first. Then the MAKI demand
queue (B174), by priority, whose scoring is in B174's archive entry. Each severity rests on one or two
call sites, so re-check it when a row is taken.

| Id | Item | Reach | Effort | Tier |
|---|---|---:|:---:|---|
| B207 | **A `text` or `AlbumArt` a script hooks the mouse on is never under the pointer.** `isInteractive` (`WasabiRendererHitTesting.swift`) admits buttons, sliders, layers and objects with an `action=`; a `text` or `AlbumArt` whose only behaviour is a script binding is skipped, so a press falls through to the layout. Wasabi gives every non-ghost GuiObject its rect. The time readout that toggles elapsed/remaining is the visible case: `text#timer` on Defix and Ebonite, `text#s2timer` on Vortex; also TRON Legacy's `songticker`, EPS's `volumetext`, and Darjah's and Formamp's album art. Found by the interaction sweep (B205) as `covered:layout`. Admit an object a script binds a pointer event on; the renderer will need the binding answer from the runtime. Done when those seven read `works` or `silent` instead of `unreachable`, and a ghost text still passes clicks through | 7 skins in gold+silver (the sweep's `covered:layout` rows on `text`/`AlbumArt`, rev `f3ca6c5c`) | M | 2 |
| B208 | **Triage the interaction sweep's dead list.** B205's run (gold+silver, rev `f3ca6c5c`): 343 silent and 117 blocked gestures, 433 unreachable. Blocked calls the demand queue already holds are covered there (B182's events-as-methods, 47 gestures; `shutdown` B187, 16; `getViewport*FromPoint` B195, 16). Left: the skins mostly dead — machina 31/33, shark5 23/23, HeadAMP 27/32, Anunaki 44/60, wTunes 19/27, Dreliction 57/83 (mostly right-clicks and hover labels) — and `Layout.onAccelerator` (10, Alpha_Media_Player_X5), `sqr`, `getNumLayouts`. For each, read the handler and, where it is drawn at rest, the running app: is the control dead, or doing something the sweep does not see (a hover-only layer, a sound, a state another click needs first)? Done when each skin above has a filed row or a dismissal reason in the archive | 6 skins named, 117 blocked gestures (manifest 9e68ffe0) | M | 2 |
| B209 | **Motion-dead: a script `Timer` declared, no animated layer, nothing moves at rest** (S4 motion ranking, §3 S3 suspect rule). 27 Gold+Silver skins declare a `Timer`, no `animatedlayer`, and render byte-identically across the 0–4 s ladder in every window. Find which capability the samples' timers are waiting on (a host event the harness does not send, a handler blocked on a method, or nothing — a timer used only for interaction), working across the samples, not one skin. S4: 27 × motion-dead 2 × at rest 3 ÷ cost 1 (untuned) = 162. Done when the cause is named for the class, fixed or dispositioned, and `wal_motion_sweep.sh`'s `ranking.tsv` re-measures the row | suspect skins: 27 of 114 Gold+Silver (`ranking.tsv`, rev `b24690b3`); samples canum, Core-X5, Darjah 1 | M | 2 |
| B210 | **Motion-dead: an `animatedlayer` that never plays at rest** (S4 motion ranking, §3 S3 cause "never played"). 23 suspect Gold+Silver skins declare animated layers whose play head never starts and whose windows never change. Find which capability starts them in Winamp and not here (an event the harness does not send, `autoplay` semantics, a blocked handler), across the samples. S4: 23 × motion-dead 2 × at rest 3 ÷ cost 1 (untuned) = 138. Done when the cause is named for the class, fixed or dispositioned, and `ranking.tsv` re-measures the row | suspect skins: 23 of 114 Gold+Silver (`ranking.tsv`, rev `b24690b3`); samples --Vortex--, Dreliction, Anaheim_Player_01 | M | 2 |

### Awaiting manual QA

| Id | Item | Remaining check |
|---|---|---|
| B41 | `getMonitorWidth` / `getMonitorHeight` | Needs a second display. Load Big Bento Modern, move the player to it, open the right-side playlist and toggle **Enlarge Playlist**; the column must size against the player's display, with no 2x oversizing on Retina. Repeat back on the primary display |
| B85 | The Widgets Manager's three place buttons | On a cPro skin: drawer menu -> *Widgets Manager*, then **show in main / drawer / side** on a row. Uninstall and support are expected to stay inert |
| B66 | The Wasabi drop-down's persistence | On Styx's Config, pick a `Position` drop-down entry, reopen the window, confirm the pick survived |
| B110 | Ebonite's frame overlay windows ([record](../docs/winamp-modern/backlog-archive.md#b110--a-skins-window-frame-can-be-a-second-window--implementation-record)) | Reporter's confirmation that Ebonite's frames draw, stay glued and stack correctly |
| B183 | Notifier click raises a minimized player | Minimize the player on jvc.tape, let a track change raise its notifier, click the notifier; the player must come back in front |
| B186 | `windowMenu()` | Right-click Winamp 3.0 Default's Thinger; the window list must open at the pointer |
| B187 | `Application.shutdown()` | Double-click cPro2 minimal's system-menu button; the app must quit |
| B188 | Scripted next/previous | Nitrous Audio CTI 2 Glass's next button must skip the track |
| B194 | `setEq(onoff)` | With the EQ off, turn mmd3's bass knob; the EQ must switch on |
| B196 | Clock fields | Ebonite's clock must show the time |
| B197 | `eject()` | `_Scythe`'s eject button must open the file dialog |
| B199 | `minimizeApplication()` | Big Bento Modern's scripted minimize must minimize the player |
| B200 | `isObjectValid` | Dreliction's winshade menu must tick the current layout |
| B182 | Events called as methods | Resize Bio-Nid's playlist editor; the `poppler` handle must follow the pointer |
| B184 | `getAlbumArt` | Right-click Ebonite's album art while a track with art plays; its menu must open |
| B185 | `getAttributeName` | Symplicipod's attribute toggles must show their saved state |
| B195 | `getViewport*FromPoint` | Hover a Shield_Amp control; its tooltip must appear on the same display |
| B201 | `Layout.center()` | Open one of 1010 Fullscreen's frame windows; it must open centred |
| B189 | `Edit.setAutoEnter` | Open 1010 Fullscreen's cover config page; its path and value fields must fill |
| B198 | `TabSheet.setCurPage` | Bio-Nid's search toggle must switch the playlist sidecar's page |
| B193 | `WindowHolder.getComponentName()` | Open cPro Venus's drawer on a component; its tab must show the component's name |

## Agent-verifiable without user input

Triaged 2026-09-27 against the `app-control` tools: `launch.sh`, `winhelper`
(`click`/`dblclick`/`drag`/`move`/`scroll`/`clickdiff`/`capture`/`screens`), `menu.applescript`,
the window census and the render-dump harness.

**Verifiable.** B162: `swift test` plus a `winhelper drag` of Pure Inspired's player with the
playlist docked, reading the glue trace. B163: `swift test`.

**Partly verifiable.** B66 and B85: the drop-down and the drawer menu may be contextual menus; if
a synthetic press does not open them, they are Route D.

**Needs the user.** B41 needs a second display (`winhelper screens` shows one). B110 waits on the
reporter's confirmation.

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
