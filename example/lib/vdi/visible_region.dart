import 'package:vdi_visible_region/vdi_visible_region.dart';

/// How often to re-read occlusion while tile geometry is otherwise stable.
const Duration visibleRegionInterval = Duration(milliseconds: 300);

/// One piece of a video widget that is actually showing.
///
/// Coordinates are relative to the widget rectangle `set_geometry` places.
/// [right] and [bottom] are exclusive. The unit matches `width` and `height`:
/// physical pixels on Windows, GTK application pixels on Linux.
class RegionRect {
  const RegionRect({required this.left, required this.top, required this.right, required this.bottom});

  final int left;
  final int top;
  final int right;
  final int bottom;

  Map<String, int> toJson() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };

  @override
  bool operator ==(Object other) =>
      other is RegionRect && other.left == left && other.top == top && other.right == right && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Widget-relative regions for one `set_geometry` call.
///
/// [widgetScreen] and [screenRects] are physical screen pixels from the Win32
/// query. [width] and [height] are the size already used for `set_geometry`.
/// On Windows that size is physical pixels, so these deltas are not divided
/// by the device pixel ratio.
List<RegionRect> regionsForWidget({
  required VisibleScreenRect widgetScreen,
  required int width,
  required int height,
  required List<VisibleScreenRect> screenRects,
}) {
  if (width < 1 || height < 1 || screenRects.isEmpty) return const [];
  if (screenRects.length == 1 && screenRects.single == widgetScreen) {
    return [RegionRect(left: 0, top: 0, right: width, bottom: height)];
  }

  final regions = <RegionRect>[];
  for (final screen in screenRects) {
    final left = (screen.left - widgetScreen.left).clamp(0, width).toInt();
    final top = (screen.top - widgetScreen.top).clamp(0, height).toInt();
    final right = (screen.right - widgetScreen.left).clamp(0, width).toInt();
    final bottom = (screen.bottom - widgetScreen.top).clamp(0, height).toInt();
    if (left >= right || top >= bottom) continue;
    regions.add(RegionRect(left: left, top: top, right: right, bottom: bottom));
  }
  return regions;
}

class _RegionEntry {
  const _RegionEntry(this.width, this.height, this.regions);

  final int width;
  final int height;
  final List<RegionRect> regions;
}

/// Last regions sent for each video window, keyed by window id.
class RegionCache {
  final _entries = <String, _RegionEntry>{};

  void retain(Set<String> ids) {
    _entries.removeWhere((id, _) => !ids.contains(id));
  }

  void clear() => _entries.clear();

  void put(String id, {required int width, required int height, required List<RegionRect> regions}) {
    _entries[id] = _RegionEntry(width, height, regions);
  }

  /// Regions queried for this size, or one full rectangle when none match.
  ///
  /// An empty list is kept: it means the widget is fully covered. A size
  /// change drops that list so a resize is not clipped with the old shape.
  List<RegionRect> forGeometry(String id, int width, int height) {
    final entry = _entries[id];
    if (entry == null || entry.width != width || entry.height != height) {
      return [RegionRect(left: 0, top: 0, right: width, bottom: height)];
    }
    return entry.regions;
  }
}
