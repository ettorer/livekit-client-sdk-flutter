# Visible region list for remote video windows

Implement this in the LiveKit Flutter client that runs as the control UI inside a Windows remote desktop session. Video is not drawn in that session. On the other PC, the endpoint that runs the remote desktop client, a C++ program renders each stream into an undecorated window placed over the remote-desktop view, in the spot where Flutter created the video widget. Flutter already hides, restores, moves, and resizes those windows through a `set_geometry` JSON-RPC. It does not yet tell the C++ program which pieces of each widget are actually showing inside the remote session.

Add a `regions` array to the existing `set_geometry` parameters. Each entry is one rectangle of that video widget's visible region, as seen on the remote desktop PC. The C++ program, on the client PC, clips its local window to that list.

The video windows are not occluders of the Flutter widgets. They exist only on the client PC. The Win32 query runs in the Flutter process, on the remote desktop PC, and those `HWND`s are not in that Z-order. Do not search for them, and do not exclude them. The spike algorithm applies directly.

## What the spike proved

A Flutter widget is not an `HWND`. Every widget in the Flutter view is painted into one window. Win32 can still describe the visible part of a widget rectangle, but only from native code on the machine where Flutter is running.

`GetRandomRgn(hdc, rgn, SYSRGN)` (the classic GDI visible-region call, `SYSRGN` is 4) is the wrong source for this. With Desktop Window Manager, each top-level window is composited on its own surface, so that call keeps returning the full widget rectangle while another application on the same desktop covers it. The spike confirmed this: GDI reported one full rectangle while Explorer, Notepad, and another app covered part of the widget.

The working approach, all on the remote desktop PC:

1. Measure each widget in Dart as an axis-aligned rectangle in logical pixels, relative to the Flutter view (`RenderBox.localToGlobal`).
2. Convert to physical screen pixels with that view's `devicePixelRatio`, then add `ClientToScreen` of the **Flutter view** `HWND`. Use the view window, not the top-level frame, or the title bar shifts every Y coordinate.
3. Clip each rectangle to the view client area and to the virtual screen.
4. Walk top-level windows from front to back (`GetTopWindow(GetDesktopWindow())`, then `GetWindow(hwnd, GW_HWNDNEXT)`). Stop at the Flutter top-level window (`GetAncestor(viewHwnd, GA_ROOT)`). Windows behind Flutter are ignored.
5. Subtract the shape of each occluding window from a single covering region, then subtract that one region from every widget. Do this walk once per update, not once per widget.
6. Read the remaining rectangles with `GetRegionData`. They are disjoint, banded, physical screen pixels, exclusive of right and bottom (`RECT`).

Reference implementation from the spike (adapt it; do not copy the demo UI):

- `windows/runner/visible_region.cpp`
- `windows/runner/visible_region.h`
- The `getVisibleRegions` method channel in `windows/runner/flutter_window.cpp`
- The 4×3 grid in `lib/main.dart` shows the Dart side measuring many widgets and sending them in one call.

Verified on that grid: 12 cells of 120×72 with 12-pixel gaps came back as 12 screen rectangles in row-major order. Covering a cell with another window on the same desktop split only that cell.

## Window shape to subtract

Occluders are other top-level windows on the remote desktop PC: another application, a dialog, the shell. The client-side video windows are not among them.

For each candidate above the Flutter window:

- Skip it when it is the Flutter root, not visible, iconic, or cloaked (`DwmGetWindowAttribute` with `DWMWA_CLOAKED`).
- Skip class `SysShadow`.
- Skip `WS_EX_TRANSPARENT`.
- Skip layered windows whose `GetLayeredWindowAttributes` alpha is 0.
- If `GetWindowRgn` returns a real region, offset it from window coordinates to screen coordinates with `GetWindowRect` and use that shape.
- Otherwise use `DWMWA_EXTENDED_FRAME_BOUNDS`, which omits the invisible resize shadow. Fall back to `GetWindowRect`.
- Test intersection with the union of all widget rectangles before taking the window title. Read titles with `SendMessageTimeoutW(WM_GETTEXT, SMTO_ABORTIFHUNG | SMTO_BLOCK, 50ms)` so a hung window cannot stall the Flutter UI thread.
- `CombineRgn(..., RGN_OR)` the shape into the shared covering region.

If the Flutter root never appears in the walk, discard the covering region and treat every widget as fully visible inside its clipped bounds. Subtracting windows when the root was not found also subtracts windows behind Flutter.

Per widget, `CombineRgn(widgetRegion, widgetRegion, covering, RGN_DIFF)` and then `GetRegionData`.

Link `user32`, `gdi32`, and `dwmapi`. Run the query on the platform thread (a method-channel handler already does).

## Coordinates

The two PCs do not share a screen origin. Absolute screen rectangles from the remote desktop are meaningless on the client. `regions` must be relative to the widget rectangle that `set_geometry` already uses to place the C++ window. The client then applies them with `SetWindowRgn` in its own window coordinates.

Dart bounds are logical pixels, origin at the top-left of the Flutter view:

```dart
final box = key.currentContext!.findRenderObject() as RenderBox;
final topLeft = box.localToGlobal(Offset.zero);
final bottomRight = box.localToGlobal(
  Offset(box.size.width, box.size.height),
);
final view = View.of(context);
```

Send `topLeft`, `bottomRight`, `view.devicePixelRatio`, and `view.viewId` for every video widget in one call. The plugin resolves the view with `PluginRegistrarWindows::GetViewById` and uses `FlutterView::GetNativeWindow()`.

Win32 results are physical screen pixels on the remote machine. Convert each one to be relative to that widget's screen rectangle before the RPC:

```
local.left   = screen.left   - widgetScreen.left
local.top    = screen.top    - widgetScreen.top
local.right  = screen.right  - widgetScreen.left
local.bottom = screen.bottom - widgetScreen.top
```

`widgetScreen` is the same rectangle already used to fill the existing position and size fields. Read that call and use its pixel unit. If those fields are logical pixels, divide the physical deltas by the same `devicePixelRatio` before putting them on the wire, and state that in a comment next to the call. Right and bottom stay exclusive.

A fully showing widget is one rectangle from `(0, 0)` to `(width, height)` in that same unit.

## JSON-RPC

Keep the existing method and the existing position, size, and identity fields. Add `regions`.

```json
{
  "method": "set_geometry",
  "params": {
    "existing": "fields stay as they are",
    "regions": [
      { "left": 0, "top": 0, "right": 320, "bottom": 80 },
      { "left": 0, "top": 140, "right": 180, "bottom": 240 }
    ]
  }
}
```

Use `left`, `top`, `right`, `bottom` unless the existing geometry object already has a rectangle convention. If it does, use that convention for each region too.

Meaning, on the client PC:

- One rectangle equal to the full window: the widget is completely showing on the remote desktop. C++ may call `SetWindowRgn(hwnd, nullptr, TRUE)` and skip a custom region.
- Several rectangles: something on the remote desktop covers part of the widget. OR the rectangles into one `HRGN` and `SetWindowRgn`. Coordinates are relative to the window that `set_geometry` just placed.
- Empty array: nothing of the widget is showing on the remote desktop. Clip the window to an empty region, or hide it through the existing hide path. Do not leave the previous region in place.
- Omit `regions` only on calls that are not reporting visibility. When a geometry update is sent because of a move or resize, include `regions` as well.

Send one `set_geometry` per video window, using that widget's list. The native query still accepts all widgets at once so the Z-order walk happens once.

Update regions when the widgets move or resize, and also while occlusion on the remote desktop can change and geometry is otherwise stable. A timer of a few hundred milliseconds is enough. Skip a new query while the previous one has not returned. Compare the new list with the last list sent for that window and skip the RPC when it is unchanged.

## Where the code goes

Put the Win32 query in a Windows plugin inside the Flutter app (or the existing Windows plugin), not in a forked runner, and not in the C++ program. The runner in the spike exists only because that folder is a throwaway app. The C++ program only consumes `regions`.

Dart responsibilities, on the remote desktop PC:

- Collect the `RenderBox` of each video widget that currently has a client-side video window.
- One method-channel call with the whole list.
- Map each returned rectangle list into widget-relative `set_geometry.regions`.

Native responsibilities, in that same Flutter process:

- Map logical bounds to screen pixels on this PC.
- Build one covering region from top-level windows above the Flutter window.
- Return, in input order, the rectangle list for each widget.

The GDI `SYSRGN` sample in the spike is diagnostic. Do not send it to the C++ program.

## Limits

- Widgets inside the Flutter window share one `HWND`. A Flutter control drawn on top of a video widget does not remove a rectangle. Only other top-level windows on the remote desktop, the view's client clip, and the virtual screen do.
- The input shape is the widget's axis-aligned bounds. A rotated widget needs its own polygon before this query.
- A layered window with partial per-pixel alpha is treated as its frame (or its custom window region). Fully transparent and click-through windows are ignored.
- The walk is synchronous on the UI thread. Titles time out. `GetWindowRgn` and `DwmGetWindowAttribute` still run on that thread; keep the intersection tests so unrelated windows are cheap.
- Occlusion on the client PC, including the video windows overlapping each other or the remote desktop client, is invisible to this query. Clipping those is the C++ program's job after it receives `regions`.

## Acceptance

- Twelve non-overlapping video widgets, nothing else on top of them on the remote desktop: each `regions` array has one rectangle, `(0, 0)` through that widget's width and height.
- Another application on the remote desktop covers the right half of one widget: that window's `regions` contains the remaining piece or pieces, and the other windows stay a single full rectangle. No video `HWND` is involved in that result.
- A fully covered widget sends an empty `regions` array, and the C++ window on the client PC no longer shows video there.
- Moving the Flutter window or resizing a widget updates both the existing geometry fields and `regions` together.
- The rectangles in `regions` are offsets inside the widget, so they stay valid on the client PC after `set_geometry` places the window.
