#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  vdi_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "livekit_example/vdi_window",
          &flutter::StandardMethodCodec::GetInstance());
  vdi_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleVdiCall(call, std::move(result)); });
  return true;
}

void FlutterWindow::HandleVdiCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "getViewOrigin") {
    result->NotImplemented();
    return;
  }

  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    result->Error("no_window", "Flutter window is not available");
    return;
  }

  // Client origin, not the frame origin, so the title bar stays outside the
  // video rect. Physical pixels match SetWindowPos on a Per-Monitor V2 app.
  POINT origin = {0, 0};
  if (!ClientToScreen(hwnd, &origin)) {
    result->Error("origin", "ClientToScreen failed");
    return;
  }

  UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
  if (dpi == 0) {
    dpi = 96;
  }
  const double scale = static_cast<double>(dpi) / 96.0;

  flutter::EncodableMap value;
  value[flutter::EncodableValue("x")] =
      flutter::EncodableValue(static_cast<int32_t>(origin.x));
  value[flutter::EncodableValue("y")] =
      flutter::EncodableValue(static_cast<int32_t>(origin.y));
  value[flutter::EncodableValue("scale")] = flutter::EncodableValue(scale);
  value[flutter::EncodableValue("devicePixels")] =
      flutter::EncodableValue(true);
  result->Success(flutter::EncodableValue(value));
}

void FlutterWindow::OnDestroy() {
  if (vdi_channel_) {
    vdi_channel_->SetMethodCallHandler(nullptr);
    vdi_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
