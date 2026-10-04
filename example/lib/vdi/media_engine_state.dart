/// Link between this app and the C++ media engine WebSocket.
enum MediaEngineLink { disconnected, connecting, connected }

/// Snapshot returned by `get_status`, kept up to date by events.
class LiveKitStatus {
  const LiveKitStatus({
    this.connection = 'disconnected',
    this.connected = false,
    this.url = '',
    this.room = '',
    this.identity = '',
    this.video = false,
    this.audio = false,
    this.remoteParticipants = const [],
    this.lastError = '',
    this.backend = '',
    this.rpcClients = 0,
  });

  factory LiveKitStatus.fromJson(Map<String, dynamic> json) {
    final participants = json['remote_participants'];
    return LiveKitStatus(
      connection: json['connection'] as String? ?? 'disconnected',
      connected: json['connected'] as bool? ?? false,
      url: json['url'] as String? ?? '',
      room: json['room'] as String? ?? '',
      identity: json['identity'] as String? ?? '',
      video: json['video'] as bool? ?? false,
      audio: json['audio'] as bool? ?? false,
      remoteParticipants: participants is List ? participants.map((entry) => '$entry').toList() : const [],
      lastError: json['last_error'] as String? ?? '',
      backend: json['backend'] as String? ?? '',
      rpcClients: json['rpc_clients'] is num ? (json['rpc_clients'] as num).toInt() : 0,
    );
  }

  final String connection;
  final bool connected;
  final String url;
  final String room;
  final String identity;
  final bool video;
  final bool audio;
  final List<String> remoteParticipants;
  final String lastError;
  final String backend;
  final int rpcClients;

  bool get isInRoom => connected || connection == 'connected';

  LiveKitStatus copyWith({
    String? connection,
    bool? connected,
    String? url,
    String? room,
    String? identity,
    bool? video,
    bool? audio,
    List<String>? remoteParticipants,
    String? lastError,
    String? backend,
    int? rpcClients,
  }) =>
      LiveKitStatus(
        connection: connection ?? this.connection,
        connected: connected ?? this.connected,
        url: url ?? this.url,
        room: room ?? this.room,
        identity: identity ?? this.identity,
        video: video ?? this.video,
        audio: audio ?? this.audio,
        remoteParticipants: remoteParticipants ?? this.remoteParticipants,
        lastError: lastError ?? this.lastError,
        backend: backend ?? this.backend,
        rpcClients: rpcClients ?? this.rpcClients,
      );
}

/// One undecorated video window owned by the media engine.
class VideoWindowInfo {
  const VideoWindowInfo({
    required this.windowId,
    required this.type,
    required this.identity,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.visible,
  });

  factory VideoWindowInfo.fromJson(Map<String, dynamic> json) => VideoWindowInfo(
        windowId: json['window_id'] as String? ?? '',
        type: json['type'] as String? ?? '',
        identity: json['identity'] as String? ?? '',
        x: _asInt(json['x']),
        y: _asInt(json['y']),
        width: _asInt(json['width']),
        height: _asInt(json['height']),
        visible: json['visible'] as bool? ?? true,
      );

  final String windowId;
  final String type;
  final String identity;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool visible;

  bool get isLocal => type == 'local' || windowId == 'local';

  String get label {
    if (isLocal) {
      return identity.isEmpty ? 'You' : '$identity (you)';
    }
    if (identity.isNotEmpty) return identity;
    return windowId;
  }

  @override
  bool operator ==(Object other) =>
      other is VideoWindowInfo &&
      other.windowId == windowId &&
      other.type == type &&
      other.identity == identity &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.visible == visible;

  @override
  int get hashCode => Object.hash(windowId, type, identity, x, y, width, height, visible);
}

int _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

/// Windows reported by the media engine.
///
/// Events are applied immediately. A `get_video_list` snapshot that was in
/// flight while those events arrived is merged so a stale response cannot
/// drop a window that was just created, or resurrect one that was destroyed.
class VideoWindowStore {
  final List<VideoWindowInfo> _windows = [];

  List<VideoWindowInfo> get windows => List<VideoWindowInfo>.unmodifiable(_windows);

  void upsert(VideoWindowInfo info) {
    if (info.windowId.isEmpty) return;
    final index = _windows.indexWhere((window) => window.windowId == info.windowId);
    if (index >= 0) {
      _windows[index] = info;
    } else {
      _windows.add(info);
    }
    _sort();
  }

  /// Removes [windowId]. Repeated removals are ignored.
  bool remove(String windowId) {
    final before = _windows.length;
    _windows.removeWhere((window) => window.windowId == windowId);
    return _windows.length != before;
  }

  void clear() => _windows.clear();

  void applySnapshot(
    List<VideoWindowInfo> snapshot, {
    required Set<String> touchedDuring,
  }) {
    if (touchedDuring.isEmpty) {
      _windows
        ..clear()
        ..addAll(snapshot.where((window) => window.windowId.isNotEmpty));
      _sort();
      return;
    }

    final current = {for (final window in _windows) window.windowId: window};
    final merged = <String, VideoWindowInfo>{};
    final snapshotIds = <String>{};

    for (final window in snapshot) {
      if (window.windowId.isEmpty) continue;
      snapshotIds.add(window.windowId);
      if (touchedDuring.contains(window.windowId)) {
        final updated = current[window.windowId];
        if (updated != null) merged[window.windowId] = updated;
        continue;
      }
      merged[window.windowId] = window;
    }

    for (final entry in current.entries) {
      if (touchedDuring.contains(entry.key) && !snapshotIds.contains(entry.key)) {
        merged[entry.key] = entry.value;
      }
    }

    _windows
      ..clear()
      ..addAll(merged.values);
    _sort();
  }

  void _sort() {
    _windows.sort((a, b) {
      if (a.isLocal != b.isLocal) return a.isLocal ? -1 : 1;
      return a.label.compareTo(b.label);
    });
  }
}
