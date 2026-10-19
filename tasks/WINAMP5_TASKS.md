# Winamp 5.x Modern Skins (`.wal`) — ranked open backlog

This is the only live backlog for the Winamp Modern subsystem. A skin is a test case, not a
milestone: take measured capability work from the top down. Closed entries move to
[`docs/winamp-modern/backlog-archive.md`](../docs/winamp-modern/backlog-archive.md) in the same change
that closes them. A row that is stale, a question rather than work, or self-described as not worth
doing moves to [`LOW_QUALITY_TASKS.md`](LOW_QUALITY_TASKS.md). This file holds tasks; how the engine
works belongs in `skills/winamp-modern-skin-guide/`.

**The corpus work follows one plan:
[`docs/winamp-modern/corpus-runner-plan.md`](../docs/winamp-modern/corpus-runner-plan.md).** Its
status line says what is built, and §7 is the build order. Take the next corpus step from §7, not
from a list of loose ends. When a corpus row closes, update the plan's status line in the same change.

## Ranking

Measured items are ordered by reach, with effort as an advisory tiebreaker. Reach is corpus demand,
not severity. Live-reported draw defects are kept in their own tier because a screenshot or runtime
observation is not comparable to a static declaration count.

Effort bands: **S** = one attribute/method/local draw fix; **M** = behavior spanning multiple files
without a seam change; **L** = a host seam, protocol change, or new fixture harness.

### Measured capability gaps

| Id | Item | Reach | Effort | Tier |
|---|---|---:|:---:|---|
| B175 | **Accept animation strips longer than 8,192 px on a side.** The image guard rejects any side past 8,192 even when the image is far under its 32,000,000-pixel budget, and a long animation strip is exactly that shape: `vu-meter_smooth.png` 98×17018 (three skins), `orb.anim.png` 15360×46, `waterstrip.png` 10320×344. The whole skin fails to load. Keep the pixel budget; decide what the per-side cap protects (a texture limit?) and slice or downscale the strip there instead of refusing the skin. Done when the 18 load with their strips animating, and a crafted image over the pixel budget is still refused | skin-dead: census `FAILED [imageDimensionsExceeded]`, quarantine 18/54 (list in B173's archive entry) | M | 2 |
| B176 | **Tolerate the XML mistakes Winamp's parser forgives.** An unterminated `<!--` at end of file (Assmosis, PioNner3, RayPlayer, SleekyXtra) and a stray closing tag (`</elements>`, `</groupdef>`, `</gammaset>`, `</WinampAbstractionLayer>`) fail the whole skin; these are published skins, so Winamp loaded them. Recover the way Winamp's parser did (close a dangling comment at EOF, drop an unmatched close tag), with a warning finding. Done when the 13 load and every recovery reports a finding | skin-dead: census `FAILED [malformedXML]`, quarantine 13/54 | M | 2 |
| B177 | **Find the skin root the way Winamp does.** Root detection refuses an archive with two `skin.xml` (a root one plus `player/skin.xml` or an old `2004/skin.xml`: 8 skins), a stray file beside the single wrapper (AniTransformers' `.avs`), and a `skin.xml` under more than one wrapper (MalteseXp, four deep). Take the shallowest `skin.xml` as the root, ignore files outside it, and keep the VFS bounded to it. Done when the 10 load and the root is reported in the census | skin-dead: census `FAILED [invalidRoot]`, quarantine 10/54 | S | 2 |
| B178 | **A skin group that overrides a `wasabi.*` system group by inheriting its own id.** `_Mercury`, `Bubble_Tea`, `Official_Coldplay` (`wasabi.titlebox`) and both `Graviton`s (`wasabi.tabsheet`) define a group with the system group's id that inherits that same id, meaning "the previous definition". We report a cycle and fail the skin. Resolve the inherit against the definition being overridden. Done when the 5 load and a true cycle still fails | skin-dead: census `FAILED [groupInheritanceCycle]`, quarantine 5/54 | M | 2 |
| B179 | **cPro skins that need the engine's `miniexes.xml`.** `cPro_SC`, `Cpro_Tokio` and `CPro_Winamp3000` include `/Plugins/classicPro/engine/miniexes.xml`, which the imported ClassicPro engine does not provide, perhaps because it is a different engine version. Find which version ships it and whether a missing include can degrade instead of failing. Done when the 3 load or are recorded as needing an engine we cannot ship | skin-dead: census `FAILED [resourceMissing]` on the cPro engine, quarantine 3/54 | S | 2 |
| B180 | **One bad resource reference fails the whole skin.** VANDREAD and VISION point an image at the author's own `c:/…/pic1.jpg`; Slim names `scripts/TimeDisplay.maki ` with a trailing space. Keep refusing host paths, but degrade (a missing-bitmap finding) instead of failing the skin, and trim attribute whitespace from file references the way Winamp did. Done when the 3 load, the host path still never reaches the file system, and each degraded reference is a finding | skin-dead: census `FAILED [resourceEscapesVFS]` / `[resourceMissing]`, quarantine 3/54 | S | 2 |
| B181 | **Skins that require the stock Big Bento.** Braun CC 50 and Nokia 5800 XpressMusic require the skin 'Big Bento' mounted, which is Winamp's own skin, and we can neither ship it nor find it in the corpus (gold holds *Big Bento Modern*, a different skin). Decide: fail with a user-readable message, or load what does not depend on it. Done when the decision is made and the 2 behave as decided | skin-dead: census `FAILED [missingRequiredMount]`, quarantine 2/54 | S | 3 |
| B161 | **A press in the outer few points of a resizable `.wal` window is AppKit's, and it moves one edge even at a corner.** The skin's auxiliary windows are `[.borderless, .resizable]`, so AppKit's own edge band takes the press before `WinampModernMainView.mouseDown` and the skin's `resize="bottomright"` layer never sees it. Measured 2026-09-30 with `WINAMP_MODERN_RESIZE_TRACE=1` on Itemskin: a press 8pt in from the playlist frame's bottom-right corner, dragged +60,+30, logged `live=true handle=false` and changed the width only; 13pt in on the PeppyMeter frame, dragged +30,+60, changed the height only. 20pt in, the same drags logged `handle=clear.bottom.right` and moved both axes. Decide whether the band should defer to a skin handle under the pointer, or the windows should drop `.resizable` where the layout declares handles. Found during B160; not changed by it | `xml-attr '@resize$'` (a skin resize handle, an upper bound — the index does not say which window): gold 43/56, silver 46/54, bronze 743/827, quarantine 44/54 (manifest 9e68ffe0) | S | 2 |

### Code health

| Id | Item | Reach | Effort | Tier |
|---|---|---:|:---:|---|
| B162 | **Move the script-glue code out of `WinampModernMainWindowController.swift`.** The file is ~2,900 lines, and the glued-window code sits in two places ~800 lines apart. One part is `moveCarryingGluedWindow`, `gluedPartner(of:)`, `gluedWindow(over:)` and `gluedWindowPairs`. The other is `restackGluedWindows`, `attachGluedWindowsForDrag`/`detachGluedWindowsAfterDrag`, their `dragObservers` and `dragAttachedGluedWindows`, and the `tracesGlue`/`carriesGluedWindowsInDrag` switches. An extension file cannot carry the stored state and cannot reach the controller's private `skinView`/`viewsByContainer`. So give the glue its own small type that owns the drag observers and linked pairs and gets the pairs from the controller, leaving one property on the controller. No behaviour change. Done when `swift test` passes and a drag of Pure Inspired's docked playlist under `WINAMP_MODERN_GLUE_TRACE=1` still prints `drag carries` and `restacked` lines. Deferred from PR #468 to keep that diff a behaviour fix | none on screen; the glue-pair skins (Ebonite, Itemskin, Pure Inspired, K-jr, MoonLight) exercise it | M | 3 |
| B163 | **Make the hosted-window registry exhaustive.** `WinampModernHostedWindowRegistry.all` is an array searched by `entry(id:)`, which returns an Optional, and every definition's `makeSurface` is Optional too, although every `WinampModernHostedWindowID` has an entry and every entry builds a surface. Three production callers (`WindowManager`, `WinampModernComponentBridge.makeHostedWindowSurface`, `WinampModernHostedWindowMaterializer`) guard a nil that cannot happen, about fifteen test lines `XCTUnwrap` it, and `WinampModernHostedProviderTests` asserts the two promises the types do not make. Give `WinampModernHostedWindowID` a `definition` built by an exhaustive `switch`, make `makeSurface` non-optional, and keep `all` as `allCases.map(\.definition)` for the synthesizer. A new hosted id then fails to compile without an entry rather than falling back at run time. No behaviour change. Done when `swift test` passes with the nil guards and the registration assertions gone | none on screen; every hosted window routes through it | S | 3 |
| B165 | **Let the hosted-frame descriptor carry a `WasabiSurfaceSynthesizer.Frame` instead of mirroring it.** `WinampModernHostedFrameDescriptor` has exactly `Frame`'s fields (`groupIdentifier`, `xuiTag`, `hasArtwork`, `exemplar`, `clientInsets`), and a `Frame` is rebuilt from it field by field in `WinampModernHostedWindowInstantiation.raised`, `WasabiSkinInitializer.instantiateHostedWindowAtRuntime` and three places in `WinampModernB140Tests`. A rebuild that dropped the client rect is what B140's second screenshot was, and every new frame field has to be threaded through all of them. Store the `Frame` in the descriptor (or replace the descriptor with it) so the rebuilds go away. While there, move `hasContentScript` and `hasArtwork` onto `inheritanceChain(of:definitions:)`, which `clientInsets(of:definitions:)` already uses, so no frame helper walks `inherit_group` by hand. No behaviour change. Done when `swift test` passes and no code builds a `Frame` from a descriptor's fields. Deferred from PR #559's review | none on screen; every hosted window wearing a skin frame routes through it | S | 3 |

### Corpus runner

Plan: [`corpus-runner-plan.md`](../docs/winamp-modern/corpus-runner-plan.md). S0, S1 and S2's MAKI half
are built, and §7 step 3, the S4 demand index, is next. B173 sorted the quarantine: no traps, and
seven loader gaps, B175–B181 under *Measured capability gaps*.

| Id | Item | Reach | Effort | Tier |
|---|---|---:|:---:|---|
| B174 | **The S4 demand index (plan §7 step 3, §3 S4).** Invert `features.tsv` into one table: capability → skins that declare it, per tier, with sample skins to test against, reproducible from the index plus the manifest rev. Start with the MAKI calls the runtime lacks (`maki-call`, `implemented=no`), because those have a verdict. XML rows wait on the supported-surface manifest (§7 step 6). Rank with the plan's `skins × severity × visibility ÷ cost` and file the top 20 as rows here, each with its Reach from `wal_reach.sh`. Done when the table regenerates byte-identically and the top 20 are filed | `maki-call implemented=no`: 157 distinct calls across 538 skins | M | 2 |

### Awaiting manual QA

| Id | Item | Remaining check |
|---|---|---|
| B41 | `getMonitorWidth` / `getMonitorHeight` | Needs a second display. Load Big Bento Modern, move the player to it, open the right-side playlist and toggle **Enlarge Playlist**; the column must size against the player's display, with no 2x oversizing on Retina. Repeat back on the primary display |
| B85 | The Widgets Manager's three place buttons | On a cPro skin: drawer menu -> *Widgets Manager*, then **show in main / drawer / side** on a row. Uninstall and support are expected to stay inert |
| B66 | The Wasabi drop-down's persistence | On Styx's Config, pick a `Position` drop-down entry, reopen the window, confirm the pick survived |
| B110 | Ebonite's frame overlay windows ([record](../docs/winamp-modern/backlog-archive.md#b110--a-skins-window-frame-can-be-a-second-window--implementation-record)) | Reporter's confirmation that Ebonite's frames draw, stay glued and stack correctly |

## Agent-verifiable without user input

Triaged 2026-09-27 against the `app-control` tools: `launch.sh`, `winhelper`
(`click`/`dblclick`/`drag`/`move`/`scroll`/`clickdiff`/`capture`/`screens`), `menu.applescript`,
the window census and the render-dump harness. The ranking above still sets the order.

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
