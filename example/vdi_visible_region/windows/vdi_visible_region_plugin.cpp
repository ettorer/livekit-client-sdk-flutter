#include "vdi_visible_region_plugin.h"

#include <flutter/standard_method_codec.h>

#include <cmath>
#include <memory>
#include <vector>

#include "visible_region.h"

namespace vdi_visible_region {
namespace {

const flutter::EncodableValue* Lookup(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &it->second;
}

bool ReadDouble(const flutter::EncodableMap& map, const char* key, double* out) {
  const auto* value = Lookup(map, key);
  if (value == nullptr) {
    return false;
  }
  if (const auto* number = std::get_if<double>(value)) {
    *out = *number;
    return true;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    *out = static_cast<double>(*number);
    return true;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    *out = static_cast<double>(*number);
    return true;
  }
  return false;
}

bool ReadInt64(const flutter::EncodableMap& map, const char* key, int64_t* out) {
  const auto* value = Lookup(map, key);
  if (value == nullptr) {
    return false;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    *out = *number;
    return true;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    *out = *number;
    return true;
  }
  if (const auto* number = std::get_if<double>(value)) {
    *out = static_cast<int64_t>(*number);
    return true;
  }
  return false;
}

flutter::EncodableMap RectMap(const RECT& rect) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("left")] = flutter::EncodableValue(static_cast<int32_t>(rect.left));
  map[flutter::EncodableValue("top")] = flutter::EncodableValue(static_cast<int32_t>(rect.top));
  map[flutter::EncodableValue("right")] = flutter::EncodableValue(static_cast<int32_t>(rect.right));
  map[flutter::EncodableValue("bottom")] =
      flutter::EncodableValue(static_cast<int32_t>(rect.bottom));
  return map;
}

}  // namespace

// static
void VdiVisibleRegionPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "livekit_example/vdi_visible_region",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<VdiVisibleRegionPlugin>(registrar);

  channel->SetMethodCallHandler([plugin_pointer = plugin.get()](const auto& call, auto result) {
    plugin_pointer->HandleMethodCall(call, std::move(result));
  });

  registrar->AddPlugin(std::move(plugin));
}

VdiVisibleRegionPlugin::VdiVisibleRegionPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

VdiVisibleRegionPlugin::~VdiVisibleRegionPlugin() {}

void VdiVisibleRegionPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() != "getVisibleRegions") {
    result->NotImplemented();
    return;
  }

  const auto* arguments = method_call.arguments();
  const auto* args = arguments == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(arguments);
  if (args == nullptr) {
    result->Error("bad_args", "Expected a map");
    return;
  }

  int64_t view_id = 0;
  double device_pixel_ratio = 0;
  if (!ReadInt64(*args, "viewId", &view_id) ||
      !ReadDouble(*args, "devicePixelRatio", &device_pixel_ratio) ||
      !(device_pixel_ratio > 0) || !std::isfinite(device_pixel_ratio)) {
    result->Error("bad_args", "viewId and a positive devicePixelRatio are required");
    return;
  }

  const auto* widget_value = Lookup(*args, "widgets");
  const auto* widget_list =
      widget_value == nullptr ? nullptr : std::get_if<flutter::EncodableList>(widget_value);
  if (widget_list == nullptr) {
    result->Error("bad_args", "widgets must be a list");
    return;
  }

  std::vector<WidgetBoundsQuery> widgets;
  widgets.reserve(widget_list->size());
  for (const auto& entry : *widget_list) {
    const auto* bounds = std::get_if<flutter::EncodableMap>(&entry);
    WidgetBoundsQuery query;
    if (bounds == nullptr || !ReadDouble(*bounds, "left", &query.left) ||
        !ReadDouble(*bounds, "top", &query.top) || !ReadDouble(*bounds, "right", &query.right) ||
        !ReadDouble(*bounds, "bottom", &query.bottom)) {
      result->Error("bad_args", "Each widget needs left, top, right, and bottom");
      return;
    }
    widgets.push_back(query);
  }

  const std::shared_ptr<flutter::FlutterView> view = registrar_->GetViewById(view_id);
  if (!view) {
    result->Error("no_view", "Flutter view is not available");
    return;
  }
  const HWND view_window = view->GetNativeWindow();
  const HWND root_window = view_window == nullptr ? nullptr : GetAncestor(view_window, GA_ROOT);
  if (view_window == nullptr || root_window == nullptr) {
    result->Error("no_view", "Flutter view window is not available");
    return;
  }

  const VisibleRegionBatch batch =
      QueryVisibleRegions(root_window, view_window, device_pixel_ratio, widgets);

  flutter::EncodableList encoded;
  encoded.reserve(batch.widgets.size());
  for (const WidgetVisibleRegion& widget : batch.widgets) {
    flutter::EncodableMap entry;
    if (widget.has_widget) {
      const flutter::EncodableMap bounds = RectMap(widget.widget_screen);
      entry.insert(bounds.begin(), bounds.end());
    }
    flutter::EncodableList rectangles;
    rectangles.reserve(widget.rectangles.size());
    for (const RECT& rect : widget.rectangles) {
      rectangles.push_back(flutter::EncodableValue(RectMap(rect)));
    }
    entry[flutter::EncodableValue("rectangles")] = flutter::EncodableValue(rectangles);
    encoded.push_back(flutter::EncodableValue(entry));
  }
  result->Success(flutter::EncodableValue(encoded));
}

}  // namespace vdi_visible_region
