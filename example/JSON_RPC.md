# Media engine JSON-RPC

Wire contract between the Flutter VDI example and the C++ media engine. The engine listens on `ws://127.0.0.1:8765`. Flutter is the only caller. The engine answers requests and pushes events.

This is the document to follow when updating the engine. The change that current Flutter builds send, and older engines do not handle yet, is `regions` on `set_geometry`.

## Change: `set_geometry.regions`

`set_geometry` still places one undecorated video window. It now also tells the engine which pieces of that window are showing on the desktop where Flutter is running.

Flutter includes `regions` on every `set_geometry`. Accept the field. A `-32602` ("invalid params") response makes this client treat that rectangle as applied and stop retrying it, so rejecting `regions` freezes placement for that window.

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "set_geometry",
  "params": {
    "window_id": "remote:bob",
    "x": 100,
    "y": 80,
    "width": 640,
    "height": 360,
    "regions": [
      { "left": 0, "top": 0, "right": 640, "bottom": 180 },
      { "left": 0, "top": 240, "right": 400, "bottom": 360 }
    ]
  }
}
```

### Position, unchanged

| Field | Type | Meaning |
| --- | --- | --- |
| `window_id` | string | `"local"` or `"remote:<identity>"`. One call per window. |
| `x`, `y` | int | Screen position of the window's top-left, in the pixel space the engine already uses to place windows. |
| `width`, `height` | int | Window size in that same pixel space. Flutter does not send a rect smaller than 2×2. |

On a Windows Flutter host these are physical pixels (`dpi / 96`). On a Linux Flutter host they are GTK application pixels, the same unit as `gtk_window_move`. The engine does not convert them again.

Place the window from these four fields as before. Applying them to a hidden window must show it. That is how restore works. Flutter does not send `set_window_state` `"show"`.

### `regions`

An array of rectangles. Each object has integer `left`, `top`, `right`, and `bottom`. Right and bottom are exclusive, matching a Win32 `RECT`.

The origin is the top-left of the window `set_geometry` just placed. These are not screen coordinates. The Flutter desktop and the engine may be on different machines and do not share a screen origin. Do not add `x` or `y` to a region edge.

The pixel unit is the same as `width` and `height`.

| `regions` | What the engine does |
| --- | --- |
| One rectangle `(0, 0)`–`(width, height)` | The widget is fully showing. Clear any custom clip. `SetWindowRgn(hwnd, nullptr, TRUE)` is the Windows form of that. |
| Two or more rectangles | Something on the Flutter desktop covers part of the widget. OR the rectangles into one region and clip the window to it (`SetWindowRgn`). |
| `[]` | Nothing of the widget is showing. Clip to an empty region. Do not leave the previous clip in place. Flutter does not send `hide` for this. |

Replace the clip on every call. Do not union the new list with the previous one. A later call with a single full rectangle must remove a clip installed by an earlier call.

Apply position first, then the clip, in the same request. The region is in the coordinate space of the window after the new size is in effect.

`SetWindowRgn` takes ownership of a region it accepts and deletes the previous one. After a successful call, do not `DeleteObject` the region that was passed in.

Flutter clamps every edge to the window: `0 <= left < right <= width` and `0 <= top < bottom <= height`. The rectangles do not overlap. Order is not significant. OR them in the order received.

A call whose position is unchanged can still carry a new `regions` list. Occlusion on the Flutter desktop changes while the tile is still. Apply the new clip.

If `regions` is absent, apply the position and leave the current clip as it is. This Flutter client does not omit the field. Keep that behavior so an older caller still places windows.

An empty array clips the window to nothing. The next `set_geometry` for that `window_id` installs whatever list it carries, including a full rectangle that clears the clip. If the engine hides the window instead of installing an empty region, that later `set_geometry` must show it again, because applying geometry shows a hidden window.

Suggested success result, same shape as before:

```json
{"jsonrpc": "2.0", "id": 7, "result": {"ok": true}}
```

Unknown `window_id`: return an error and do not create a window. Prefer a code other than `-32602` when the window may appear a moment later (`window_created` and `set_geometry` can cross). `-32602` tells this client to drop that rect permanently.

## Transport

Each WebSocket message is one JSON object, UTF-8 text.

Request:

```json
{"jsonrpc": "2.0", "id": 1, "method": "connect", "params": {"url": "wss://livekit.example", "token": "<jwt>"}}
```

- `jsonrpc` is `"2.0"`.
- `id` is an integer. Flutter starts at 1 and increases by 1.
- `params` is omitted when the method takes none. Do not require an empty object.
- Answer with the same `id`.

Success result is a JSON object. Flutter treats a non-object result as `{}`.

```json
{"jsonrpc": "2.0", "id": 1, "result": {"ok": true, "status": "connecting"}}
```

Failure:

```json
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "already connected"}}
```

`code` is an integer. `message` is a string. Flutter waits 10 seconds, then abandons the call.

| Code | When the engine sends it | What this client does |
| --- | --- | --- |
| `-32000` | `connect` while already in that room. Put `"already connected"` in the message. | Resyncs status and the window list, and stays in the room. |
| `-32000` | `disconnect` while already disconnected. | Ignores the error. |
| `-32602` | Params are invalid and retrying the same params will fail the same way. | For `set_geometry`, treats that rect as applied and does not send it again. |
| `-32603` | Used by the client when `code` is missing. The engine does not need to send it. | Surfaces the message. |

Events are notifications. They have `method` `"event"`, a `params` object, and no `id`. The engine does not wait for a response.

```json
{"jsonrpc": "2.0", "method": "event", "params": {"event": "connected", "room": "demo-room", "identity": "alice"}}
```

## Methods

### `get_status`

No params.

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

`connection` is `"disconnected"`, `"connecting"`, `"connected"`, or `"disconnecting"`. Flutter treats the engine as in the room when `connected` is true or `connection` is `"connected"`. `video` and `audio` are the engine's own publish flags, not a remote participant's.

### `get_video_list`

No params.

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

`window_id` is `"local"` or `"remote:<identity>"`. `type` is `"local"` or `"remote"`. Return the current list. Flutter also listens for `window_created` and `window_destroyed` and will ignore a snapshot that would resurrect a window destroyed while this call was in flight.

### `connect`

```json
{"url": "wss://livekit.example", "token": "<jwt>"}
```

Join that LiveKit room. Return `{"ok": true, "status": "connecting"}`, then push `connected`. If already in that room, return `-32000` with a message containing `"already connected"`.

### `disconnect`

No params. Leave the room, then push `disconnected`. `-32000` when already disconnected. Do not exit the process.

### `start_video` / `stop_video` / `start_audio` / `stop_audio`

No params. Publish or unpublish the engine's local camera or microphone, then push `media_state`. `start_video` and `start_audio` open the devices last stored by `set_media`.

### `get_media` / `set_media`

Device lists and the camera, microphone, and speaker selection. No room is required. The full shapes, including `selected` and `default`, are in [rpc_media_devices.md](rpc_media_devices.md).

`get_media` takes no params. `set_media` takes any subset of `camera`, `audio_input`, and `audio_output`. Each value is an `id` from `get_media`. At least one field is required. Omitted fields stay as they are.

### `start_preview` / `stop_preview`

Local camera preview before the room. These do not publish.

`start_preview` params are `{"camera": "<id>"}`. The id is from `get_media.cameras`. Create or reuse the local preview window and push `window_created` with that window's fields (`window_id`, `type: "local"`, and the rest of the `get_video_list` object). Push it when the window is new, before or as the call returns. Result: `{"ok": true, "window_id": "local"}`. Flutter does not place the preview until that `window_created` arrives. It then sends `set_geometry` for the event's `window_id`, sized to the preview hole. `window_destroyed` stops those updates.

`stop_preview` takes no params. Close that preview. If video is not published, destroy the local window and push `window_destroyed`. If no preview is running, return `{"ok": true}`.

The device page calls `get_media`, then `start_preview` with `default.camera`. A camera change is `stop_preview`, then `set_media` with the new id, then `start_preview` with that id. Joining the room calls `stop_preview` before `connect`.

### `publish_data`

```json
{"topic": "lk-example-chat", "data": "<utf-8 text>", "reliable": true}
```

Send `data` as a reliable LiveKit data packet on `topic`. `data` is a string, not a JSON object. Packets the engine receives are pushed as `data_received`.

Chat text carried in `data` for topic `lk-example-chat`:

```json
{"id": "m1", "text": "hello", "senderIdentity": "alice", "createdAt": "2026-10-04T09:00:00.000Z"}
```

That value is the packet payload, a string of JSON text.

### `set_window_state`

```json
{"window_id": "all", "state": "hide"}
```

`window_id` is `"local"`, `"remote:<identity>"`, or `"all"`. `state` is `"show"`, `"hide"`, or `"toggle"`.

This client sends only `"hide"`, either for `"all"` when the Flutter window is minimized, or for one `window_id` when that window is created while Flutter is minimized. Restore does not send `"show"`.

### `set_geometry`

Defined in [Change: `set_geometry.regions`](#change-set_geometryregions). Flutter will not send it for a window smaller than 2×2. It skips a call when both the position and `regions` are unchanged, and it may wait about 40 ms to coalesce a burst of moves.

### `quit`

No params. Stop work and exit the process. Flutter calls this only when its own window is closing, and only after `stop_audio` and `stop_video` for streams the engine itself is publishing. Leaving the room is `disconnect`, not `quit`.

## Events

| `event` | Fields |
| --- | --- |
| `connected` | `room`, `identity` |
| `disconnected` | none |
| `error` | `message` |
| `participant_connected` | `identity` |
| `participant_disconnected` | `identity` |
| `media_state` | `video` (bool), `audio` (bool). These are the engine's publish flags. |
| `window_created` | The same fields as one object in `get_video_list.windows`. |
| `window_destroyed` | `window_id`. Sending it twice is harmless. |
| `data_received` | `topic`, `identity`, `data`. `data` is a UTF-8 string, or a list of byte integers. |
| `chat` | Optional shortcut for the same chat message: `text`, `identity`, `id`, `createdAt`. |

`window_created` should be pushed when the engine creates the native window, before Flutter can align it. Flutter then sends `set_geometry`. Until that call, the window may sit wherever the engine created it. A window created while Flutter is minimized is hidden by a following `set_window_state` `"hide"`.
