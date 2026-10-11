# Media devices

Wire contract for choosing the camera, microphone, and speaker used by the C++ media engine. The UI calls these over the same JSON-RPC WebSocket as the rest of the engine (`ws://<engine>:8765`).

Call `get_media` when the device picker opens. The user picks one entry from each list. Call `set_media` with the chosen `id` values. The engine uses that selection the next time it publishes video or audio, and also switches immediately when a stream is already running.

These methods do not require an active room. The UI can offer the picker before `connect`.

## `get_media`

No params. `params` may be omitted.

```json
{"jsonrpc": "2.0", "id": 1, "method": "get_media"}
```

Success:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "cameras": [
      {"id": "/dev/video0", "name": "Integrated Camera"}
    ],
    "audio_inputs": [
      {"id": "default: Built-in Microphone", "name": "default: Built-in Microphone", "index": 0},
      {"id": "Built-in Microphone", "name": "Built-in Microphone", "index": 1}
    ],
    "audio_outputs": [
      {"id": "default: Built-in Speaker", "name": "default: Built-in Speaker", "index": 0},
      {"id": "Built-in Speaker", "name": "Built-in Speaker", "index": 1}
    ],
    "selected": {
      "camera": "/dev/video0",
      "audio_input": "Built-in Microphone",
      "audio_output": "Built-in Speaker"
    },
    "default": {
      "camera": "/dev/video0",
      "audio_input": "Built-in Microphone",
      "audio_output": "Built-in Speaker"
    },
    "audio_error": ""
  }
}
```

| Field | Meaning |
| --- | --- |
| `cameras` | V4L2 capture devices. `id` is the device path (`/dev/videoN`). `name` is the name reported by the driver. |
| `audio_inputs` | Microphones. `id` is never empty. When the OS provides a device guid, `id` is that guid. When it does not, `id` is the device `name`, with ` #<index>` appended if two devices share a name. Pass that string to `set_media` exactly. `index` is informational and can change when devices are plugged in. |
| `audio_outputs` | Speakers and headphones. Same shape as `audio_inputs`. |
| `selected.camera` | Camera the engine will open for `start_video`. This is `/dev/video0` until `set_media` or `--camera` changes it. It can name a device that is not in `cameras` if that device is unplugged. |
| `selected.audio_input` | Microphone the engine will open. Before `set_media` this is the same id as `default.audio_input`. After `set_media` it is the id the user sent. |
| `selected.audio_output` | Speaker the engine will use. Same rule as `selected.audio_input`. |
| `default.camera` | Platform default camera: `/dev/video0` when that device is in `cameras`, otherwise the first camera. `""` when there is no camera. |
| `default.audio_input` | Current system default microphone, as an `id` from `audio_inputs`. When the list has both a concrete device and a `default: …` alias for it, this is the concrete device. `""` when the microphone list is empty. |
| `default.audio_output` | Current system default speaker. Same rule as `default.audio_input`. |
| `audio_error` | `""` when the microphone and speaker lists were read. A non-empty string means those lists are empty because the audio module failed. `cameras`, `selected.camera`, and `default.camera` are still valid. |

Check the row whose `id` equals `selected.*`. Badge the row whose `id` equals `default.*`. Those can be the same row. Show `name` in the picker. Store and send `id`. Do not send `index` or `name` back, even when `id` and `name` happen to be the same string.

## `set_media`

Any subset of the three fields. Each value is an `id` from the matching `get_media` list. Omitted fields stay as they are. At least one field is required.

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "set_media",
  "params": {
    "camera": "/dev/video2",
    "audio_input": "default",
    "audio_output": "default"
  }
}
```

A single device is enough:

```json
{"jsonrpc": "2.0", "id": 3, "method": "set_media", "params": {"audio_output": "default"}}
```

Success:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "ok": true,
    "selected": {
      "camera": "/dev/video2",
      "audio_input": "default",
      "audio_output": "default"
    },
    "default": {
      "camera": "/dev/video0",
      "audio_input": "Built-in Microphone",
      "audio_output": "Built-in Speaker"
    }
  }
}
```

`selected` is the selection after the call, including fields this call did not change. `default` is the platform default at the same moment, in the same shape as `get_media`.

## While a call is already up

- `camera` while video is publishing restarts the camera on the new device. The local video window stays up. If the new camera cannot be opened, the engine stops video, pushes `media_state` with `video: false`, and returns an error.
- `audio_input` while audio is publishing switches the microphone in place.
- `audio_output` switches speaker playout in place, including remote audio already playing.
- When the OS gives each device a guid, `id` is that guid and the engine selects it directly. When it does not, `id` is the device name and the engine selects it by making that device the system default microphone or speaker, then moving this process's existing audio streams onto it.
- A selection made before `start_video` or `start_audio` is what those methods open.

## Errors

| Code | When | What the UI should do |
| --- | --- | --- |
| `-32602` | A present field is not a non-empty string, or no field was sent. | Fix the request. Do not retry the same params. |
| `-32000` | The `id` is not in the current device list, or the device could not be opened. `message` names the field, for example `unknown camera: /dev/video9`. | Refresh with `get_media` and let the user pick again. Devices already accepted earlier in a different call stay selected. |

A failed `set_media` does not change the device that failed. Refresh the lists; ids are not stable across unplug and replug.

## Camera preview

`get_media` and `set_media` choose the device. They do not open a camera. The device page shows a preview with two more calls. Neither call publishes to a room, and neither requires `connect`.

### `start_preview`

```json
{"jsonrpc": "2.0", "id": 4, "method": "start_preview", "params": {"camera": "/dev/video0"}}
```

| Field | Meaning |
| --- | --- |
| `camera` | Required. An `id` from `get_media.cameras`. The same string `set_media` accepts. |

Open that camera and show it in the local preview window. `window_id` is `"local"` and `type` is `"local"`. Create the window if it does not exist. Push `window_created` with the same fields as one `get_video_list` window. Flutter ignores the preview for placement until that event arrives, then sends `set_geometry` for the event's `window_id` so the window covers the preview hole. Send the event when the window is new, including when this call returns after creating it. Do not join a room and do not publish. A later `start_video` is what publishes, and it should open `selected.camera`.

```json
{"jsonrpc": "2.0", "id": 4, "result": {"ok": true, "window_id": "local"}}
```

Calling `start_preview` again replaces the camera. Flutter does not rely on that. On a camera change it calls `stop_preview`, then `set_media` with the new id, then `start_preview` with that same id. A new window pushes `window_created` again. `stop_preview` pushes `window_destroyed`, and Flutter stops sending geometry for that id.

The device page's first preview uses `default.camera` from `get_media`, not `selected.camera`.

### `stop_preview`

No params. `params` may be omitted.

```json
{"jsonrpc": "2.0", "id": 5, "method": "stop_preview"}
```

Close the camera opened by `start_preview` and destroy the local window when video is not published. Push `window_destroyed` for `"local"` when the window goes away. Success is `{"ok": true}`. If no preview is running, return success and do not change a published `start_video` stream.

Flutter calls this before `connect` when the user joins, and when they leave the device page without joining.

### Preview errors

| Code | When |
| --- | --- |
| `-32602` | `start_preview` has no `camera`, or `camera` is not a non-empty string. |
| `-32000` | The id is not in `cameras`, or the camera could not be opened. `message` names the id. |

Use a code other than `-32602` when the window does not exist yet. Flutter treats `-32602` on `set_geometry` as permanent for that rectangle.
