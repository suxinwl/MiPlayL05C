#include "desktop_lyrics_window.h"

#include <windowsx.h>
#include <commctrl.h>
#include "desktop_lyrics_renderer.h"
#include <gdiplus.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>

namespace {
constexpr wchar_t kWindowClass[] = L"OoMusicDesktopLyrics";
constexpr wchar_t kUnlockWindowClass[] = L"OoMusicDesktopLyricsUnlock";
constexpr int kHeight = 118;
constexpr int kMinWidth = 460;
constexpr int kMaxWidth = 800;
constexpr UINT_PTR kHoverTimer = 1;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                        static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), length);
  return result;
}

void SetClickThrough(HWND window, bool enabled) {
  const LONG_PTR style = GetWindowLongPtrW(window, GWL_EXSTYLE);
  const LONG_PTR updated = enabled ? style | WS_EX_TRANSPARENT
                                   : style & ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
  if (style == updated) return;
  SetWindowLongPtrW(window, GWL_EXSTYLE, updated);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

template <typename Draw>
bool RenderLayeredWindow(HWND window, Draw draw) {
  RECT rect{};
  GetClientRect(window, &rect);
  const int width = rect.right;
  const int height = rect.bottom;
  if (width <= 0 || height <= 0) return false;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!bitmap || !dc) {
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
    ReleaseDC(nullptr, screen);
    return false;
  }
  HGDIOBJ old_bitmap = SelectObject(dc, bitmap);
  {
    Gdiplus::Bitmap surface(width, height, width * 4, PixelFormat32bppPARGB,
                            static_cast<BYTE*>(pixels));
    Gdiplus::Graphics graphics(&surface);
    draw(graphics, width, height);
  }
  POINT origin{0, 0};
  SIZE size{width, height};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  const bool rendered = UpdateLayeredWindow(window, screen, nullptr, &size, dc,
      &origin, 0, &blend, ULW_ALPHA) != FALSE;
  SelectObject(dc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
  return rendered;
}

}  // namespace

DesktopLyricsWindow::DesktopLyricsWindow(flutter::BinaryMessenger* messenger,
                                         HWND main_window)
    : main_window_(main_window) {
  Gdiplus::GdiplusStartupInput input;
  if (Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr) != Gdiplus::Ok) {
    gdiplus_token_ = 0;
  }
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "oo_music/desktop_lyrics", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "show") {
          Update(call.arguments());
          result->Success(flutter::EncodableValue(Show()));
        } else if (call.method_name() == "update") {
          Update(call.arguments());
          if (window_ && IsWindowVisible(window_)) Render();
          result->Success();
        } else if (call.method_name() == "hide") {
          Hide(false);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

DesktopLyricsWindow::~DesktopLyricsWindow() {
  channel_->SetMethodCallHandler(nullptr);
  channel_.reset();
  if (tooltip_) DestroyWindow(tooltip_);
  tooltip_ = nullptr;
  if (unlock_window_) DestroyWindow(unlock_window_);
  if (window_) DestroyWindow(window_);
  if (gdiplus_token_) Gdiplus::GdiplusShutdown(gdiplus_token_);
}

int DesktopLyricsWindow::Scale(int value) const {
  return MulDiv(value, static_cast<int>(dpi_), 96);
}

void DesktopLyricsWindow::Update(const flutter::EncodableValue* arguments) {
  if (!arguments) return;
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (!map) return;
  auto string_value = [map](const char* key) -> std::wstring {
    const auto entry = map->find(flutter::EncodableValue(key));
    if (entry == map->end()) return {};
    const auto* value = std::get_if<std::string>(&entry->second);
    return value ? Utf8ToWide(*value) : std::wstring();
  };
  lyric_ = string_value("lyric");
  translation_ = string_value("translation");
  const auto entry = map->find(flutter::EncodableValue("isPlaying"));
  if (entry != map->end()) {
    if (const auto* value = std::get_if<bool>(&entry->second)) {
      if (playing_ != *value) {
        playing_ = *value;
        UpdateTooltips();
      }
    }
  }
}

bool DesktopLyricsWindow::Show() {
  if (!gdiplus_token_) return false;
  if (!window_) {
    WNDCLASSW cls{};
    cls.lpfnWndProc = WindowProc;
    cls.hInstance = GetModuleHandle(nullptr);
    cls.hCursor = LoadCursor(nullptr, IDC_ARROW);
    cls.lpszClassName = kWindowClass;
    if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    dpi_ = GetDpiForWindow(main_window_);
    if (!dpi_) dpi_ = 96;
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (!GetMonitorInfo(MonitorFromWindow(main_window_, MONITOR_DEFAULTTONEAREST), &monitor)) {
      return false;
    }
    const int width = Scale(620);
    const int height = Scale(kHeight);
    window_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
                                 WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
                             kWindowClass, L"oo music - 桌面歌词", WS_POPUP,
                             monitor.rcWork.left +
                                 (monitor.rcWork.right - monitor.rcWork.left - width) / 2,
                             monitor.rcWork.bottom - height - Scale(32), width, height,
                             nullptr, nullptr, cls.hInstance, this);
    if (!window_) return false;
  }
  if (!unlock_window_) {
    WNDCLASSW cls{};
    cls.lpfnWndProc = UnlockWindowProc;
    cls.hInstance = GetModuleHandle(nullptr);
    cls.hCursor = LoadCursor(nullptr, IDC_HAND);
    cls.lpszClassName = kUnlockWindowClass;
    if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    // A separate, visible control avoids relying on HTTRANSPARENT, which only
    // searches windows on the same thread and cannot protect other apps below.
    unlock_window_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST |
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kUnlockWindowClass,
        L"oo music - 解锁桌面歌词", WS_POPUP, 0, 0, Scale(28), Scale(28),
        window_, nullptr, cls.hInstance, this);
    if (!unlock_window_) return false;
  }
  hovered_ = false;
  hovered_button_ = -1;
  UpdateTooltips();
  KeepOnScreen();
  Render();
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  SetTimer(window_, kHoverTimer, 100, nullptr);
  return true;
}

void DesktopLyricsWindow::Hide(bool notify) {
  moving_ = false;
  resizing_ = false;
  if (GetCapture() == window_ || GetCapture() == unlock_window_) ReleaseCapture();
  if (unlock_window_) ShowWindow(unlock_window_, SW_HIDE);
  if (window_) {
    KillTimer(window_, kHoverTimer);
    ShowWindow(window_, SW_HIDE);
  }
  hovered_ = false;
  hovered_button_ = -1;
  pressed_button_ = -1;
  if (notify) Emit("closed");
}

void DesktopLyricsWindow::Emit(const char* event) {
  if (channel_) channel_->InvokeMethod(event, nullptr);
}

void DesktopLyricsWindow::Hover(bool hovered) {
  if (hovered_ == hovered) return;
  hovered_ = hovered;
  if (!hovered) hovered_button_ = -1;
  Render();
}

void DesktopLyricsWindow::ToggleLock() {
  if (GetCapture() == window_ || GetCapture() == unlock_window_) ReleaseCapture();
  pressed_button_ = -1;
  moving_ = false;
  resizing_ = false;
  locked_ = !locked_;
  hovered_button_ = -1;
  UpdateTooltips();
  Render();
}

int DesktopLyricsWindow::HitButton(POINT point) const {
  if (!hovered_) return -1;
  RECT rect{};
  GetClientRect(window_, &rect);
  return desktop_lyrics::HitButton(static_cast<float>(point.x),
      static_cast<float>(point.y), static_cast<float>(rect.right),
      static_cast<float>(dpi_) / 96.0f, locked_);
}

void DesktopLyricsWindow::UpdateTooltips() {
  if (!window_) return;
  if (!tooltip_) {
    INITCOMMONCONTROLSEX controls{sizeof(INITCOMMONCONTROLSEX), ICC_WIN95_CLASSES};
    InitCommonControlsEx(&controls);
    tooltip_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE,
        TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX,
        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
        window_, nullptr, GetModuleHandle(nullptr), nullptr);
    if (!tooltip_) return;
  }
  RECT rect{};
  GetClientRect(window_, &rect);
  const wchar_t* labels[] = {L"上一首", playing_ ? L"暂停" : L"播放", L"下一首",
      locked_ ? L"解锁桌面歌词" : L"锁定桌面歌词", L"关闭桌面歌词"};
  for (int button = 0; button < 5; ++button) {
    const auto bounds = desktop_lyrics::ButtonBounds(button,
        static_cast<float>(rect.right), static_cast<float>(dpi_) / 96.0f, locked_);
    TOOLINFOW tool{};
    tool.cbSize = sizeof(TOOLINFOW);
    tool.uFlags = TTF_SUBCLASS;
    tool.hwnd = window_;
    tool.uId = static_cast<UINT_PTR>(button + 1);
    SendMessageW(tooltip_, TTM_DELTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
    if (unlock_window_) {
      tool.hwnd = unlock_window_;
      SendMessageW(tooltip_, TTM_DELTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
    }
    if (bounds.Width <= 0) continue;
    if (locked_) {
      tool.hwnd = unlock_window_;
      GetClientRect(unlock_window_, &tool.rect);
    } else {
      tool.hwnd = window_;
      tool.rect = {static_cast<LONG>(bounds.X), static_cast<LONG>(bounds.Y),
          static_cast<LONG>(bounds.GetRight()), static_cast<LONG>(bounds.GetBottom())};
    }
    tool.lpszText = const_cast<wchar_t*>(labels[button]);
    SendMessageW(tooltip_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
  }
}
void DesktopLyricsWindow::KeepOnScreen() {
  if (!window_) return;
  RECT rect{};
  GetWindowRect(window_, &rect);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  if (!GetMonitorInfo(MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST), &monitor)) return;
  const LONG width = rect.right - rect.left;
  const LONG height = rect.bottom - rect.top;
  const LONG x = std::clamp(rect.left, monitor.rcWork.left,
      std::max(monitor.rcWork.left, monitor.rcWork.right - width));
  const LONG y = std::clamp(rect.top, monitor.rcWork.top,
      std::max(monitor.rcWork.top, monitor.rcWork.bottom - height));
  SetWindowPos(window_, HWND_TOPMOST, x, y, 0, 0,
      SWP_NOSIZE | SWP_NOACTIVATE);
}

void DesktopLyricsWindow::Render() {
  if (!window_) return;
  const auto interaction = desktop_lyrics::InteractiveSurface(
      {hovered_, locked_, playing_, hovered_button_});
  const bool background = interaction == desktop_lyrics::InteractionSurface::kBackground;
  // Make the main surface pass through before removing its visible background.
  // In the opposite direction, do not enable input until that background exists.
  if (!background) SetClickThrough(window_, true);
  const bool rendered = RenderLayeredWindow(window_, [this](auto& graphics, int width, int height) {
    // Locked controls are rendered by the dedicated small unlock HWND, not by
    // the full click-through lyric surface.
    desktop_lyrics::Render(graphics, width, height, dpi_, lyric_, translation_,
        {hovered_ && !locked_, locked_, playing_, hovered_button_});
  });
  if (rendered && background) SetClickThrough(window_, false);
  UpdateUnlockButton(interaction == desktop_lyrics::InteractionSurface::kUnlockButton);
}

void DesktopLyricsWindow::UpdateUnlockButton(bool visible) {
  if (!unlock_window_) return;
  if (!visible || !IsWindowVisible(window_)) {
    ShowWindow(unlock_window_, SW_HIDE);
    return;
  }
  RECT frame{}, client{};
  GetWindowRect(window_, &frame);
  GetClientRect(window_, &client);
  const auto bounds = desktop_lyrics::ButtonBounds(3, static_cast<float>(client.right),
      static_cast<float>(dpi_) / 96.0f, true);
  SetWindowPos(unlock_window_, HWND_TOPMOST,
      frame.left + static_cast<int>(bounds.X), frame.top + static_cast<int>(bounds.Y),
      static_cast<int>(bounds.Width), static_cast<int>(bounds.Height), SWP_NOACTIVATE);
  const bool rendered = RenderLayeredWindow(unlock_window_, [this](auto& graphics, int width, int height) {
    desktop_lyrics::RenderUnlockButton(graphics, width, height, dpi_, hovered_button_ == 3);
  });
  if (rendered) ShowWindow(unlock_window_, SW_SHOWNOACTIVATE);
}

LRESULT CALLBACK DesktopLyricsWindow::WindowProc(HWND hwnd, UINT message,
                                                  WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<DesktopLyricsWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    self = static_cast<DesktopLyricsWindow*>(create->lpCreateParams);
    self->window_ = hwnd;
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(hwnd, message, wparam, lparam);
  return self->HandleMessage(message, wparam, lparam);
}

LRESULT CALLBACK DesktopLyricsWindow::UnlockWindowProc(HWND hwnd, UINT message,
                                                       WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<DesktopLyricsWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    self = static_cast<DesktopLyricsWindow*>(create->lpCreateParams);
    self->unlock_window_ = hwnd;
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProcW(hwnd, message, wparam, lparam);
  return self->HandleUnlockMessage(message, wparam, lparam);
}

LRESULT DesktopLyricsWindow::HandleUnlockMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_ERASEBKGND: return 1;
    case WM_NCHITTEST: return HTCLIENT;
    case WM_CLOSE: Hide(true); return 0;
    case WM_SIZE: UpdateTooltips(); return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      BeginPaint(unlock_window_, &paint);
      EndPaint(unlock_window_, &paint);
      return 0;
    }
    case WM_MOUSEMOVE:
      Hover(true);
      if (hovered_button_ != 3) {
        hovered_button_ = 3;
        Render();
      }
      return 0;
    case WM_SETCURSOR:
      SetCursor(LoadCursor(nullptr, IDC_HAND));
      return TRUE;
    case WM_LBUTTONDOWN:
      pressed_button_ = 3;
      SetCapture(unlock_window_);
      return 0;
    case WM_LBUTTONUP: {
      const bool pressed = pressed_button_ == 3;
      pressed_button_ = -1;
      if (GetCapture() == unlock_window_) ReleaseCapture();
      RECT rect{};
      GetClientRect(unlock_window_, &rect);
      const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (pressed && locked_ && PtInRect(&rect, point)) ToggleLock();
      return 0;
    }
    case WM_CAPTURECHANGED:
      pressed_button_ = -1;
      return 0;
    case WM_NCDESTROY: {
      const HWND hwnd = unlock_window_;
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
      unlock_window_ = nullptr;
      return DefWindowProcW(hwnd, message, wparam, lparam);
    }
  }
  return DefWindowProcW(unlock_window_, message, wparam, lparam);
}

LRESULT DesktopLyricsWindow::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_ERASEBKGND: return 1;
    case WM_CLOSE: Hide(true); return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      BeginPaint(window_, &paint);
      EndPaint(window_, &paint);
      Render();
      return 0;
    }
    case WM_TIMER: {
      if (wparam != kHoverTimer) break;
      POINT point{};
      RECT rect{};
      if (!GetCursorPos(&point)) return 0;
      GetWindowRect(window_, &rect);
      // Poll independently of mouse messages: a pass-through layered window
      // intentionally receives none, but must still reveal its controls.
      const bool captured = GetCapture() == window_ || GetCapture() == unlock_window_;
      Hover(captured || PtInRect(&rect, point) != FALSE);
      ScreenToClient(window_, &point);
      const int button = HitButton(point);
      if (hovered_button_ != button) {
        hovered_button_ = button;
        Render();
      }
      return 0;
    }
    case WM_MOUSEMOVE: {
      Hover(true);
      const POINT cursor{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const int hover = HitButton(cursor);
      if (hovered_button_ != hover) {
        hovered_button_ = hover;
        Render();
      }
      if (moving_ || resizing_) {
        POINT point{};
        GetCursorPos(&point);
        if (moving_) {
          SetWindowPos(window_, HWND_TOPMOST,
              drag_frame_.left + point.x - drag_origin_.x,
              drag_frame_.top + point.y - drag_origin_.y, 0, 0,
              SWP_NOSIZE | SWP_NOACTIVATE);
        } else {
          const LONG width = std::clamp<LONG>(
              drag_frame_.right - drag_frame_.left + point.x - drag_origin_.x,
              Scale(kMinWidth), Scale(kMaxWidth));
          SetWindowPos(window_, HWND_TOPMOST, 0, 0, width, Scale(kHeight),
              SWP_NOMOVE | SWP_NOACTIVATE);
        }
      }
      return 0;
    }
    case WM_NCHITTEST:
      // WS_EX_TRANSPARENT handles cross-process pass-through; this is only a
      // defensive answer for direct/same-thread hit-test queries.
      return hovered_ && !locked_ ? HTCLIENT : HTTRANSPARENT;
    case WM_SETCURSOR: {
      POINT point{};
      RECT rect{};
      GetCursorPos(&point);
      ScreenToClient(window_, &point);
      GetClientRect(window_, &rect);
      const bool resize = !locked_ && point.x >= rect.right - Scale(18)
          && point.y >= rect.bottom - Scale(18);
      SetCursor(LoadCursor(nullptr, resize ? IDC_SIZEWE : IDC_ARROW));
      return TRUE;
    }
    case WM_LBUTTONDOWN: {
      if (!hovered_ || locked_) return 0;
      const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      pressed_button_ = HitButton(point);
      if (pressed_button_ >= 0) {
        SetCapture(window_);
      } else if (!locked_) {
        RECT rect{};
        GetClientRect(window_, &rect);
        resizing_ = point.x >= rect.right - Scale(18)
            && point.y >= rect.bottom - Scale(18);
        moving_ = !resizing_;
        GetCursorPos(&drag_origin_);
        GetWindowRect(window_, &drag_frame_);
        SetCapture(window_);
      }
      return 0;
    }
    case WM_LBUTTONUP: {
      const int button = pressed_button_;
      pressed_button_ = -1;
      const bool was_dragging = moving_ || resizing_;
      moving_ = false;
      resizing_ = false;
      ReleaseCapture();
      if (was_dragging) {
        KeepOnScreen();
        return 0;
      }
      const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (button < 0 || button != HitButton(point)) return 0;
      switch (button) {
        case 0: Emit("previous"); break;
        case 1: Emit("togglePlayback"); break;
        case 2: Emit("next"); break;
        case 3: ToggleLock(); break;
        case 4: Hide(true); break;
      }
      return 0;
    }
    case WM_CAPTURECHANGED:
      pressed_button_ = -1;
      moving_ = false;
      resizing_ = false;
      return 0;
    case WM_GETMINMAXINFO: {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize = {Scale(kMinWidth), Scale(kHeight)};
      limits->ptMaxTrackSize = {Scale(kMaxWidth), Scale(kHeight)};
      return 0;
    }
    case WM_SIZING: {
      auto* rect = reinterpret_cast<RECT*>(lparam);
      rect->right = rect->left + std::clamp<LONG>(rect->right - rect->left,
                                           Scale(kMinWidth), Scale(kMaxWidth));
      rect->bottom = rect->top + Scale(kHeight);
      return TRUE;
    }
    case WM_SIZE: UpdateTooltips(); Render(); return 0;
    case WM_DPICHANGED: {
      dpi_ = HIWORD(wparam);
      const auto* rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(window_, HWND_TOPMOST, rect->left, rect->top,
                   std::clamp<LONG>(rect->right - rect->left, Scale(kMinWidth), Scale(kMaxWidth)),
                   Scale(kHeight), SWP_NOACTIVATE);
      Render();
      return 0;
    }
    case WM_DISPLAYCHANGE: KeepOnScreen(); return 0;
    case WM_NCDESTROY: {
      HWND hwnd = window_;
      KillTimer(hwnd, kHoverTimer);
      SetWindowLongPtr(hwnd, GWLP_USERDATA, 0);
      window_ = nullptr;
      return DefWindowProc(hwnd, message, wparam, lparam);
    }
  }
  return DefWindowProc(window_, message, wparam, lparam);
}
