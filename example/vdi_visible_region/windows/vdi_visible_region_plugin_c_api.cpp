#include "include/vdi_visible_region/vdi_visible_region_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "vdi_visible_region_plugin.h"

void VdiVisibleRegionPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  vdi_visible_region::VdiVisibleRegionPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
