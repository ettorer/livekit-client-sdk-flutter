import 'package:flutter/services.dart';

/// Screen origin of the Flutter view, in the coordinate space `set_geometry` uses.
///
/// On Linux, [x] and [y] are GTK application pixels. Those already match
/// Flutter logical pixels, so [devicePixels] is false and [scale] is ignored.
/// Multiplying by the GDK scale double-sizes windows on a 150% desktop.
///
/// On Windows, [x] and [y] are physical screen pixels (`ClientToScreen`) and
/// [devicePixels] is true. Tile offsets and sizes are logical pixels, so they
/// are multiplied by [scale] (`dpi / 96`) before being added.
class VdiViewOrigin {
  const VdiViewOrigin({
    required this.x,
    required this.y,
    required this.scale,
    required this.devicePixels,
  });

  static const fallback = VdiViewOrigin(x: 0, y: 0, scale: 1, devicePixels: false);

  final int x;
  final int y;
  final double scale;
  final bool devicePixels;

  int toScreenX(double logical) => (x + logical * _factor).round();

  int toScreenY(double logical) => (y + logical * _factor).round();

  int toScreenSize(double logical) => (logical * _factor).round();

  double get _factor => devicePixels && scale > 0 ? scale : 1;
}

/// Reads the Flutter view origin from the desktop runner.
class VdiViewLocator {
  static const _channel = MethodChannel('livekit_example/vdi_window');

  static Future<VdiViewOrigin?> getOrigin() async {
    try {
      final result = await _channel.invokeMethod<dynamic>('getViewOrigin');
      if (result is! Map) return null;
      final scale = _asDouble(result['scale']);
      return VdiViewOrigin(
        x: _asInt(result['x']),
        y: _asInt(result['y']),
        scale: scale <= 0 ? 1 : scale,
        devicePixels: result['devicePixels'] == true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static int _asInt(Object? value) => value is num ? value.toInt() : 0;

  static double _asDouble(Object? value) => value is num ? value.toDouble() : 1;
}
