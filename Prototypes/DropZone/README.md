# Drop zone prototype (throwaway)

A separate menu-bar app for trying the 1.6 drop zone by hand. **It never converts anything and will never be merged.**
Bundle id `io.github.jaybirdzhang.ConvertAnything.dropzone-proto`. It has its own defaults domain and does not watch folders, so it can't affect the installed app.

## Try it

Double-click **`Try It.command`** in this folder. It makes test files on your Desktop, opens them in Finder, starts the prototype and lists what to try. Press Return in its Terminal window when done to see a summary.

## Run by hand

```sh
Prototypes/DropZone/build.sh                         # → Prototypes/DropZone/build/DropZoneProto.app
open Prototypes/DropZone/build/DropZoneProto.app     # a second prism appears in the menu bar
```

Quit with the menu's **Quit** button (⌘Q while the menu is open) or `pkill -x DropZoneProto`.
Forget the slider value and remembered formats: `defaults delete io.github.jaybirdzhang.ConvertAnything.dropzone-proto`.

Every drag-state change is logged to `~/Library/Logs/DropZoneProto.log`.
`DropZoneProto --selftest` prints the tiles for sample drags. `--snapshot <dir>` renders each menu state to PNG.
`--demo` opens the menu as if a HEIC had paused on the icon.

## What it does

- **A file coming near opens the menu.** Hold a dragged file within 90 pt below the menu bar, inside a menu-wide band around the icon, for the wait time. The distance is adjustable from 20 to 300 pt. You never have to touch the top edge, where macOS opens Mission Control.
  - This works through a global monitor for mouse down, dragged and up only. macOS sends those only while a button is held, so idle cost stays zero, and mouse monitors need no permission.
  - The drag pasteboard's change count tells a real drag from a click-drag that carries nothing. Dragging the file well away closes the menu again.
  - Hovering on the icon itself still works too.

- **Drag a file onto the prism and hold still** for the spring-load delay (default 0.3 s, adjustable in the menu, 0.1–1.0 s). The menu opens with format tiles on top. Moving more than 3 pt restarts the wait, so a drag that passes by doesn't open it.
- **Let go on a tile** to see about 1 s of fake progress. The menu then closes, the icon shows a checkmark for 2 s, and the item is added to Recent.
- **Let go anywhere else** (between tiles, on the icon, or off the menu) to cancel and close the menu.
- **More…** opens every possible format as clickable chips.
- **Tiles:** the last choice for these source types comes first, highlighted and labelled "Last used". Then come the hand-picked "most likely" formats for the file's kind, then the real app's popularity order. Several files show only formats that every file can become. When all the files are images, a **Combine into PDF** tile is added. Unknown types, folders and files without an extension show "Can't convert .xyz files" instead of tiles.
- **Format table:** uses the real `Convert Anything/Format.swift`, compiled unchanged, plus a copy of `Converter.route` in `Sources/Formats.swift`.

## Findings

**MenuBarExtra can't do this. Use `NSStatusItem` + a borderless `NSPanel` hosting SwiftUI.**
- SwiftUI's `MenuBarExtra` has no API to open its window.
- Its status button is reachable only through the private view hierarchy (`NSApp.windows` → `NSStatusBarWindow` → `NSStatusBarButton`). Making it a drag destination would mean adding views to a button SwiftUI owns; drag delivery to it was not tested.
- A probe on macOS 27 found the button has no `action` or `target`. With the app active, three attempts all failed to open the `.window`-style panel, checked 0.1 s and 0.5 s later: `performClick`, `sendAction` and a synthesized `mouseDown`. SwiftUI evidently tracks the click above the button.
- So the real feature needs MyApp.swift to drop `MenuBarExtra` and host ContentView in its own panel. The prototype's `MenuPanel` shows how: non-activating, `.popUpMenu` level, `canJoinAllSpaces` + `fullScreenAuxiliary`, and a rounded `NSVisualEffectView` mask.
- The real app will also have to rebuild what MenuBarExtra gives for free: close on outside click, Esc, the button highlight, and positioning.

**Drag plumbing.**
- **Icon:** a transparent `IconDropView` is added over the status button and registered for file URLs. It is the drag destination and also takes the clicks, so it has to open the menu itself and set the button highlight by hand.
- **Menu:** a single AppKit drag destination (`PanelDropView`) covers the whole menu. SwiftUI only draws the tiles and reports their frames. The hit test maps the drag point into the flipped `NSHostingView`, and `--demo` confirms each tile's centre hits that tile.
  - SwiftUI `.onDrop` per tile was avoided because it can't tell "between tiles" from "left the menu". A drag into a menu already open by click switches it to tiles too.
- **Drag ending elsewhere:** `draggingEnded` on either view closes the menu. The SDK header doesn't say whether it arrives once the drag has moved on to another app, so there's also a backup. While a drag is over the open menu, a 50 ms timer watches `NSEvent.pressedMouseButtons`. Whichever comes first wins: if no tile drop arrives within 0.25 s, the menu closes. The log line `drag ended (…)` shows which one fired. The timer exists only during that drag; idle cost stays zero.
  - Both timers run in the `.common` run-loop modes, so they keep firing while AppKit tracks the drag.
- **Stealing the drag:** the panel is non-activating and shown with `orderFrontRegardless`, so Finder keeps the drag and stays frontmost. Clicking the icon normally does activate the app, so the menu's controls take the keyboard.
- **The system way:** `NSSpringLoadingDestination` / `NSButton.isSpringLoaded` exist, but they use the system's spring-loading delay (System Settings › Accessibility), so they can't drive the slider. Worth trying in the real feature so it follows the user's setting.

**Awkward bits seen while building.**
- Right after launch the status item's window reports a zero frame (macOS 27). The menu falls back to the pointer's position, which is on the icon whenever the menu opens.
- `NSHostingView.fittingSize` lags a model change by one update. The panel has to `layoutSubtreeIfNeeded()` before measuring, or it opens at the old height and jumps.
- macOS 27 created three `NSStatusBarWindow`s for a single MenuBarExtra item; two are off screen at y = −33. Probably the menu bar copies for other displays (see multi-display below).
- With 3 images (HEIC, PNG and JPEG), "every file supports it" removes PNG and JPEG, because a PNG can't become PNG. The tiles become PDF, WebP, GIF and TIFF, which feels wrong. The real feature should probably skip files that are already in the target format.
- The menu is tall: about 620 pt with the tiles open. The tiles sit well above the fold, but Recent plus the tuning section push the bottom a long way down on a 13" screen.

**Not verified here.** This session has no Accessibility or Screen Recording permission, so it could not post a real drag or take screenshots. All of the following is unverified until tried by hand:
- the drag reaching `IconDropView`
- the spring timer firing from a real drag
- the drop on a tile
- multi-display: the icon on a second display's menu bar may be one of those off-screen copies and might not receive drags
- full-screen apps: the panel is `fullScreenAuxiliary`, but whether the auto-hidden menu bar stays revealed during a drag is untested
- the notch: if the icon is hidden behind it, there is no drop target at all; the real feature would need a fallback, such as a drop target on the Dock icon or a hot corner

What was verified:
- the tile logic (`--selftest`)
- rendering in light and dark mode (`--snapshot`)
- with `--demo`:
  - the spring-open path, panel position and tile hit testing
  - drag-ended-elsewhere closing
  - the icon overlay filling the button, registered for file URLs and receiving the click
  - click-open: the menu becomes key and toggles closed on a second click
- idle cost

**Idle cost.** Measured over 60 s with the menu closed (`top -l 13 -s 5`, `footprint`):
- 0.0 % CPU and about 1 idle wakeup per sample
- 0.02 s of CPU time in the minute
- 22 MB physical footprint (23 MB peak)
- no timers or event monitors exist while idle

## Design guesses to check by hand

- Combine into PDF and More… are full-width rows below the 2×2 grid. Combine moves above the grid when it was the last choice.
- Moving more than 3 pt restarts the spring wait. An unsteady hand may never open the menu; the log shows `spring: moved, wait restarted`.
- For several files, tiles are the literal intersection of formats (see the 3-image case above).
- The header is "Convert Anything" with a "drop zone prototype" tag. While dragging, the title reads "Convert IMG_2041.heic to…" or "Convert 3 files to…", with "Let go anywhere else to cancel" underneath.
- A file dropped on the icon itself cancels rather than opening the More list.

## What a hand test should log

`icon: drag entered` → `spring: fired` → `panel: over .jpg` → `panel: dropped on .jpg` → `panel: closed (converted)`.
For a cancel: `… drag ended (…)` → `panel: closed (drag ended elsewhere)`.
