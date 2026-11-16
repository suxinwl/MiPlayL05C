#include <windows.h>
#include <gdiplus.h>
#include "desktop_lyrics_renderer.h"
#include <array>
#include <cstdio>
#include <string>
#include <vector>

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  if (Gdiplus::GdiplusStartup(&token, &input, nullptr) != Gdiplus::Ok) return 3;
  {
    UINT count = 0, bytes = 0;
    Gdiplus::GetImageEncodersSize(&count, &bytes);
    std::vector<BYTE> buffer(bytes);
    auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
    Gdiplus::GetImageEncoders(count, bytes, codecs);
    CLSID png{};
    bool found = false;
    for (UINT i = 0; i < count; ++i) {
      if (wcscmp(codecs[i].MimeType, L"image/png") == 0) { png = codecs[i].Clsid; found = true; }
    }
    if (!found) return 4;
    std::array<int, 3> soft_halo_pixels{};
    for (int state = 0; state < 3; ++state) {
      const int width = 620, height = 118;
      Gdiplus::Bitmap output(width, height, PixelFormat32bppPARGB);
      Gdiplus::Graphics graphics(&output);
      desktop_lyrics::Render(graphics, width, height, 96,
          L"惬意的事 · 放慢脚步，享受片刻宁静", L"轻松一下 · 桌面歌词在浅色背景上仍然清晰",
          {state != 0, state == 2, true, -1});
      const std::wstring path = std::wstring(argv[1]) + (state == 0 ? L"\\idle.png" : state == 1 ? L"\\hover.png" : L"\\locked.png");
      if (output.Save(path.c_str(), &png) != Gdiplus::Ok) return 5;
      Gdiplus::Color blank;
      output.GetPixel(2, height / 2, &blank);
      if ((state == 1 && blank.GetA() < 150) ||
          (state != 1 && blank.GetA() != 0)) return 9;
      if (state != 1) {
        int outline = 0, colored = 0, soft_halo = 0;
        for (int y = 38; y < height - 8; ++y) for (int x = 38; x < width - 38; ++x) {
          Gdiplus::Color pixel;
          output.GetPixel(x, y, &pixel);
          const bool dark = pixel.GetR() < 65 && pixel.GetG() < 65 && pixel.GetB() < 65;
          if (pixel.GetA() > 100 && dark) ++outline;
          if (pixel.GetA() > 10 && pixel.GetA() < 160 && dark) ++soft_halo;
          if (pixel.GetA() > 180 && pixel.GetG() > pixel.GetR() + 20) ++colored;
        }
        soft_halo_pixels[state] = soft_halo;
        if (outline < 100 || colored < 100) return 6;
        if (soft_halo > 2000) return 13;
        if (state == 1) {
          Gdiplus::Color border;
          output.GetPixel(width / 2, 0, &border);
          if (border.GetA() < 180) return 14;
        }
        std::printf("state=%d dark_outline=%d soft_halo=%d colored_glyphs=%d\n",
                    state, outline, soft_halo, colored);
      }
    }
    if (desktop_lyrics::LyricFontSize(620) != 24 ||
        desktop_lyrics::HitButton(310, 20, 620, 1, true) != 3 ||
        desktop_lyrics::HitButton(235, 20, 620, 1, true) != -1) return 7;
    // Verify every icon hit rectangle stays within the same bounds at 200% DPI.
    for (int i = 0; i < 5; ++i) {
      const auto rect = desktop_lyrics::ButtonBounds(i, 1240, 2, false);
      if (desktop_lyrics::HitButton(rect.X + 10, rect.Y + 10, 1240, 2, false) != i) return 8;
    }
    // Exercise hover -> lock -> leave -> unlock on the SAME bitmap. This also
    // prevents a prior hover background from leaving alpha behind after redraw.
    const std::array<desktop_lyrics::Appearance, 4> appearances{{
        {true, false, true, -1}, {true, true, true, -1},
        {false, true, true, -1}, {false, false, true, -1}}};
    int transitions = 0;
    for (const UINT dpi : {96U, 120U, 144U, 192U}) {
      for (const int logical_width : {460, 620, 800}) {
        const int width = MulDiv(logical_width, dpi, 96);
        const int height = MulDiv(desktop_lyrics::kHeight, dpi, 96);
        Gdiplus::Bitmap output(width, height, PixelFormat32bppPARGB);
        Gdiplus::Graphics graphics(&output);
        for (const auto& appearance : appearances) {
          desktop_lyrics::Render(graphics, width, height, dpi,
              L"透明背景不得阻挡下方文件", L"锁定后仅解锁按钮接收点击", appearance);
          const auto interaction = desktop_lyrics::InteractiveSurface(appearance);
          const auto expected = !appearance.hovered
              ? desktop_lyrics::InteractionSurface::kNone
              : appearance.locked ? desktop_lyrics::InteractionSurface::kUnlockButton
                                  : desktop_lyrics::InteractionSurface::kBackground;
          if (interaction != expected) return 10;
          Gdiplus::Color blank, corner;
          output.GetPixel(2, height / 2, &blank);
          output.GetPixel(0, 0, &corner);
          if (corner.GetA() != 0 ||
              (expected == desktop_lyrics::InteractionSurface::kBackground
                   ? blank.GetA() < 150 : blank.GetA() != 0)) return 11;
          ++transitions;
        }
      }
      const int button_size = MulDiv(28, dpi, 96);
      Gdiplus::Bitmap button(button_size, button_size, PixelFormat32bppPARGB);
      Gdiplus::Graphics graphics(&button);
      for (const bool hovered : {false, true}) {
        desktop_lyrics::RenderUnlockButton(graphics, button_size, button_size, dpi, hovered);
        Gdiplus::Color corner, center;
        button.GetPixel(0, 0, &corner);
        button.GetPixel(button_size / 2, button_size / 2, &center);
        if (corner.GetA() != 0 || center.GetA() == 0) return 12;
      }
    }
    std::printf("Transparent input-state/DPI transitions=%d; unlock surface passed\n", transitions);
  }
  Gdiplus::GdiplusShutdown(token);
  std::puts("Native lyrics render, transparency and hit tests passed");
  return 0;
}
