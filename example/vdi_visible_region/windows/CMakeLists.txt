# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "vdi_visible_region")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "vdi_visible_region_plugin")

list(APPEND PLUGIN_SOURCES
  "vdi_visible_region_plugin.cpp"
  "vdi_visible_region_plugin.h"
  "visible_region.cpp"
  "visible_region.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/vdi_visible_region/vdi_visible_region_plugin_c_api.h"
  "vdi_visible_region_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin user32 gdi32 dwmapi)

set(vdi_visible_region_bundled_libraries
  ""
  PARENT_SCOPE
)
