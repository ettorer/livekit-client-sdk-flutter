#ifndef VDI_VISIBLE_REGION_VISIBLE_REGION_H_
#define VDI_VISIBLE_REGION_VISIBLE_REGION_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <vector>

namespace vdi_visible_region {

// One widget rectangle in Flutter view logical pixels, origin at the top-left
// of the Flutter view client area. Right and bottom are exclusive.
struct WidgetBoundsQuery {
  double left = 0;
  double top = 0;
  double right = 0;
  double bottom = 0;
};

// Rectangles are physical screen pixels, exclusive of right and bottom.
// Video windows drawn on the remote-desktop client are not in this process
// and are not subtracted here.
struct WidgetVisibleRegion {
  // Unclipped widget rectangle mapped into screen pixels.
  RECT widget_screen{};
  bool has_widget = false;
  // Pieces still showing after the view clip, the virtual screen, and
  // top-level windows above the Flutter window.
  std::vector<RECT> rectangles;
};

struct VisibleRegionBatch {
  std::vector<WidgetVisibleRegion> widgets;
};

// One Z-order walk for every widget. [view_window] is the Flutter view HWND,
// not the top-level frame, so the title bar is outside the widget rects.
// [root_window] is where the walk stops; windows behind it are ignored.
VisibleRegionBatch QueryVisibleRegions(HWND root_window,
                                       HWND view_window,
                                       double device_pixel_ratio,
                                       const std::vector<WidgetBoundsQuery>& widgets);

}  // namespace vdi_visible_region

#endif  // VDI_VISIBLE_REGION_VISIBLE_REGION_H_
