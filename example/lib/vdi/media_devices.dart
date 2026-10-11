/// Devices and the current selection returned by `get_media` / `set_media`.
class MediaDeviceSnapshot {
  const MediaDeviceSnapshot({
    this.cameras = const [],
    this.audioInputs = const [],
    this.audioOutputs = const [],
    this.selected = const MediaDeviceChoice(),
    this.defaults = const MediaDeviceChoice(),
    this.audioError = '',
  });

  factory MediaDeviceSnapshot.fromJson(Map<String, dynamic> json) {
    return MediaDeviceSnapshot(
      cameras: _devices(json['cameras']),
      audioInputs: _devices(json['audio_inputs']),
      audioOutputs: _devices(json['audio_outputs']),
      selected: MediaDeviceChoice.fromJson(_object(json['selected'])),
      defaults: MediaDeviceChoice.fromJson(_object(json['default'])),
      audioError: json['audio_error'] as String? ?? '',
    );
  }

  final List<EngineMediaDevice> cameras;
  final List<EngineMediaDevice> audioInputs;
  final List<EngineMediaDevice> audioOutputs;
  final MediaDeviceChoice selected;
  final MediaDeviceChoice defaults;
  final String audioError;

  /// Keeps the device lists and applies [update]'s selection.
  ///
  /// `set_media` returns `selected` and `default` only.
  MediaDeviceSnapshot applying(MediaDeviceSnapshot update) {
    return MediaDeviceSnapshot(
      cameras: cameras,
      audioInputs: audioInputs,
      audioOutputs: audioOutputs,
      selected: update.selected,
      defaults: update.defaults,
      audioError: audioError,
    );
  }
}

/// One camera, microphone, or speaker. Send [id] to the engine. Show [name].
class EngineMediaDevice {
  const EngineMediaDevice({required this.id, required this.name, this.index});

  final String id;
  final String name;
  final int? index;

  String label({required String defaultId}) {
    final text = name.isEmpty ? id : name;
    if (defaultId.isNotEmpty && id == defaultId) return '$text (default)';
    return text;
  }
}

/// Ids currently selected, or the platform defaults. Empty means none.
class MediaDeviceChoice {
  const MediaDeviceChoice({this.camera = '', this.audioInput = '', this.audioOutput = ''});

  factory MediaDeviceChoice.fromJson(Map<String, dynamic> json) {
    return MediaDeviceChoice(
      camera: json['camera'] as String? ?? '',
      audioInput: json['audio_input'] as String? ?? '',
      audioOutput: json['audio_output'] as String? ?? '',
    );
  }

  final String camera;
  final String audioInput;
  final String audioOutput;
}

/// Dropdown value: [preferred] when it is in [devices], otherwise [fallback], otherwise the first id.
String? listedDeviceId(List<EngineMediaDevice> devices, String preferred, String fallback) {
  if (devices.any((device) => device.id == preferred)) return preferred;
  if (devices.any((device) => device.id == fallback)) return fallback;
  if (devices.isEmpty) return null;
  return devices.first.id;
}

List<EngineMediaDevice> _devices(Object? value) {
  if (value is! List) return const [];
  final devices = <EngineMediaDevice>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final json = Map<String, dynamic>.from(entry);
    final id = json['id'] as String? ?? '';
    if (id.isEmpty) continue;
    final index = json['index'];
    devices.add(
      EngineMediaDevice(
        id: id,
        name: json['name'] as String? ?? '',
        index: index is num ? index.toInt() : null,
      ),
    );
  }
  return devices;
}

Map<String, dynamic> _object(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}
