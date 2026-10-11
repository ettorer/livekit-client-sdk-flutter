import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One video widget in Flutter view logical pixels.
///
/// Origin is the top-left of the Flutter view. [right] and [bottom] are
/// exclusive.
class VisibleWidgetBounds {
  const VisibleWidgetBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// A rectangle in physical screen pixels on the machine running Flutter.
///
/// [right] and [bottom] are exclusive.
class VisibleScreenRect {
  const VisibleScreenRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;

  bool get isEmpty => left >= right || top >= bottom;

  @override
  bool operator ==(Object other) =>
      other is VisibleScreenRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Visible pieces of one widget, in the same order the native query returned.
class VisibleWidgetRegion {
  const VisibleWidgetRegion({required this.bounds, required this.rectangles});

  /// Unclipped widget rectangle in physical screen pixels.
  ///
  /// Null when the widget could not be mapped. [rectangles] is then empty:
  /// nothing of that widget is showing.
  final VisibleScreenRect? bounds;

  /// Pieces still showing, in physical screen pixels.
  final List<VisibleScreenRect> rectangles;
}

/// Asks Windows which parts of each Flutter widget are showing.
///
/// The query runs in this process. Video windows drawn on the remote-desktop
/// client PC are not part of the result. Other platforms return null.
class VdiVisibleRegion {
  static const channel = MethodChannel('livekit_example/vdi_visible_region');

  /// One Z-order walk for every widget. Results are in [widgets] order.
  ///
  /// Returns null when the platform has no plugin or the call fails. The
  /// caller keeps the previous regions in that case.
  static Future<List<VisibleWidgetRegion>?> getVisibleRegions({
    required int viewId,
    required double devicePixelRatio,
    required List<VisibleWidgetBounds> widgets,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return null;
    try {
      final raw = await channel.invokeMethod<dynamic>('getVisibleRegions', {
        'viewId': viewId,
        'devicePixelRatio': devicePixelRatio,
        'widgets': [
          for (final widget in widgets)
            {
              'left': widget.left,
              'top': widget.top,
              'right': widget.right,
              'bottom': widget.bottom,
            },
        ],
      });
      return _parse(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static List<VisibleWidgetRegion>? _parse(Object? raw) {
    if (raw is! List) return null;
    final regions = <VisibleWidgetRegion>[];
    for (final entry in raw) {
      if (entry is! Map) return null;
      final rectList = entry['rectangles'];
      if (rectList is! List) return null;
      final rectangles = <VisibleScreenRect>[];
      for (final rect in rectList) {
        final parsed = _screenRect(rect);
        if (parsed == null) return null;
        rectangles.add(parsed);
      }
      VisibleScreenRect? bounds;
      if (entry.containsKey('left')) {
        bounds = _screenRect(entry);
        if (bounds == null) return null;
      }
      regions.add(VisibleWidgetRegion(bounds: bounds, rectangles: rectangles));
    }
    return regions;
  }

  static VisibleScreenRect? _screenRect(Object? raw) {
    if (raw is! Map) return null;
    return VisibleScreenRect(
      left: _asInt(raw['left']),
      top: _asInt(raw['top']),
      right: _asInt(raw['right']),
      bottom: _asInt(raw['bottom']),
    );
  }

  static int _asInt(Object? value) => value is num ? value.toInt() : 0;
}
