#ifndef RUNNER_DESKTOP_LYRICS_RENDERER_H_
#define RUNNER_DESKTOP_LYRICS_RENDERER_H_

#include <windows.h>
#include <gdiplus.h>

#include <string>

namespace desktop_lyrics {
constexpr int kHeight = 118;
constexpr int kMinWidth = 460;
constexpr int kMaxWidth = 800;

struct Appearance {
  bool hovered = false;
  bool locked = false;
  bool playing = false;
  int hovered_button = -1;
};

// A locked lyric surface is never an input target. Its visible unlock button
// uses a separate small HWND so clicks also pass to other processes below it.
enum class InteractionSurface { kNone, kBackground, kUnlockButton };
InteractionSurface InteractiveSurface(const Appearance& appearance);

// Logical dimensions and font steps match macOS MainFlutterWindow.swift.
float LyricFontSize(float width);
float TranslationFontSize(float lyric_size);
Gdiplus::RectF ButtonBounds(int button, float width, float scale, bool locked);
int HitButton(float x, float y, float width, float scale, bool locked);
void RenderUnlockButton(Gdiplus::Graphics& graphics, int width, int height,
                        UINT dpi, bool hovered);
void Render(Gdiplus::Graphics& graphics, int width, int height, UINT dpi,
            const std::wstring& lyric, const std::wstring& translation,
            const Appearance& appearance);
}  // namespace desktop_lyrics

#endif
