# VDI example

Local customization of the LiveKit Flutter example (`example/`). The published SDK under `lib/` is unchanged. This work is uncommitted on `main`.

## What this is

The example still connects to a LiveKit server as usual. If the process is started with `--vdi`, Flutter stays the call UI and a separate C++ media engine owns WebRTC (camera, microphone, remote video windows). During development both programs may run on the same PC.

```text
flutter run -d linux -- --vdi
flutter run -d windows -- --vdi
```

Without `--vdi`, `LiveKitClient.initialize` runs and the stock example connects itself. With `--vdi`, Flutter does not initialize LiveKit. The connect page sends the server URL and token to the media engine.

Default media-engine address: `ws://127.0.0.1:8765`.

## Behavior already implemented

- Connect page in VDI mode asks for the LiveKit URL, token, and media-engine WebSocket, then opens a device page. That page calls `get_media` and `start_preview` on the platform default camera. It places the preview only after `window_created`, with `set_geometry` for that window id over the preview hole. `window_destroyed` stops the updates. Microphone and speaker changes call `set_media`. Changing the camera calls `stop_preview`, then `set_media`, then `start_preview` for the new camera. Join sends the selection, stops the preview, and enters the room.
- Once the engine reports it is in the room, Flutter calls `start_video` and `start_audio` automatically. There is no publish dialog.
- Video tiles in Flutter are placeholders. Grid holes are 16:9, start at the top-left, and do not stretch to fill leftover space; a short last row stays on the left. A short window shrinks those tiles, still at 16:9, so the holes stay above the control bar. A focused tile fills the stage beside the side strip, down to the control bar, and is not forced to 16:9. The engine draws undecorated windows on top of those holes. Flutter polls tile geometry about every 100 ms and sends `set_geometry` for the hole, so the engine window matches that rectangle.
- Each `set_geometry` includes `regions`: the pieces of that tile actually showing on this desktop, relative to the tile. Windows reads them from the `vdi_visible_region` plugin about every 300 ms (one Z-order walk for every tile, skipped while a query is in flight). Linux sends one rectangle covering the whole tile.
- Each tile keeps a 1 px inset (2 px when selected) so the engine window does not cover the Flutter border.
- Chat uses the same topic as the stock example, `lk-example-chat`, via `publish_data`.
- Minimize (`AppLifecycleState.hidden` or `paused`) sends `set_window_state` with `window_id: "all"` and `state: "hide"`. Losing focus (`inactive`) while windows are already shown does not hide them. Restore does not send `show`. Flutter forgets the last rect and sends `set_geometry` again. The engine must show a hidden window when it applies that rect. A window created while the app is minimized is hidden immediately.
- Closing the Flutter app stops published local audio and video (`stop_audio`, then `stop_video`, only if `get_status` says they are on), then calls `quit`. "Local" is the engine's own publish flags, not a remote participant.
- Leaving the room calls `disconnect` and closes the socket. It does not quit the engine process.
- If the socket drops, Flutter waits 3 seconds and reconnects, unless close or quit was requested.

## Open Windows work

Linux (Ubuntu 24.04, X11, 150% scale) placement is correct. Windows drag tracking is not.

`getViewOrigin` on Windows uses `ClientToScreen` and returns physical pixels (`devicePixels: true`, `scale = dpi / 96`). Dart multiplies logical tile offsets and sizes by that scale. The runner does not push a move notification; Dart only polls. Dragging the Flutter window on Windows was still not moving the media-engine windows. That is the customization to continue on the Windows PC.

Visible regions are separate from that drag bug. On Windows, `set_geometry.regions` comes from `example/vdi_visible_region`. The query uses the Flutter view HWND, not the top-level frame.

RDP geometry tracking (`MS-RDPEGT`) was discussed only. No code for it.

## Coordinate space

`set_geometry` x, y, width, and height are screen pixels in the space the engine uses to place windows.

The desktop runner exposes them through the method channel `livekit_example/vdi_window`, method `getViewOrigin`. Result map:

| Field | Linux | Windows |
| --- | --- | --- |
| `x`, `y` | GTK application pixels (`gdk_window_get_origin` plus the view offset inside the toplevel). Same space as Flutter logical pixels and `gtk_window_move`. | Physical pixels of the client area (`ClientToScreen` of the Flutter HWND, so the title bar is outside the video rect). |
| `scale` | GDK scale factor. Informational. | `dpi / 96`. |
| `devicePixels` | `false`. Dart must not multiply by `scale`. On a 150% desktop GDK scale is 2 and multiplying doubles every tile. | `true`. Dart multiplies logical tile x, y, width, and height by `scale` before adding them to the origin. |

`regions` are not screen coordinates. They are offsets inside the widget rectangle, in the same pixel unit as `width` and `height`. On Windows that unit is physical pixels, so the deltas are not divided by the device pixel ratio. A fully showing tile is `(0, 0)` through `(width, height)`.

Dart side: `example/lib/vdi/view_origin.dart`, `example/lib/vdi/visible_region.dart`. Linux: `example/linux/my_application.cc`. Windows position: `example/windows/runner/flutter_window.cpp`. Windows occlusion: `example/vdi_visible_region`.

## Code map

| Path | Role |
| --- | --- |
| `example/lib/main.dart` | `--vdi` flag. Skips `LiveKitClient.initialize`. Wraps the app in `VdiExitScope`. |
| `example/lib/pages/connect.dart` | Connect form and engine handshake. |
| `example/lib/pages/vdi_devices.dart` | Camera, microphone, and speaker picker. Places the preview after `window_created`. |
| `example/lib/pages/vdi_room.dart` | Room UI, tiles, chat, geometry polling, auto publish. |
| `example/lib/vdi/json_rpc.dart` | JSON-RPC 2.0 peer. |
| `example/lib/vdi/media_engine_client.dart` | WebSocket client and method wrappers. |
| `example/lib/vdi/media_engine_controller.dart` | Room state, geometry queue, hide/show, quit. |
| `example/lib/vdi/media_engine_state.dart` | `get_status` and window-list models. |
| `example/lib/vdi/media_devices.dart` | `get_media` / `set_media` device lists and the selected ids. |
| `example/lib/vdi/vdi_session.dart` | App lifecycle and quit-on-exit. |
| `example/lib/vdi/chat.dart` | `data_received` / `chat` parsing. |
| `example/lib/vdi/visible_region.dart` | Widget-relative `regions` and the last list sent per window. |
| `example/vdi_visible_region` | Windows plugin. One Z-order walk, screen rectangles back to Dart. |
| `example/JSON_RPC.md` | Wire contract for the C++ media engine. |
| `example/rpc_media_devices.md` | `get_media`, `set_media`, and the preview calls. |
| `example/test/vdi_protocol_test.dart` | Protocol and geometry unit tests. |

# JSON-RPC

The wire contract for the C++ media engine is [JSON_RPC.md](JSON_RPC.md). That file is the one to follow when updating the engine. The change older engines do not handle yet is `regions` on `set_geometry`.

Transport is a WebSocket. Each message is one JSON object, UTF-8 text. The Flutter client is the only caller. The engine answers requests and pushes events.

Requests use integer ids, starting at 1. `params` is omitted when a method takes none.

```json
{"jsonrpc":"2.0","id":1,"method":"connect","params":{"url":"wss://example","token":"jwt"}}
```

Success:

```json
{"jsonrpc":"2.0","id":1,"result":{"ok":true,"status":"connecting"}}
```

Failure:

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"already connected"}}
```

A result that is not an object is treated as `{}`. Calls time out after 10 seconds. Flutter raises `JsonRpcException` with the engine's `code` and `message`.

Codes the client already handles:

| Code | Meaning in this client |
| --- | --- |
| `-32000` | `connect` when already in that room: resync and continue. `disconnect` when not connected: ignore. |
| `-32602` | `set_geometry` rejected as invalid. The client treats that rect as applied and does not retry it. |
| `-32603` | Fallback when the error object is missing a code. |

## Events

Notifications have `method: "event"`, a `params` object, and no `id`.

```json
{"jsonrpc":"2.0","method":"event","params":{"event":"connected","room":"demo-room","identity":"alice"}}
```

| `event` | Fields the client reads |
| --- | --- |
| `connected` | `room`, `identity` |
| `disconnected` | none. Client clears windows, geometry, video, audio, and remote participants. |
| `error` | `message` |
| `participant_connected` | `identity` |
| `participant_disconnected` | `identity` |
| `media_state` | `video` (bool), `audio` (bool) |
| `window_created` | same fields as a window object below |
| `window_destroyed` | `window_id`. Repeated destroys are ignored. |
| `data_received` | `topic`, `identity`, `data` (UTF-8 string, or a list of byte ints) |
| `chat` | optional shortcut: `text`, `identity`, `id`, `createdAt` |

## Methods

### `get_status`

No params. Result:

```json
{
  "connection": "disconnected",
  "connected": false,
  "url": "",
  "room": "",
  "identity": "",
  "video": false,
  "audio": false,
  "remote_participants": [],
  "last_error": "",
  "backend": "",
  "rpc_clients": 0
}
```

`connection` is `disconnected`, `connecting`, `connected`, or `disconnecting`. The client treats the engine as in the room when `connected` is true or `connection` is `"connected"`. `video` and `audio` are the engine's local publish flags.

### `get_video_list`

No params. Result:

```json
{
  "windows": [
    {
      "window_id": "local",
      "type": "local",
      "identity": "alice",
      "x": 0,
      "y": 0,
      "width": 320,
      "height": 240,
      "visible": true
    }
  ]
}
```

`window_id` is `"local"` or `"remote:<identity>"`. `type` is `"local"` or `"remote"`. A window is local when `type` is `"local"` or `window_id` is `"local"`.

Events are applied immediately. A `get_video_list` that was in flight while a create or destroy arrived must not resurrect a destroyed window or drop one created during the call. The client merges that itself; the engine should still return the current list.

### `connect`

```json
{"url":"wss://livekit.example","token":"<jwt>"}
```

Joins the LiveKit room. A typical result is `{"ok":true,"status":"connecting"}`, followed by a `connected` event. If the engine returns `-32000` with a message containing "already connected", the client resyncs status and the window list.

### `disconnect`

No params. Leaves the room. `-32000` is ignored.

### `start_video` / `stop_video` / `start_audio` / `stop_audio`

No params. Publish or unpublish the engine's local camera or microphone. The engine should then emit `media_state`.

### `publish_data`

```json
{"topic":"lk-example-chat","data":"<utf-8 text>","reliable":true}
```

The engine sends `data` as a reliable LiveKit data packet on `topic`. Packets it receives come back as `data_received`.

Chat payload inside `data` (JSON text, not an object):

```json
{"id":"m1","text":"hello","senderIdentity":"alice","createdAt":"2026-10-04T09:00:00.000Z"}
```

Topic `lk-example-chat` is parsed as chat. Any other topic is shown as a system line. A `chat` event is an optional direct form of the same message.

### `set_window_state`

```json
{"window_id":"all","state":"hide"}
```

`window_id`: `"local"` | `"remote:<identity>"` | `"all"`.

`state`: `"show"` | `"hide"` | `"toggle"`.

The Flutter client currently sends only `hide` (for `"all"`, or for one new window while minimized).

### `set_geometry`

```json
{
  "window_id": "remote:bob",
  "x": 100,
  "y": 80,
  "width": 640,
  "height": 360,
  "regions": [
    { "left": 0, "top": 0, "right": 640, "bottom": 360 }
  ]
}
```

Places that engine window. `x`, `y`, `width`, and `height` are integers, screen pixels, in the coordinate space described above. Rects smaller than 2×2 are not sent. The client debounces changes by about 40 ms and skips a call when that rect and `regions` are both unchanged.

`regions` are the pieces of the widget actually showing on the desktop where Flutter is running. `left`, `top`, `right`, and `bottom` are exclusive, relative to the widget, in the same pixel unit as `width` and `height`.

- One rectangle from `(0, 0)` to `(width, height)`: the widget is completely showing. The engine may call `SetWindowRgn(hwnd, nullptr, TRUE)`.
- Several rectangles: something on that desktop covers part of the widget. The engine ORs them and calls `SetWindowRgn`.
- Empty array: nothing of the widget is showing. The engine clips to an empty region. Flutter does not send `hide` for this.

Flutter includes `regions` on every `set_geometry`. On Windows they come from one visible-region query for every tile. On Linux the list is one full rectangle.

Applying geometry to a hidden window must show it. That is how restore works. The engine applies `regions` to the window it just placed.

### `quit`

No params. The engine process exits. Flutter calls this only after stopping published local audio and video, and only when the Flutter window itself is closing.
