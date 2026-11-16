#ifndef RUNNER_DESKTOP_LYRICS_WINDOW_H_
#define RUNNER_DESKTOP_LYRICS_WINDOW_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include <string>

// Transparent, non-activating Win32 lyrics. Owns both the channel and HWND;
// destroy before the Flutter engine to avoid callbacks into a dead messenger.
class DesktopLyricsWindow {
 public:
  DesktopLyricsWindow(flutter::BinaryMessenger* messenger, HWND main_window);
  ~DesktopLyricsWindow();
  DesktopLyricsWindow(const DesktopLyricsWindow&) = delete;
  DesktopLyricsWindow& operator=(const DesktopLyricsWindow&) = delete;

 private:
  bool Show();
  void Hide(bool notify);
  void Update(const flutter::EncodableValue* arguments);
  void Emit(const char* event);
  void Render();
  void Hover(bool hovered);
  void ToggleLock();
  void UpdateUnlockButton(bool visible);
  void KeepOnScreen();
  void UpdateTooltips();
  int HitButton(POINT point) const;
  int Scale(int value) const;
  static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM);
  static LRESULT CALLBACK UnlockWindowProc(HWND, UINT, WPARAM, LPARAM);
  LRESULT HandleMessage(UINT, WPARAM, LPARAM);
  LRESULT HandleUnlockMessage(UINT, WPARAM, LPARAM);

  HWND main_window_ = nullptr;
  HWND window_ = nullptr;
  HWND unlock_window_ = nullptr;
  HWND tooltip_ = nullptr;
  ULONG_PTR gdiplus_token_ = 0;
  UINT dpi_ = 96;
  bool hovered_ = false;
  bool locked_ = false;
  bool playing_ = false;
  bool moving_ = false;
  bool resizing_ = false;
  POINT drag_origin_{};
  RECT drag_frame_{};
  int pressed_button_ = -1;
  int hovered_button_ = -1;
  std::wstring lyric_;
  std::wstring translation_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
