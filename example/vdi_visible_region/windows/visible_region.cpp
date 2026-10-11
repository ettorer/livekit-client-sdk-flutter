#include "visible_region.h"

#include <dwmapi.h>

#include <algorithm>
#include <cmath>

namespace vdi_visible_region {
namespace {

bool IsEmptyRect(const RECT& rect) {
  return rect.left >= rect.right || rect.top >= rect.bottom;
}

RECT NormalizeRect(LONG left, LONG top, LONG right, LONG bottom) {
  return RECT{std::min(left, right), std::min(top, bottom), std::max(left, right),
              std::max(top, bottom)};
}

RECT VirtualScreenRect() {
  const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  return RECT{left, top, left + GetSystemMetrics(SM_CXVIRTUALSCREEN),
              top + GetSystemMetrics(SM_CYVIRTUALSCREEN)};
}

RECT ViewClientScreenRect(HWND view_window) {
  RECT client{};
  GetClientRect(view_window, &client);
  POINT top_left{0, 0};
  POINT bottom_right{client.right, client.bottom};
  ClientToScreen(view_window, &top_left);
  ClientToScreen(view_window, &bottom_right);
  return RECT{top_left.x, top_left.y, bottom_right.x, bottom_right.y};
}

bool Intersect(const RECT& a, const RECT& b, RECT* out) {
  RECT intersection{};
  if (!IntersectRect(&intersection, &a, &b) || IsEmptyRect(intersection)) {
    return false;
  }
  *out = intersection;
  return true;
}

std::vector<RECT> RectanglesOfRegion(HRGN region) {
  const DWORD bytes = GetRegionData(region, 0, nullptr);
  if (bytes == 0) {
    return {};
  }
  std::vector<BYTE> buffer(bytes);
  auto* data = reinterpret_cast<RGNDATA*>(buffer.data());
  if (GetRegionData(region, bytes, data) != bytes) {
    return {};
  }
  const auto* rects = reinterpret_cast<const RECT*>(data->Buffer);
  return std::vector<RECT>(rects, rects + data->rdh.nCount);
}

HRGN CreateEmptyRegion() {
  return CreateRectRgn(0, 0, 0, 0);
}

// Window shape in screen pixels. A custom window region wins; otherwise the
// DWM extended frame bounds are used so the invisible resize shadow is not
// treated as covering the widgets.
HRGN CreateWindowShapeRegion(HWND hwnd) {
  RECT window_rect{};
  if (!GetWindowRect(hwnd, &window_rect)) {
    return CreateEmptyRegion();
  }

  HRGN custom = CreateEmptyRegion();
  if (custom == nullptr) {
    return nullptr;
  }
  const int kind = GetWindowRgn(hwnd, custom);
  if (kind != ERROR && kind != NULLREGION) {
    OffsetRgn(custom, window_rect.left, window_rect.top);
    return custom;
  }
  DeleteObject(custom);

  RECT frame = window_rect;
  RECT extended{};
  if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &extended,
                                      sizeof(extended))) &&
      !IsEmptyRect(extended)) {
    frame = extended;
  }
  HRGN region = CreateRectRgnIndirect(&frame);
  return region != nullptr ? region : CreateEmptyRegion();
}

bool IsCloaked(HWND hwnd) {
  DWORD cloaked = 0;
  const HRESULT hr = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  return SUCCEEDED(hr) && cloaked != 0;
}

bool CanOcclude(HWND hwnd, HWND root_window) {
  if (hwnd == nullptr || hwnd == root_window || !IsWindow(hwnd) || !IsWindowVisible(hwnd) ||
      IsIconic(hwnd) || IsCloaked(hwnd)) {
    return false;
  }

  wchar_t class_name[64] = {};
  if (GetClassNameW(hwnd, class_name, 64) > 0 && wcscmp(class_name, L"SysShadow") == 0) {
    return false;
  }

  const LONG ex_style = GetWindowLongW(hwnd, GWL_EXSTYLE);
  if ((ex_style & WS_EX_TRANSPARENT) != 0) {
    return false;
  }
  if ((ex_style & WS_EX_LAYERED) != 0) {
    BYTE alpha = 255;
    DWORD flags = 0;
    COLORREF color_key = 0;
    if (GetLayeredWindowAttributes(hwnd, &color_key, &alpha, &flags) && (flags & LWA_ALPHA) != 0 &&
        alpha == 0) {
      return false;
    }
  }
  return true;
}

// Union of every top-level window above [root_window] that meets [interest].
// [covered] is owned by the caller. Windows behind [root_window] are ignored.
// Returns false when the Flutter root never appears, including when the walk
// stops early. The caller must then drop [covered].
bool CollectCoveringRegion(HWND root_window, HRGN interest, HRGN covered) {
  bool found_root = false;
  constexpr int kMaxWindows = 10000;
  int visited = 0;
  for (HWND above = GetTopWindow(GetDesktopWindow()); above != nullptr;
       above = GetWindow(above, GW_HWNDNEXT)) {
    if (above == root_window) {
      found_root = true;
      break;
    }
    if (++visited > kMaxWindows) {
      break;
    }
    if (!CanOcclude(above, root_window)) {
      continue;
    }

    HRGN shape = CreateWindowShapeRegion(above);
    if (shape == nullptr) {
      continue;
    }
    HRGN overlap = CreateEmptyRegion();
    const int overlap_kind =
        overlap == nullptr ? ERROR : CombineRgn(overlap, interest, shape, RGN_AND);
    if (overlap != nullptr) {
      DeleteObject(overlap);
    }
    if (overlap_kind == NULLREGION || overlap_kind == ERROR) {
      DeleteObject(shape);
      continue;
    }

    CombineRgn(covered, covered, shape, RGN_OR);
    DeleteObject(shape);
  }
  return found_root;
}

void ApplyRegion(HRGN bounds_region, HRGN other, std::vector<RECT>* out) {
  HRGN result = CreateEmptyRegion();
  if (result == nullptr) {
    return;
  }
  const int kind = CombineRgn(result, bounds_region, other, RGN_DIFF);
  if (kind != ERROR) {
    *out = RectanglesOfRegion(result);
  }
  DeleteObject(result);
}

}  // namespace

VisibleRegionBatch QueryVisibleRegions(HWND root_window,
                                       HWND view_window,
                                       double device_pixel_ratio,
                                       const std::vector<WidgetBoundsQuery>& widgets) {
  VisibleRegionBatch batch;
  batch.widgets.resize(widgets.size());
  if (root_window == nullptr || view_window == nullptr || !(device_pixel_ratio > 0) ||
      !std::isfinite(device_pixel_ratio)) {
    return batch;
  }

  const auto px = [&](double logical) {
    return static_cast<LONG>(std::lround(logical * device_pixel_ratio));
  };
  const RECT view_on_screen = ViewClientScreenRect(view_window);
  const RECT virtual_screen = VirtualScreenRect();

  HRGN interest = CreateEmptyRegion();
  if (interest == nullptr) {
    return batch;
  }

  std::vector<RECT> clipped(widgets.size());
  std::vector<bool> has_clipped(widgets.size(), false);

  for (size_t index = 0; index < widgets.size(); ++index) {
    const WidgetBoundsQuery& query = widgets[index];
    if (!std::isfinite(query.left) || !std::isfinite(query.top) || !std::isfinite(query.right) ||
        !std::isfinite(query.bottom)) {
      continue;
    }
    const RECT widget_on_screen = NormalizeRect(view_on_screen.left + px(query.left),
                                                view_on_screen.top + px(query.top),
                                                view_on_screen.left + px(query.right),
                                                view_on_screen.top + px(query.bottom));
    if (IsEmptyRect(widget_on_screen)) {
      continue;
    }

    batch.widgets[index].widget_screen = widget_on_screen;
    batch.widgets[index].has_widget = true;

    RECT visible_bounds{};
    if (!Intersect(widget_on_screen, view_on_screen, &visible_bounds) ||
        !Intersect(visible_bounds, virtual_screen, &visible_bounds)) {
      continue;
    }

    clipped[index] = visible_bounds;
    has_clipped[index] = true;
    HRGN piece = CreateRectRgnIndirect(&visible_bounds);
    if (piece != nullptr) {
      CombineRgn(interest, interest, piece, RGN_OR);
      DeleteObject(piece);
    }
  }

  HRGN covered = CreateEmptyRegion();
  if (covered == nullptr) {
    DeleteObject(interest);
    return batch;
  }

  bool any_clipped = false;
  for (bool is_clipped : has_clipped) {
    if (is_clipped) {
      any_clipped = true;
      break;
    }
  }

  // One walk covers every widget. Each widget later subtracts this same region.
  // If the Flutter root is missing, drop the covering region so windows behind
  // Flutter are not treated as occluders.
  const bool found_root = !any_clipped || CollectCoveringRegion(root_window, interest, covered);
  DeleteObject(interest);
  if (!found_root) {
    DeleteObject(covered);
    covered = CreateEmptyRegion();
  }
  if (covered == nullptr) {
    return batch;
  }

  for (size_t index = 0; index < batch.widgets.size(); ++index) {
    if (!has_clipped[index]) {
      continue;
    }
    HRGN bounds_region = CreateRectRgnIndirect(&clipped[index]);
    if (bounds_region == nullptr) {
      continue;
    }
    ApplyRegion(bounds_region, covered, &batch.widgets[index].rectangles);
    DeleteObject(bounds_region);
  }

  DeleteObject(covered);
  return batch;
}

}  // namespace vdi_visible_region
