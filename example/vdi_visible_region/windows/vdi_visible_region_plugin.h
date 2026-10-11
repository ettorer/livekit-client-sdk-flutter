#ifndef FLUTTER_PLUGIN_VDI_VISIBLE_REGION_PLUGIN_H_
#define FLUTTER_PLUGIN_VDI_VISIBLE_REGION_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace vdi_visible_region {

class VdiVisibleRegionPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit VdiVisibleRegionPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~VdiVisibleRegionPlugin();

  VdiVisibleRegionPlugin(const VdiVisibleRegionPlugin&) = delete;
  VdiVisibleRegionPlugin& operator=(const VdiVisibleRegionPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  flutter::PluginRegistrarWindows* registrar_;
};

}  // namespace vdi_visible_region

#endif  // FLUTTER_PLUGIN_VDI_VISIBLE_REGION_PLUGIN_H_
