#include "desktop_lyrics_renderer.h"

#include <algorithm>
#include <cmath>

namespace desktop_lyrics {
namespace {

void RoundedRectangle(Gdiplus::GraphicsPath& path, Gdiplus::RectF rect,
                       float radius) {
  const float diameter = radius * 2.0f;
  path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
  path.AddArc(rect.GetRight() - diameter, rect.Y, diameter, diameter, 270, 90);
  path.AddArc(rect.GetRight() - diameter, rect.GetBottom() - diameter,
               diameter, diameter, 0, 90);
  path.AddArc(rect.X, rect.GetBottom() - diameter, diameter, diameter, 90, 90);
  path.CloseFigure();
}

Gdiplus::Color DarkerColor(Gdiplus::Color color, float factor) {
  return Gdiplus::Color(
      235,
      static_cast<BYTE>(static_cast<float>(color.GetR()) * factor),
      static_cast<BYTE>(static_cast<float>(color.GetG()) * factor),
      static_cast<BYTE>(static_cast<float>(color.GetB()) * factor));
}

void DrawLabel(Gdiplus::Graphics& graphics, const std::wstring& text,
               Gdiplus::RectF rect, float size, float scale,
               Gdiplus::Color color, bool bold) {
  if (text.empty()) return;
  Gdiplus::FontFamily family(L"Microsoft YaHei UI");
  Gdiplus::StringFormat format;
  format.SetAlignment(Gdiplus::StringAlignmentCenter);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  Gdiplus::GraphicsPath glyphs;
  glyphs.AddString(text.c_str(), static_cast<int>(text.size()), &family,
                   bold ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular,
                   size, rect, &format);
  const auto saved = graphics.Save();
  const float clip_margin = 2.0f * scale;
  Gdiplus::RectF clip(rect.X - clip_margin, rect.Y - clip_margin,
                      rect.Width + clip_margin * 2,
                      rect.Height + clip_margin * 2);
  graphics.SetClip(clip);
  Gdiplus::Pen outline(DarkerColor(color, 0.72f), 1.0f * scale);
  outline.SetLineJoin(Gdiplus::LineJoinRound);
  graphics.DrawPath(&outline, &glyphs);
  Gdiplus::SolidBrush fill(color);
  graphics.FillPath(&fill, &glyphs);
  graphics.Restore(saved);
}

void IconPath(Gdiplus::GraphicsPath& path, int button, bool playing, bool locked) {
  if (button == 0 || button == 2) {
    const bool previous = button == 0;
    const Gdiplus::PointF points[] = {
      {previous ? 7.0f : 17.0f, 12.0f},
      {previous ? 17.0f : 7.0f, 5.0f},
      {previous ? 17.0f : 7.0f, 19.0f},
    };
    path.AddPolygon(points, 3);
    path.AddRectangle(Gdiplus::RectF(previous ? 4.0f : 18.0f, 5, 2, 14));
  } else if (button == 1) {
    if (playing) {
      path.AddRectangle(Gdiplus::RectF(6, 5, 4, 14));
      path.AddRectangle(Gdiplus::RectF(14, 5, 4, 14));
    } else {
      const Gdiplus::PointF points[] = {{7, 4}, {19, 12}, {7, 20}};
      path.AddPolygon(points, 3);
    }
  } else if (button == 3) {
    RoundedRectangle(path, Gdiplus::RectF(5, 11, 14, 10), 2);
    // Filled U-shaped shackle, open while unlocked (same affordance as Mac).
    Gdiplus::GraphicsPath shackle;
    shackle.AddArc(7.0f, locked ? 2.0f : 0.0f, 10.0f, 12.0f, 180.0f, 180.0f);
    if (!locked) shackle.AddLine(17, 6, 17, 8);
    Gdiplus::Pen stroke(Gdiplus::Color(255, 255, 255, 255), 2.3f);
    shackle.Widen(&stroke);
    path.AddPath(&shackle, false);
  } else if (button == 4) {
    path.AddLine(6, 6, 18, 18);
    path.StartFigure();
    path.AddLine(18, 6, 6, 18);
    Gdiplus::Pen stroke(Gdiplus::Color(255, 255, 255, 255), 2.5f);
    stroke.SetLineJoin(Gdiplus::LineJoinRound);
    path.Widen(&stroke);
  }
}

void DrawIcon(Gdiplus::Graphics& graphics, Gdiplus::RectF rect, int button,
              float scale, const Appearance& appearance) {
  if (appearance.locked) {
    // Give the only live control a visible hit surface; the surrounding
    // transparent corners and the entire lyric window remain click-through.
    Gdiplus::SolidBrush background(Gdiplus::Color(28, 27, 33, 38));
    graphics.FillEllipse(&background, rect);
  }
  if (appearance.hovered_button == button) {
    Gdiplus::SolidBrush hover(Gdiplus::Color(48, 187, 222, 211));
    graphics.FillEllipse(&hover, rect);
  }
  Gdiplus::GraphicsPath path;
  IconPath(path, button, appearance.playing, appearance.locked);
  Gdiplus::Matrix transform;
  const float icon_scale = 15.0f * scale / 24.0f;
  transform.Scale(icon_scale, icon_scale);
  transform.Translate(rect.X + (rect.Width - 15 * scale) / 2,
                       rect.Y + (rect.Height - 15 * scale) / 2,
                       Gdiplus::MatrixOrderAppend);
  path.Transform(&transform);
  Gdiplus::Pen shadow(Gdiplus::Color(210, 9, 15, 19), 2.0f * scale);
  shadow.SetLineJoin(Gdiplus::LineJoinRound);
  graphics.DrawPath(&shadow, &path);
  Gdiplus::SolidBrush color(appearance.locked
      ? Gdiplus::Color(255, 179, 219, 201)
      : Gdiplus::Color(255, 201, 209, 211));
  graphics.FillPath(&color, &path);
}
}  // namespace

InteractionSurface InteractiveSurface(const Appearance& appearance) {
  if (!appearance.hovered) return InteractionSurface::kNone;
  return appearance.locked ? InteractionSurface::kUnlockButton
                           : InteractionSurface::kBackground;
}

float LyricFontSize(float width) {
  width = std::clamp(width, static_cast<float>(kMinWidth), static_cast<float>(kMaxWidth));
  if (width < 520) return 18;
  if (width < 570) return 20;
  if (width < 620) return 22;
  if (width < 670) return 24;
  if (width < 720) return 26;
  if (width < 760) return 28;
  return 30;
}

float TranslationFontSize(float lyric_size) {
  return std::clamp(std::round(lyric_size * 0.56f), 13.0f, 18.0f);
}

Gdiplus::RectF ButtonBounds(int button, float width, float scale, bool locked) {
  if (button < 0 || button > 4 || (locked && button != 3)) return {};
  const float offsets[] = {0, 30, 60, 107, 143};
  const float left = locked ? (width - 28 * scale) / 2
                            : (width - 171 * scale) / 2 + offsets[button] * scale;
  return {left, 8 * scale, 28 * scale, 28 * scale};
}

int HitButton(float x, float y, float width, float scale, bool locked) {
  for (int button = 0; button < 5; ++button) {
    const auto rect = ButtonBounds(button, width, scale, locked);
    if (rect.Width > 0 && rect.Contains(x, y)) return button;
  }
  return -1;
}

void RenderUnlockButton(Gdiplus::Graphics& graphics, int width, int height,
                        UINT dpi, bool hovered) {
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
  graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
  graphics.SetCompositingMode(Gdiplus::CompositingModeSourceOver);
  DrawIcon(graphics, {0, 0, static_cast<float>(width), static_cast<float>(height)},
           3, static_cast<float>(dpi) / 96.0f,
           {true, true, false, hovered ? 3 : -1});
  graphics.Flush(Gdiplus::FlushIntentionSync);
}

void Render(Gdiplus::Graphics& graphics, int width, int height, UINT dpi,
            const std::wstring& lyric, const std::wstring& translation,
            const Appearance& appearance) {
  const float scale = static_cast<float>(dpi) / 96.0f;
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
  // Alpha must be exactly zero: even alpha=1 makes a layered window intercept
  // clicks on what looks like empty desktop space.
  graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
  graphics.SetCompositingMode(Gdiplus::CompositingModeSourceOver);
  if (InteractiveSurface(appearance) == InteractionSurface::kBackground) {
    Gdiplus::GraphicsPath fill_path;
    RoundedRectangle(fill_path,
                     {0, 0, static_cast<float>(width), static_cast<float>(height)},
                     18 * scale);
    Gdiplus::SolidBrush fill(Gdiplus::Color(246, 27, 33, 38));
    graphics.FillPath(&fill, &fill_path);
    Gdiplus::GraphicsPath border_path;
    RoundedRectangle(border_path,
                     {0.5f * scale, 0.5f * scale,
                      static_cast<float>(width) - scale,
                      static_cast<float>(height) - scale},
                     17.5f * scale);
    Gdiplus::Pen border(Gdiplus::Color(255, 20, 25, 29), 1.0f * scale);
    border.SetLineJoin(Gdiplus::LineJoinRound);
    graphics.DrawPath(&border, &border_path);
  }
  const float font = LyricFontSize(static_cast<float>(width) / scale);
  const auto primary = lyric.empty() ? std::wstring(L"oo music · 暂无歌词") : lyric;
  DrawLabel(graphics, primary,
             {46 * scale, 42 * scale, width - 92 * scale, 35 * scale},
             font * scale, scale, Gdiplus::Color(255, 179, 219, 201), true);
  DrawLabel(graphics, translation,
             {46 * scale, 80 * scale, width - 92 * scale, 25 * scale},
             TranslationFontSize(font) * scale, scale,
             Gdiplus::Color(255, 184, 194, 191), false);
  if (appearance.hovered) {
    for (int button = 0; button < 5; ++button) {
      const auto rect = ButtonBounds(button, static_cast<float>(width), scale, appearance.locked);
      if (rect.Width > 0) DrawIcon(graphics, rect, button, scale, appearance);
    }
    if (!appearance.locked) {
      Gdiplus::Pen separator(Gdiplus::Color(90, 195, 209, 205), scale);
      const float x = (width - 171 * scale) / 2 + 99 * scale;
      graphics.DrawLine(&separator, x, 14 * scale, x, 30 * scale);
      Gdiplus::Pen grip(Gdiplus::Color(185, 169, 195, 187), scale);
      for (int i = 0; i < 3; ++i) {
        const float right = width - (8 + i * 4) * scale;
        graphics.DrawLine(&grip, right, height - 8 * scale,
                           width - 8 * scale, height - (8 + i * 4) * scale);
      }
    }
  }
  graphics.Flush(Gdiplus::FlushIntentionSync);
}
}  // namespace desktop_lyrics
