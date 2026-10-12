# The `.sgf` format

What a Sonique 1.x skin is, as measured on the corpus. The authoring-side spec is Lycos's own
`misc.txt` (the `skin.ini` keys and defaults, "from the Sonique source code") and
`how-to-make-skins-1.09.txt`, both under `SoniqueOracle/docs/` (`harness.md` § *Where things are*).
They are Lycos's text and are never committed.

## What a skin can and cannot change

A skin re-textures a fixed UI; it adds no behaviour.

| Mode | Skin controls | Sonique draws, skin only recolours |
|---|---|---|
| navigator (`nav`) | frame picture and shape, button pictures and hit shapes, drawer, volume knob | the screen: menu, playlist, visual mode, setup, about, audio controls, search, status line |
| mid (`mid`, `msm`) | frame picture and shape, every button, the display placement, the progress rings | track number and time, the vis |
| small (`small`) | the bar picture | the shape (effectively fixed: the drawers depend on it), track and time text |

The skinpack's own words: *"You cannot change anything inside of the screens except color scheme"*,
and resizing a screen *"probably won't work"*. Mid mode is the exception in practice: corpus skins
reshape it freely (Trigun is a cross, MintE a swirl), see the sample captures.

**`0x000000` is transparent** in every picture. Authors use a near-black for black.

## Container

Little-endian, uncompressed. Every file in the corpus starts with `DAF\0LIST`.

| Offset | Field |
|---|---|
| `0x00` | `DAF\0` magic, then `LIST` |
| `0x08` | u32: offset of the first payload |
| `0x14` | `sgf\0`, the root name |
| `0x64` | u32: total file size |
| `0x68` | u32: entry count |
| `0x70` | the entry table: `count` entries of `0x64` bytes each |

An entry is a NUL-terminated name in a `0x54`-byte field (bytes after the NUL are garbage, not
zero), then u32 payload offset, u32 payload size, then 8 bytes of padding. The padding is zero in
every entry but the last, whose final 4 bytes are the start of the first payload: the table is 4
bytes shorter than `count × 0x64`, so read entries by stride and payloads by their own offsets.
Payloads are raw:

- **`/skin.ini`**: Windows INI text, CRLF, latin-1.
- **`/jpeg/<name>`**: a complete JFIF JPEG.
- **`/rgn/<mode>/<control>`**: a region, already rasterised by Skinmaker from the author's mask:
  u16 rectangle count, u16 `left, top, right, bottom` bounds, then `count` × u16
  `left, top, right, bottom`. Size is always `10 + 8 × count`; the census checks every region
  against that. Whether `right`/`bottom` are exclusive is not yet verified (S3).

## Entries

| Entry | Meaning |
|---|---|
| `/jpeg/navigator`, `/jpeg/midsonique`, `/jpeg/smallstate` | the three mode pictures, buttons drawn unlit |
| `/jpeg/misc` | every lit button state and the drawer; positions in `[misc locations]` |
| `/jpeg/extra` | the drawer screen (audio enhancement) |
| `/jpeg/volumeknob`, `/jpeg/smallknob`, `/jpeg/shuttle`, `/jpeg/nav_volumeknob` | horizontal animation strips; frame width and count in `[misc values]` (volume: 18px × 37) |
| `/jpeg/skinthumb`, `/jpeg/skinthumbmask` | the thumbnail Sonique's skin browser shows |
| `/rgn/<mode>/frame` | the window shape |
| `/rgn/nav/*`, `/rgn/mid/*` | hit shapes: `play`, `pause`, `prev`, `next`, `eject`, `repeat`, `shuffle`, `volume`, `up`, `down`, `display`, `drawer*`, `dknob*`, `shuttle`, `eq`, `top`, `bottom`, `songposring`, `listposring`, `logohref` |
| `/rgn/small/extratop`, `/rgn/small/extrabottom` | the small-mode drawers |

An entry absent from a skin means "Sonique's default" (Skinmaker writes `= #` for it). The default
skin's artwork is inside `Sonique.exe`, not in any `.sgf`, so a skin that omits an entry needs an
app-authored default (S4).

## `skin.ini`

| Section | Holds |
|---|---|
| `[skin]` | author, title, url, `version` (100, or 105 for the extra 1.05 features), `TouchNavMode` / `TouchMidMode` / `TouchSmallMode` (0 leaves that mode on the default skin), `nav_logo_href` / `mid_logo_href` |
| `[sonique colors]` | ~25 `0xAARRGGBB` colours: `SystemColor_1..3`, `SystemBkColor_1..2`, `PlayListColor_*`, `ProgressColor_1..3`, `ProgressBkColor`, `StatusBar*`, `*KnobColor`, `Logo*`, `BlueBallsColor`, `InternalVis*` (105) |
| `[misc locations]` | `<NAME>_x` / `<NAME>_y`: top-left of each lit state in `/jpeg/misc`; `NAV_*` variants (105) let nav and mid differ |
| `[misc values]` | drawer geometry, knob strip frame width and count, `NC_BB_DIST_FROM_RIGHT` (105), `mid_playlistmode` (270° or 360° ring) |
| `[msm locations]` | end positions of the mid-mode window-control balls (`MSM_SINGLEUP`, `MSM_HELP`, `MSM_MINIMIZE`, `MSM_CLOSE`, …) |
| `[preferences]` | Skinmaker's own font settings; ignore |

Only values that differ from the default are written, so every key needs its default from
`misc.txt`. Some defaults there are expressions (`BIGON_DOWN_y = BIGUP_y + 35`), and 6 corpus skins
write one, always `BIGON_DOWN_y = BIGUP_y + n`. 15 skins carry more than one `[skin]` section:
Skinmaker writes the first (author, title), and an author following `misc.txt` adds a second holding
`version=105` and the other 1.05 keys. How the engine reads both is the decision record's
§ *INI rules*.
