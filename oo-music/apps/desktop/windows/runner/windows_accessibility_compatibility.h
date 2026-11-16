#ifndef RUNNER_WINDOWS_ACCESSIBILITY_COMPATIBILITY_H_
#define RUNNER_WINDOWS_ACCESSIBILITY_COMPATIBILITY_H_

#include <windows.h>
#include <commctrl.h>

#include <string>
#include <vector>

namespace windows_accessibility {

// Temporary Windows test-build default, accepted by the user. An explicit
// normal-mode launch restores Flutter MSAA/UIA without changing global settings.
// These native-only flags must not be forwarded to the Dart entry point.
bool ResolveCompatibilityMode(std::vector<std::string>& arguments);
bool ShouldSuppressObjectRequest(bool compatibility, UINT message, LPARAM lparam);

// Install before parenting/showing the Flutter view or registering plugins.
// The guard owns only its subclass, never the HWND or the Flutter engine.
class CompatibilityGuard {
 public:
  CompatibilityGuard() = default;
  ~CompatibilityGuard();
  CompatibilityGuard(const CompatibilityGuard&) = delete;
  CompatibilityGuard& operator=(const CompatibilityGuard&) = delete;

  bool Install(HWND window);
  bool IsInstalled() const;
  void Remove();

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam, UINT_PTR subclass_id,
                                     DWORD_PTR reference_data);
  HWND window_ = nullptr;
};

}  // namespace windows_accessibility

#endif  // RUNNER_WINDOWS_ACCESSIBILITY_COMPATIBILITY_H_
