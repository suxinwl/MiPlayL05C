#include "windows_accessibility_compatibility.h"

#include <oleacc.h>
#include <cstdio>

namespace {
constexpr wchar_t kTestClass[] = L"OoMusicAccessibilityCompatibilityTest";
constexpr LRESULT kForwarded = 12345;
constexpr UINT kInputMessage = WM_APP + 1;

struct TestWindow {
  HWND window = nullptr;
  int object_requests = 0;
  int input_messages = 0;

  ~TestWindow() { if (window) DestroyWindow(window); }

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* self = reinterpret_cast<TestWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      self = static_cast<TestWindow*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (self && message == WM_GETOBJECT) {
      ++self->object_requests;
      return kForwarded;
    }
    if (self && message == kInputMessage) {
      ++self->input_messages;
      return static_cast<LRESULT>(wparam);
    }
    if (self && message == WM_NCDESTROY) self->window = nullptr;
    return DefWindowProcW(window, message, wparam, lparam);
  }

  bool Create() {
    // These are hidden test windows in this process, never user application UI.
    window = CreateWindowExW(0, kTestClass, L"Hidden guard test", WS_POPUP,
        0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), this);
    return window != nullptr;
  }
};

bool Check(bool condition, const char* label) {
  if (!condition) std::fprintf(stderr, "FAILED: %s\n", label);
  return condition;
}

bool TestModes() {
  using windows_accessibility::ResolveCompatibilityMode;
  std::vector<std::string> arguments;
  if (!Check(ResolveCompatibilityMode(arguments), "default mode is compatibility")) return false;
  arguments = {"--windows-accessibility-normal", "dart-argument"};
  if (!Check(!ResolveCompatibilityMode(arguments) &&
      arguments == std::vector<std::string>{"dart-argument"}, "normal override and native flag removal")) return false;
  arguments = {"first", "--windows-accessibility-compat", "--windows-accessibility-compat", "last"};
  if (!Check(ResolveCompatibilityMode(arguments) &&
      arguments == std::vector<std::string>{"first", "last"}, "compatibility and duplicate removal")) return false;
  arguments = {"--windows-accessibility-normal", "--windows-accessibility-compat", "keep"};
  if (!Check(ResolveCompatibilityMode(arguments) &&
      arguments == std::vector<std::string>{"keep"}, "conflicting flags prefer compatibility")) return false;
  arguments = {"--windows-accessibility-normal=not-a-mode", ""};
  const auto original = arguments;
  return Check(ResolveCompatibilityMode(arguments) && arguments == original,
               "unrelated Dart arguments remain unchanged");
}

bool TestGuard() {
  using windows_accessibility::ShouldSuppressObjectRequest;
  using windows_accessibility::CompatibilityGuard;
  const LPARAM client_signed = static_cast<LPARAM>(OBJID_CLIENT);
  const LPARAM client_unsigned = static_cast<LPARAM>(static_cast<DWORD>(OBJID_CLIENT));
  const LPARAM uia_signed = static_cast<LPARAM>(-25);
  const LPARAM uia_unsigned = static_cast<LPARAM>(static_cast<DWORD>(-25));
  for (const LPARAM id : {client_signed, client_unsigned, uia_signed, uia_unsigned}) {
    if (!Check(ShouldSuppressObjectRequest(true, WM_GETOBJECT, id) &&
               !ShouldSuppressObjectRequest(false, WM_GETOBJECT, id) &&
               !ShouldSuppressObjectRequest(true, WM_MOUSEMOVE, id), "request type and sign extension")) return false;
  }
  if (!Check(!ShouldSuppressObjectRequest(true, WM_GETOBJECT, OBJID_WINDOW) &&
             !ShouldSuppressObjectRequest(true, WM_GETOBJECT, OBJID_CURSOR), "system objects unaffected")) return false;

  WNDCLASSW cls{};
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpfnWndProc = TestWindow::WindowProc;
  cls.lpszClassName = kTestClass;
  if (!Check(RegisterClassW(&cls) != 0, "register hidden test class")) return false;
  {
    TestWindow first, second;
    if (!Check(first.Create() && second.Create(), "create hidden test windows")) return false;
    CompatibilityGuard guard;
    if (!Check(!guard.Install(nullptr) && guard.Install(first.window) &&
               guard.Install(first.window) && guard.IsInstalled(), "installation verified and idempotent")) return false;
    for (int i = 0; i < 5000; ++i) {
      for (const LPARAM id : {client_signed, client_unsigned, uia_signed, uia_unsigned}) {
        if (!Check(SendMessageW(first.window, WM_GETOBJECT, 0, id) == 0,
                   "MSAA/UIA request suppressed before original proc")) return false;
      }
      if (!Check(SendMessageW(first.window, kInputMessage, 6789, 0) == 6789,
                 "normal input forwarded")) return false;
    }
    if (!Check(first.object_requests == 0 && first.input_messages == 5000,
               "20,000 native requests suppressed; input unaffected")) return false;
    if (!Check(SendMessageW(first.window, WM_GETOBJECT, 0, OBJID_WINDOW) == kForwarded &&
               first.object_requests == 1, "system title bar forwarded")) return false;
    if (!Check(!guard.Install(nullptr) && guard.IsInstalled(), "invalid replacement preserves guard")) return false;
    if (!Check(guard.Install(second.window) &&
               SendMessageW(first.window, WM_GETOBJECT, 0, client_signed) == kForwarded &&
               SendMessageW(second.window, WM_GETOBJECT, 0, client_signed) == 0,
               "rebind removes original subclass")) return false;
    guard.Remove();
    guard.Remove();
    if (!Check(!guard.IsInstalled() &&
               SendMessageW(second.window, WM_GETOBJECT, 0, client_signed) == kForwarded,
               "explicit removal restores normal path")) return false;
    {
      CompatibilityGuard temporary;
      if (!Check(temporary.Install(second.window), "temporary installation")) return false;
    }
    if (!Check(SendMessageW(second.window, WM_GETOBJECT, 0, client_signed) == kForwarded,
               "destructor restores normal path")) return false;
    if (!Check(guard.Install(first.window), "reinstall for destruction")) return false;
    DestroyWindow(first.window);
    if (!Check(!first.window && !guard.IsInstalled(), "window destruction clears guard handle")) return false;
  }
  return Check(UnregisterClassW(kTestClass, cls.hInstance) != FALSE, "test windows cleaned up");
}
}  // namespace

int main() {
  INITCOMMONCONTROLSEX controls{sizeof(INITCOMMONCONTROLSEX), ICC_WIN95_CLASSES};
  if (!InitCommonControlsEx(&controls)) return 2;
  if (!TestModes() || !TestGuard()) return 1;
  std::puts("Windows mode selection and actual Win32 guard tests passed (20,000 AX requests)");
  return 0;
}
