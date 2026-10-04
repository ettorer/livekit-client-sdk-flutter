import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'json_rpc.dart';
import 'media_engine_client.dart';
import 'media_engine_state.dart';

final _log = Logger('VdiMediaEngine');

/// Screen rectangle sent to `set_geometry`. Values are root-window pixels.
class TileRect {
  const TileRect({required this.x, required this.y, required this.width, required this.height});

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is TileRect && other.x == x && other.y == y && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// Room state mirrored from the media engine, plus tile placement.
class MediaEngineController extends ChangeNotifier {
  MediaEngineClient? _client;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  final _windows = VideoWindowStore();
  final _inflightWindowTouches = <Set<String>>[];
  final _pendingGeometry = <String, TileRect>{};
  final _lastGeometry = <String, TileRect>{};

  LiveKitStatus _status = const LiveKitStatus();
  MediaEngineLink _link = MediaEngineLink.disconnected;
  String _lastError = '';
  Timer? _geometryTimer;
  Timer? _refreshTimer;
  var _statusGeneration = 0;
  var _busy = false;
  var _shutDown = false;
  var _quitStarted = false;
  var _initialSyncDone = false;
  var _flushingGeometry = false;
  bool? _overlayHidden;
  Future<void>? _overlayChain;

  LiveKitStatus get status => _status;

  MediaEngineLink get link => _link;

  List<VideoWindowInfo> get windows => _windows.windows;

  String get lastError => _lastError;

  bool get busy => _busy;

  /// Called for `data_received` and `chat` events. Not tied to [notifyListeners].
  void Function(Map<String, dynamic> event)? onDataReceived;

  bool get isShutdown => _shutDown || _quitStarted;

  bool get isQuitting => _quitStarted;

  Future<void> open(String url, {bool syncWindows = true}) async {
    final client = MediaEngineClient(onLink: _handleLink);
    _client = client;
    _eventsSub = client.events.listen(_onEvent);
    await client.connect(url);
    if (_shutDown || _quitStarted) return;
    await _syncStatus();
    if (_shutDown || _quitStarted) return;
    if (syncWindows) await _syncWindows();
    _initialSyncDone = true;
  }

  /// Joins [url] unless the engine is already in that room.
  Future<void> ensureRoom({required String url, required String token}) async {
    if (_shutDown || _quitStarted) return;
    final sameRoom = _status.isInRoom && _status.url == url;
    if (sameRoom) return;
    if (_status.connection != 'disconnected') {
      await disconnectRoom();
      if (_shutDown || _quitStarted) return;
      await _waitFor((status) => status.connection == 'disconnected');
    }
    if (_shutDown || _quitStarted) return;
    try {
      await _client?.connectRoom(url: url, token: token);
    } on JsonRpcException catch (error) {
      if (error.code == -32000 && error.message.toLowerCase().contains('already connected')) {
        await _syncAll();
        return;
      }
      rethrow;
    }
    _status = _status.copyWith(connection: 'connecting', connected: false, url: url, lastError: '');
    _lastError = '';
    _notify();
  }

  Future<void> disconnectRoom() async {
    if (_quitStarted) return;
    final client = _client;
    if (client == null) return;
    try {
      await client.disconnect();
    } on JsonRpcException catch (error) {
      if (error.code == -32000) return;
      rethrow;
    }
  }

  Future<void> startVideo() => _guard(() => _client!.startVideo());

  Future<void> stopVideo() => _guard(() => _client!.stopVideo());

  Future<void> startAudio() => _guard(() => _client!.startAudio());

  Future<void> stopAudio() => _guard(() => _client!.stopAudio());

  Future<void> publishData({required String topic, required String data}) async {
    final client = _client;
    if (client == null || _shutDown) {
      throw StateError('Media engine is not connected');
    }
    await client.publishData(topic: topic, data: data);
  }

  void clearError() {
    if (_lastError.isEmpty) return;
    _lastError = '';
    _notify();
  }

  /// Hides every media-engine window, or places them again when the app is restored.
  ///
  /// Restore does not send `show`. It forgets the last rect so the room
  /// re-sends `set_geometry`, and the engine shows a hidden window when it
  /// applies that rect.
  Future<void> setOverlayHidden(bool hidden) {
    final scheduled = (_overlayChain ?? Future<void>.value()).then((_) => _sendOverlayState(hidden));
    _overlayChain = scheduled.catchError((Object error) {
      _log.warning('set_window_state failed: $error');
    });
    return scheduled;
  }

  Future<void> _sendOverlayState(bool hidden) async {
    if (_shutDown || _quitStarted || _overlayHidden == hidden) return;
    _overlayHidden = hidden;
    if (hidden) {
      _geometryTimer?.cancel();
      _geometryTimer = null;
      _pendingGeometry.clear();
      final client = _client;
      if (client == null) return;
      try {
        await client.setWindowState(windowId: 'all', state: 'hide');
      } catch (error) {
        if (_overlayHidden == true) _overlayHidden = null;
        _log.warning('set_window_state hide failed: $error');
      }
      return;
    }
    _lastGeometry.clear();
    _notify();
  }

  void _hideWindowWhileMinimized(String windowId) {
    if (windowId.isEmpty) return;
    final scheduled = (_overlayChain ?? Future<void>.value()).then((_) async {
      if (_overlayHidden != true || _shutDown || _quitStarted) return;
      final client = _client;
      if (client == null) return;
      try {
        await client.setWindowState(windowId: windowId, state: 'hide');
      } catch (error) {
        _log.warning('set_window_state hide $windowId failed: $error');
      }
    });
    _overlayChain = scheduled.catchError((Object error) {
      _log.warning('set_window_state failed: $error');
    });
  }

  /// Queues a `set_geometry` for [windowId] when the tile has moved or resized.
  void reportGeometry(String windowId, TileRect rect) {
    if (_shutDown || _quitStarted || _overlayHidden == true || rect.width < 2 || rect.height < 2) return;
    if (_lastGeometry[windowId] == rect) return;
    _pendingGeometry[windowId] = rect;
    if (_flushingGeometry) return;
    _geometryTimer ??= Timer(const Duration(milliseconds: 40), () {
      unawaited(_flushGeometry());
    });
  }

  Future<void> shutdown() async {
    if (_shutDown || _quitStarted) return;
    _shutDown = true;
    _geometryTimer?.cancel();
    _refreshTimer?.cancel();
    _pendingGeometry.clear();
    await _eventsSub?.cancel();
    _eventsSub = null;
    final client = _client;
    if (client != null &&
        (_status.isInRoom || _status.connection == 'connecting' || _status.connection == 'disconnecting')) {
      try {
        await client.disconnect().timeout(const Duration(seconds: 3));
      } catch (error) {
        _log.fine('Disconnect before closing media engine socket: $error');
      }
    }
    await _client?.close();
    _client = null;
  }

  /// Stops published local media, then asks the media engine process to exit.
  ///
  /// Local means the engine's own publish flags (`status.video` / `status.audio`),
  /// not a remote participant. A later [shutdown] is a no-op.
  Future<void> quitEngine() async {
    if (_shutDown || _quitStarted) return;
    _quitStarted = true;
    _geometryTimer?.cancel();
    _geometryTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _pendingGeometry.clear();
    final client = _client;
    if (client == null) {
      _shutDown = true;
      return;
    }
    try {
      await _stopPublished(video: true);
      await _stopPublished(video: false);
      try {
        await client.quit().timeout(const Duration(seconds: 3));
      } catch (error) {
        _log.warning('Quit media engine failed: $error');
      }
    } finally {
      _shutDown = true;
      await _eventsSub?.cancel();
      _eventsSub = null;
      await client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  Future<void> _stopPublished({required bool video}) async {
    final client = _client;
    if (client == null) return;
    if (video ? !_status.video : !_status.audio) return;
    final method = video ? 'stop_video' : 'stop_audio';
    try {
      final call = video ? client.stopVideo() : client.stopAudio();
      await call.timeout(const Duration(seconds: 3));
    } catch (error) {
      _log.warning('$method before quit failed: $error');
    }
    await _waitUntil(
      (status) => video ? !status.video : !status.audio,
      const Duration(milliseconds: 1500),
    );
  }

  Future<void> _waitUntil(bool Function(LiveKitStatus status) test, Duration timeout) async {
    if (test(_status)) return;
    final completer = Completer<void>();
    void listener() {
      if (!completer.isCompleted && test(_status)) {
        completer.complete();
      }
    }

    addListener(listener);
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      _log.warning('Timed out waiting for published media to stop');
    } finally {
      removeListener(listener);
    }
  }

  Future<void> _waitFor(bool Function(LiveKitStatus status) test) async {
    if (_shutDown || test(_status)) return;
    final completer = Completer<void>();
    void listener() {
      if (!completer.isCompleted && (_shutDown || test(_status))) {
        completer.complete();
      }
    }

    addListener(listener);
    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _log.warning('Timed out waiting for the media engine');
    } finally {
      removeListener(listener);
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy || _shutDown || _quitStarted || _client == null) return;
    _busy = true;
    _notify();
    try {
      await action();
    } finally {
      _busy = false;
      if (!_shutDown) _notify();
    }
  }

  void _handleLink(MediaEngineLink link) {
    _link = link;
    _notify();
    if (link == MediaEngineLink.connected && _initialSyncDone && !_shutDown && !_quitStarted) {
      unawaited(_syncAll());
    }
  }

  Future<void> _syncAll() async {
    await _syncStatus();
    await _syncWindows();
  }

  Future<void> _syncStatus() async {
    final client = _client;
    if (client == null || _shutDown || _quitStarted) return;
    for (var attempt = 0; attempt < 3; attempt++) {
      final generation = _statusGeneration;
      final status = await client.getStatus();
      if (_shutDown || _quitStarted) return;
      if (generation == _statusGeneration) {
        _applyStatus(status);
        return;
      }
    }
  }

  Future<void> _syncWindows() async {
    final client = _client;
    if (client == null || _shutDown || _quitStarted) return;
    final touched = <String>{};
    _inflightWindowTouches.add(touched);
    try {
      final snapshot = await client.getVideoList();
      if (_shutDown || _quitStarted) return;
      _windows.applySnapshot(snapshot, touchedDuring: touched);
      _notify();
    } finally {
      _inflightWindowTouches.remove(touched);
    }
  }

  void _applyStatus(LiveKitStatus status) {
    _status = status;
    if (status.lastError.isNotEmpty) {
      _lastError = status.lastError;
    }
    _notify();
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_shutDown) return;
    final name = event['event'] as String? ?? '';
    switch (name) {
      case 'connected':
        _bumpStatus();
        _lastError = '';
        _status = _status.copyWith(
          connection: 'connected',
          connected: true,
          room: event['room'] as String? ?? _status.room,
          identity: event['identity'] as String? ?? _status.identity,
          lastError: '',
        );
        break;
      case 'disconnected':
        _bumpStatus();
        _windows.clear();
        _lastGeometry.clear();
        _pendingGeometry.clear();
        _status = _status.copyWith(
          connection: 'disconnected',
          connected: false,
          video: false,
          audio: false,
          remoteParticipants: const [],
        );
        break;
      case 'error':
        _bumpStatus();
        _lastError = event['message'] as String? ?? 'Media engine error';
        _status = _status.copyWith(lastError: _lastError);
        break;
      case 'participant_connected':
        _bumpStatus();
        _addParticipant(event['identity'] as String? ?? '');
        break;
      case 'participant_disconnected':
        _bumpStatus();
        _removeParticipant(event['identity'] as String? ?? '');
        break;
      case 'media_state':
        _bumpStatus();
        _status = _status.copyWith(
          video: event['video'] as bool? ?? _status.video,
          audio: event['audio'] as bool? ?? _status.audio,
        );
        break;
      case 'window_created':
        _onWindowCreated(VideoWindowInfo.fromJson(event));
        break;
      case 'window_destroyed':
        _onWindowDestroyed(event['window_id'] as String? ?? '');
        break;
      case 'data_received':
      case 'chat':
        onDataReceived?.call(event);
        return;
      default:
        return;
    }
    _notify();
  }

  void _addParticipant(String identity) {
    if (identity.isEmpty || _status.remoteParticipants.contains(identity)) return;
    _status = _status.copyWith(remoteParticipants: [..._status.remoteParticipants, identity]);
  }

  void _removeParticipant(String identity) {
    _status = _status.copyWith(
      remoteParticipants: _status.remoteParticipants.where((id) => id != identity).toList(),
    );
  }

  void _onWindowCreated(VideoWindowInfo info) {
    _touchWindow(info.windowId);
    _windows.upsert(info);
    _scheduleWindowRefresh();
    if (_overlayHidden == true) {
      _hideWindowWhileMinimized(info.windowId);
    }
  }

  void _onWindowDestroyed(String windowId) {
    _touchWindow(windowId);
    _windows.remove(windowId);
    _lastGeometry.remove(windowId);
    _pendingGeometry.remove(windowId);
    _scheduleWindowRefresh();
  }

  void _bumpStatus() => _statusGeneration++;

  void _touchWindow(String windowId) {
    if (windowId.isEmpty) return;
    for (final touched in _inflightWindowTouches) {
      touched.add(windowId);
    }
  }

  void _scheduleWindowRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 50), () {
      unawaited(_syncWindows());
    });
  }

  Future<void> _flushGeometry() async {
    _geometryTimer = null;
    if (_pendingGeometry.isEmpty || _shutDown || _quitStarted || _overlayHidden == true) return;
    final client = _client;
    if (client == null) return;
    _flushingGeometry = true;
    final batch = Map<String, TileRect>.of(_pendingGeometry);
    _pendingGeometry.clear();
    try {
      for (final entry in batch.entries) {
        if (_shutDown || _quitStarted || _overlayHidden == true) return;
        if (_lastGeometry[entry.key] == entry.value) continue;
        final rect = entry.value;
        try {
          await client.setGeometry(
            windowId: entry.key,
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
          );
          _lastGeometry[entry.key] = rect;
          _log.fine(
            'set_geometry ${entry.key} -> ${rect.x},${rect.y} ${rect.width}x${rect.height}',
          );
        } on JsonRpcException catch (error) {
          if (error.code == -32602) {
            _lastGeometry[entry.key] = rect;
          }
          _log.warning('set_geometry ${entry.key} failed: $error');
        } catch (error) {
          _log.warning('set_geometry ${entry.key} failed: $error');
        }
      }
    } finally {
      _flushingGeometry = false;
      if (_pendingGeometry.isNotEmpty && !_shutDown && !_quitStarted && _overlayHidden != true) {
        _geometryTimer = Timer(const Duration(milliseconds: 40), () {
          unawaited(_flushGeometry());
        });
      }
    }
  }

  void _notify() {
    if (!_shutDown) notifyListeners();
  }
}
