#include "windows_accessibility_compatibility.h"

#include <oleacc.h>
#include <algorithm>

namespace windows_accessibility {
namespace {
constexpr char kCompatibilityFlag[] = "--windows-accessibility-compat";
constexpr char kNormalFlag[] = "--windows-accessibility-normal";
constexpr LONG kUiaRootObjectId = -25;
constexpr UINT_PTR kSubclassId = 1;
}  // namespace

bool ResolveCompatibilityMode(std::vector<std::string>& arguments) {
  const bool compatibility_requested =
      std::find(arguments.begin(), arguments.end(), kCompatibilityFlag) != arguments.end();
  const bool normal_requested =
      std::find(arguments.begin(), arguments.end(), kNormalFlag) != arguments.end();
  arguments.erase(std::remove_if(arguments.begin(), arguments.end(), [](const auto& argument) {
    return argument == kCompatibilityFlag || argument == kNormalFlag;
  }), arguments.end());
  // If both flags are present, prefer the explicitly requested safer mode.
  return compatibility_requested || !normal_requested;
}

bool ShouldSuppressObjectRequest(bool compatibility, UINT message, LPARAM lparam) {
  if (!compatibility || message != WM_GETOBJECT) return false;
  // Windows only guarantees the lower 32 bits, regardless of sign extension.
  const auto object_id = static_cast<LONG>(static_cast<DWORD_PTR>(lparam));
  return object_id == OBJID_CLIENT || object_id == kUiaRootObjectId;
}

CompatibilityGuard::~CompatibilityGuard() {
  Remove();
}

bool CompatibilityGuard::Install(HWND window) {
  if (!window || !IsWindow(window)) return false;
  if (window_ == window && IsInstalled()) return true;
  Remove();
  if (!SetWindowSubclass(window, WindowProc, kSubclassId,
                         reinterpret_cast<DWORD_PTR>(this))) return false;
  window_ = window;
  if (IsInstalled()) return true;
  Remove();
  return false;
}

bool CompatibilityGuard::IsInstalled() const {
  DWORD_PTR reference_data = 0;
  return window_ && GetWindowSubclass(window_, WindowProc, kSubclassId, &reference_data) &&
      reference_data == reinterpret_cast<DWORD_PTR>(this);
}

void CompatibilityGuard::Remove() {
  if (window_) RemoveWindowSubclass(window_, WindowProc, kSubclassId);
  window_ = nullptr;
}

LRESULT CALLBACK CompatibilityGuard::WindowProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference_data) {
  if (ShouldSuppressObjectRequest(true, message, lparam)) return 0;
  if (message == WM_NCDESTROY) {
    auto* guard = reinterpret_cast<CompatibilityGuard*>(reference_data);
    RemoveWindowSubclass(window, WindowProc, subclass_id);
    guard->window_ = nullptr;
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

}  // namespace windows_accessibility
