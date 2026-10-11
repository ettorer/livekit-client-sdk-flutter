# JSON-RPC method: `set_window_state`

**Direction:** controller → media engine (request/response)

Shows, hides, or toggles the visibility of one or all GTK video windows managed\
by the media engine.

---

## Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "set_window_state",
  "params": {
    "window_id": "<string>",
    "state":     "<string>"
  }
}
```

### Parameters

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `window_id` | string | yes | Which window(s) to affect. See **Window IDs** below. |
| `state` | string | yes | `"show"`, `"hide"`, or `"toggle"`. |

#### `window_id` values

| Value | Meaning |
| --- | --- |
| `"local"` | The local webcam preview window. |
| `"remote:<identity>"` | The remote participant window for `<identity>` (e.g. `"remote:bob"`). |
| `"all"` | Every currently-open window (local + all remotes). |

> Note: `window_id` values match the `window_id` field returned by `get_video_list`\
> and `window_created` / `window_destroyed` events.

#### `state` values

| Value | Meaning |
| --- | --- |
| `"show"` | Make the window visible (no-op if already visible). |
| `"hide"` | Hide the window (no-op if already hidden). |
| `"toggle"` | Flip: show if currently hidden, hide if currently visible. |

---

## Response (success)

HTTP 200 / WebSocket frame carrying a JSON-RPC 2.0 result:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "ok": true,
    "windows": [
      {
        "window_id": "local",
        "type":      "local",
        "identity":  "",
        "x":         20,
        "y":         20,
        "width":     320,
        "height":    240,
        "visible":   false
      }
    ]
  }
}
```

### Result fields

| Field | Type | Description |
| --- | --- | --- |
| `ok` | bool | Always `true` on success. |
| `windows` | array of object | One geometry object per affected window (same schema as `get_video_list`). |

Each geometry object:

| Field | Type | Description |
| --- | --- | --- |
| `window_id` | string | e.g. `"local"` or `"remote:alice"`. |
| `type` | string | `"local"` or `"remote"`. |
| `identity` | string | Participant identity, or `""` for the local window. |
| `x` | int | Window left edge in screen pixels. |
| `y` | int | Window top edge in screen pixels. |
| `width` | int | Window width in pixels. |
| `height` | int | Window height in pixels. |
| `visible` | bool | Visibility **after** this call. |

---

## Error responses

| Code | Condition |
| --- | --- |
| `-32602` (InvalidParams) | `window_id` is not `"local"`, `"remote:<identity>"` (with a known identity), or `"all"`. |
| `-32602` (InvalidParams) | `state` is not one of `"show"`, `"hide"`, or `"toggle"`. |
| `-32602` (InvalidParams) | Either `window_id` or `state` is missing or not a non-empty string. |
| `-32000` (ServerError) | Application is shutting down. |
| `-32603` (InternalError) | GTK main loop did not respond within 3 seconds. |

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32602,
    "message": "unknown window_id: remote:nobody"
  }
}
```

---

## Examples

### Hide the local preview

```json
{"jsonrpc":"2.0","id":1,"method":"set_window_state","params":{"window_id":"local","state":"hide"}}
```

Response:

```json
{"jsonrpc":"2.0","id":1,"result":{"ok":true,"windows":[{"window_id":"local","type":"local","identity":"","x":20,"y":20,"width":320,"height":240,"visible":false}]}}
```

### Show a specific remote participant

```json
{"jsonrpc":"2.0","id":2,"method":"set_window_state","params":{"window_id":"remote:alice","state":"show"}}
```

### Toggle all windows

```json
{"jsonrpc":"2.0","id":3,"method":"set_window_state","params":{"window_id":"all","state":"toggle"}}
```

Response contains one geometry object per window that was open at the time of the call.

---

## Threading notes

`set_window_state` is synchronous: the RPC call **blocks** until the GTK main thread\
has applied the show/hide and the response carries the resulting geometry.\
Internally the handler calls `CallOnGtk()`, which waits up to 3 seconds for the\
GTK idle callback to execute.  In practice this resolves in < 1 ms.

No `window_created` or `window_destroyed` events are emitted by this call — those\
events are only fired when a window is actually created or destroyed (i.e.\
`OnParticipantConnected` / `OnParticipantDisconnected` and video start/stop).

---

## Related methods and events

| Name | Direction | Description |
| --- | --- | --- |
| `get_video_list` | C→E | List all windows and their current geometry + visibility. |
| `get_geometry` | C→E | Geometry of a single window. |
| `set_geometry` | C→E | Move / resize a window. |
| `window_created` | E→C | Fired when a new window appears. |
| `window_destroyed` | E→C | Fired when a window is closed. |



### `set_geometry` implicit show

Calling `set_geometry` on a hidden window **automatically shows it**.
This lets the controller place and reveal a window in a single call:

```json
{"jsonrpc":"2.0","id":4,"method":"set_geometry",
 "params":{"window_id":"local","x":100,"y":100}}
```

moves the local preview to (100, 100) **and** makes it visible if it was hidden —
no need to call `set_window_state` first.

`get_geometry` does **not** show the window; it is a pure read.
