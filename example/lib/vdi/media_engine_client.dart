import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'json_rpc.dart';
import 'media_devices.dart';
import 'media_engine_state.dart';
import 'visible_region.dart';

final _log = Logger('VdiMediaEngine');

/// WebSocket client for the C++ media engine.
///
/// The socket stays open while the room screen is shown. If it drops, the
/// client waits 3 seconds and reconnects, unless [close] was requested or the
/// engine is quitting.
class MediaEngineClient {
  MediaEngineClient({this.onLink});

  final void Function(MediaEngineLink link)? onLink;

  final _events = StreamController<Map<String, dynamic>>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _peerEvents;
  JsonRpcPeer? _peer;
  Timer? _reconnectTimer;
  String? _url;
  var _intentionalClose = false;
  var _openedOnce = false;
  var _socketOpen = false;
  var _session = 0;

  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isSocketOpen => _socketOpen;

  Future<void> connect(String url) async {
    _url = url;
    _intentionalClose = false;
    await _open();
  }

  Future<void> close() async {
    _intentionalClose = true;
    _session++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _tearDownSocket();
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  Future<LiveKitStatus> getStatus() async {
    final result = await _callMap('get_status');
    return LiveKitStatus.fromJson(result);
  }

  Future<List<VideoWindowInfo>> getVideoList() async {
    final result = await _callMap('get_video_list');
    final windows = result['windows'];
    if (windows is! List) return const [];
    return windows
        .whereType<Map>()
        .map((window) => VideoWindowInfo.fromJson(Map<String, dynamic>.from(window)))
        .where((window) => window.windowId.isNotEmpty)
        .toList();
  }

  Future<void> connectRoom({required String url, required String token}) {
    return _callMap('connect', {'url': url, 'token': token});
  }

  Future<void> disconnect() => _callMap('disconnect');

  Future<MediaDeviceSnapshot> getMedia() async {
    return MediaDeviceSnapshot.fromJson(await _callMap('get_media'));
  }

  /// Sends only the ids that are present. At least one is required.
  Future<MediaDeviceSnapshot> setMedia({String? camera, String? audioInput, String? audioOutput}) async {
    final params = <String, dynamic>{
      if (camera != null && camera.isNotEmpty) 'camera': camera,
      if (audioInput != null && audioInput.isNotEmpty) 'audio_input': audioInput,
      if (audioOutput != null && audioOutput.isNotEmpty) 'audio_output': audioOutput,
    };
    if (params.isEmpty) {
      throw ArgumentError('set_media needs a camera, audio_input, or audio_output id');
    }
    return MediaDeviceSnapshot.fromJson(await _callMap('set_media', params));
  }

  /// Opens [camera] in the local preview window. Does not publish it.
  ///
  /// The engine must create `window_id` `"local"` before it returns, so the
  /// next `set_geometry` can place that window.
  Future<void> startPreview({required String camera}) {
    return _callMap('start_preview', {'camera': camera});
  }

  /// Closes the preview opened by [startPreview]. No params.
  Future<void> stopPreview() => _callMap('stop_preview');

  Future<void> startVideo() => _callMap('start_video');

  Future<void> stopVideo() => _callMap('stop_video');

  Future<void> startAudio() => _callMap('start_audio');

  Future<void> stopAudio() => _callMap('stop_audio');

  /// Asks the media engine to publish a reliable LiveKit data packet.
  ///
  /// The engine should send [data] as UTF-8 on [topic]. Packets it receives
  /// are pushed back as `data_received` events:
  /// `{ "event": "data_received", "topic": "...", "identity": "...", "data": "..." }`.
  Future<void> publishData({required String topic, required String data}) {
    return _callMap('publish_data', {
      'topic': topic,
      'data': data,
      'reliable': true,
    });
  }

  /// `window_id` is `"local"`, `"remote:<identity>"`, or `"all"`.
  /// `state` is `"show"`, `"hide"`, or `"toggle"`.
  Future<void> setWindowState({required String windowId, required String state}) {
    return _callMap('set_window_state', {
      'window_id': windowId,
      'state': state,
    });
  }

  Future<void> setGeometry({
    required String windowId,
    required int x,
    required int y,
    required int width,
    required int height,
    required List<RegionRect> regions,
  }) {
    return _callMap('set_geometry', {
      'window_id': windowId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'regions': [for (final region in regions) region.toJson()],
    });
  }

  Future<void> quit() async {
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    await _callMap('quit');
  }

  Future<Map<String, dynamic>> _callMap(String method, [Map<String, dynamic>? params]) async {
    final peer = _peer;
    if (peer == null || peer.isClosed) {
      throw StateError('Media engine is not connected');
    }
    final result = await peer.call(method, params).timeout(const Duration(seconds: 10));
    if (result is Map) return Map<String, dynamic>.from(result);
    return <String, dynamic>{};
  }

  Future<void> _open() async {
    final url = _url;
    if (url == null || _intentionalClose) return;
    final session = ++_session;
    onLink?.call(MediaEngineLink.connecting);
    final channel = WebSocketChannel.connect(Uri.parse(url));
    try {
      await channel.ready.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      await _abandon(channel);
      if (_intentionalClose || session != _session) return;
      final error = Exception('Timed out connecting to the media engine at $url');
      if (_openedOnce) {
        _scheduleReconnect();
        return;
      }
      onLink?.call(MediaEngineLink.disconnected);
      throw error;
    } catch (error) {
      await _abandon(channel);
      if (_intentionalClose || session != _session) return;
      if (_openedOnce) {
        _log.warning('Media engine reconnect failed: $error');
        _scheduleReconnect();
        return;
      }
      onLink?.call(MediaEngineLink.disconnected);
      rethrow;
    }

    if (_intentionalClose || session != _session) {
      await _abandon(channel);
      return;
    }

    await _tearDownSocket();
    if (_intentionalClose || session != _session) {
      await _abandon(channel);
      return;
    }
    _channel = channel;
    _socketOpen = true;
    _openedOnce = true;
    final peer = JsonRpcPeer(send: (message) => channel.sink.add(message));
    _peer = peer;
    _peerEvents = peer.events.listen(_forwardEvent);
    _subscription = channel.stream.listen(
      (message) => _onSocketMessage(peer, message),
      onError: (Object error, StackTrace stackTrace) {
        _log.warning('Media engine socket error: $error', error, stackTrace);
        unawaited(_handleSocketClosed());
      },
      onDone: () {
        unawaited(_handleSocketClosed());
      },
    );
    _log.info('Media engine connected: $url');
    onLink?.call(MediaEngineLink.connected);
  }

  void _onSocketMessage(JsonRpcPeer peer, dynamic message) {
    if (message is String) {
      peer.handleMessage(message);
    } else if (message is List<int>) {
      peer.handleMessage(utf8.decode(message));
    }
  }

  void _forwardEvent(Map<String, dynamic> event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  Future<void> _handleSocketClosed() async {
    if (!_socketOpen) return;
    _log.info('Media engine socket closed');
    await _tearDownSocket();
    onLink?.call(MediaEngineLink.disconnected);
    _scheduleReconnect();
  }

  Future<void> _tearDownSocket() async {
    _socketOpen = false;
    final subscription = _subscription;
    final peerEvents = _peerEvents;
    final channel = _channel;
    final peer = _peer;
    _subscription = null;
    _peerEvents = null;
    _channel = null;
    _peer = null;
    peer?.close();
    await peerEvents?.cancel();
    await subscription?.cancel();
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (error) {
        _log.fine('Ignoring socket close error: $error');
      }
    }
  }

  Future<void> _abandon(WebSocketChannel channel) async {
    try {
      await channel.sink.close();
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (_intentionalClose || _url == null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_intentionalClose) return;
      unawaited(_open());
    });
  }
}
