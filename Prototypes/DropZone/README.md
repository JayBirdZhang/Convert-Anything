# Drop zone prototype (throwaway)

A separate menu-bar app for trying the 1.6 drop zone by hand. **It never converts anything and will never be merged.**
Bundle id `io.github.jaybirdzhang.ConvertAnything.dropzone-proto`. It has its own defaults domain and does not watch folders, so it can't affect the installed app.

## Run

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

- **Drag a file onto the prism and hold still** for the spring-load delay (default 0.3 s, adjustable in the menu, 0.1–1.0 s). The menu opens with format tiles on top. Moving more than 3 pt restarts the wait, so a drag that passes by doesn't open it.
- **Let go on a tile** to see about 1 s of fake progress. The menu then closes, the icon shows a checkmark for 2 s, and the item is added to Recent.
- **Let go anywhere else** (between tiles, on the icon, or off the menu) to cancel and close the menu.
- **More…** opens every possible format as clickable chips.
- **Tiles:** the last choice for these source types comes first, highlighted and labelled "Last used". Then come the hand-picked "most likely" formats for the file's kind, then the real app's popularity order. Several files show only formats that every file can become. When all the files are images, a **Combine into PDF** tile is added. Unknown types, folders and files without an extension show "Can't convert .xyz files" instead of tiles.
- **Format table:** uses the real `Convert Anything/Format.swift`, compiled unchanged, plus a copy of `Converter.route` in `Sources/Formats.swift`.

## Findings

**MenuBarExtra can't do this. Use `NSStatusItem` + a borderless `NSPanel` hosting SwiftUI.**
- SwiftUI's `MenuBarExtra` has no API to open its window.
- Its status button isn't exposed, so it can't be a drag destination.
- A probe found the button through `NSApp.windows`, but on macOS 27 `performClick` on it does **not** open the `.window`-style panel.
- So the real feature needs MyApp.swift to drop `MenuBarExtra` and host ContentView in its own panel. The prototype's `MenuPanel` shows how: non-activating, `.popUpMenu` level, `canJoinAllSpaces` + `fullScreenAuxiliary`, and a rounded `NSVisualEffectView` mask.
- The real app will also have to rebuild what MenuBarExtra gives for free: close on outside click, Esc, the button highlight, and positioning.

**Drag plumbing.**
- **Icon:** a transparent `IconDropView` is added over the status button and registered for file URLs. It is the drag destination and also takes the clicks, so it has to open the menu itself and set the button highlight by hand.
- **Menu:** a single AppKit drag destination (`PanelDropView`) covers the whole menu. SwiftUI only draws the tiles and reports their frames. The hit test maps the drag point into the flipped `NSHostingView`, and `--demo` confirms each tile's centre hits that tile.
  - SwiftUI `.onDrop` per tile was avoided because it can't tell "between tiles" from "left the menu". A drag into a menu already open by click switches it to tiles too.
- **Drag ending elsewhere:** AppKit doesn't tell a destination that a drag it no longer hovers has ended. So while a drag is over the open menu, a 50 ms timer watches `NSEvent.pressedMouseButtons`. If the button goes up and no tile drop arrives within 0.25 s, the menu closes. The timer exists only during that drag; idle cost stays zero.
  - `draggingEnded` is logged on both views, so the log shows whether macOS delivers it.
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
- the spring-open path, panel position, tile hit testing, and drag-ended-elsewhere closing (`--demo`)
- idle cost

**Idle cost.** Measured over 60 s with the menu closed (`top -l 13 -s 5`, `footprint`):
- 0.0 % CPU and about 1 idle wakeup per sample
- 0.02 s of CPU time in the minute
- 22 MB physical footprint (23 MB peak)
- no timers or event monitors exist while idle
