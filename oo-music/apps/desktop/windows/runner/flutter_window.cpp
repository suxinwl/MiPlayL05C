#include "flutter_window.h"

#include <optional>
#include <iostream>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool accessibility_compatibility)
    : project_(project), accessibility_compatibility_(accessibility_compatibility) {}

FlutterWindow::~FlutterWindow() {
  OnDestroy();
}

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
  const HWND content_window = flutter_controller_->view()->GetNativeWindow();
  if (accessibility_compatibility_ && !accessibility_guard_.Install(content_window)) {
    // Do not silently run the unsafe mode if the requested guard failed.
    std::cerr << "Windows accessibility compatibility guard could not be installed.\n";
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  desktop_lyrics_ = std::make_unique<DesktopLyricsWindow>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(content_window);
  if (accessibility_compatibility_ && !accessibility_guard_.IsInstalled()) return false;
  const std::string version = FLUTTER_VERSION;
  const std::wstring title = L"oo music " + std::wstring(version.begin(), version.end()) +
      (accessibility_compatibility_ ? L" [Windows 兼容模式]" : L" [Windows 标准模式]");
  SetWindowTextW(GetHandle(), title.c_str());
  std::clog << "Windows startup: version=" << version << " pid=" << GetCurrentProcessId()
            << " accessibility_mode=" << (accessibility_compatibility_ ? "compatibility" : "normal")
            << " guard_installed=" << (accessibility_guard_.IsInstalled() ? "true" : "false") << '\n';

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  accessibility_guard_.Remove();
  desktop_lyrics_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Cover parent-window requests before Flutter/plugins get a chance to expose
  // the same AX tree. System title-bar objects and all ordinary input continue.
  if (windows_accessibility::ShouldSuppressObjectRequest(
          accessibility_compatibility_, message, lparam)) return 0;
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
    case WM_GETMINMAXINFO: {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = GetDpiForWindow(hwnd);
      RECT rect{0, 0, MulDiv(980, dpi ? dpi : 96, 96),
                       MulDiv(640, dpi ? dpi : 96, 96)};
      AdjustWindowRectExForDpi(&rect, static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_STYLE)),
                               FALSE, static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_EXSTYLE)),
                               dpi ? dpi : 96);
      limits->ptMinTrackSize = {rect.right - rect.left, rect.bottom - rect.top};
      return 0;
    }
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
