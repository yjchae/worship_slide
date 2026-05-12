#include "presentation_channel.h"

#include <algorithm>
#include <stdexcept>
#include <string>

#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>

PresentationChannel* PresentationChannel::s_ = nullptr;

// ── helpers ───────────────────────────────────────────────────────────────────

COLORREF PresentationChannel::HexRgb(const std::string& hex, COLORREF def) {
  if (hex.size() != 7 || hex[0] != '#') return def;
  try {
    int r = std::stoi(hex.substr(1, 2), nullptr, 16);
    int g = std::stoi(hex.substr(3, 2), nullptr, 16);
    int b = std::stoi(hex.substr(5, 2), nullptr, 16);
    return RGB(r, g, b);
  } catch (...) { return def; }
}

std::wstring PresentationChannel::W(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (n <= 0) return {};
  std::wstring out(n - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, out.data(), n);
  return out;
}

UINT PresentationChannel::HFlag(int h) {
  if (h == 0) return DT_LEFT;
  if (h == 2) return DT_RIGHT;
  return DT_CENTER;
}

// ── lifecycle ─────────────────────────────────────────────────────────────────

PresentationChannel::PresentationChannel(HWND main_hwnd)
    : main_hwnd_(main_hwnd) {
  s_ = this;
  Register();
}

PresentationChannel::~PresentationChannel() {
  if (hwnd_) { DestroyWindow(hwnd_); hwnd_ = nullptr; }
  s_ = nullptr;
}

void PresentationChannel::Register() {
  WNDCLASSEXW wc = {};
  wc.cbSize        = sizeof(wc);
  wc.lpfnWndProc   = WndProc;
  wc.hInstance     = GetModuleHandle(nullptr);
  wc.hCursor       = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kClass;
  RegisterClassExW(&wc);
}

// ── channel setup ─────────────────────────────────────────────────────────────

void PresentationChannel::Setup(flutter::FlutterEngine* engine) {
  auto* codec = &flutter::StandardMethodCodec::GetInstance();
  auto* msg   = engine->messenger();

  cmd_ = std::make_unique<Channel>(msg, "worship_slides/presentation", codec);
  cmd_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        const auto* data = std::get_if<flutter::EncodableMap>(call.arguments());

        if (call.method_name() == "openWindow") {
          OpenWindow();
          if (data) { Apply(*data); InvalidateRect(hwnd_, nullptr, TRUE); }
        } else if (call.method_name() == "updatePage") {
          if (data && hwnd_) {
            Apply(*data);
            InvalidateRect(hwnd_, nullptr, TRUE);
          }
        } else if (call.method_name() == "closeWindow") {
          CloseWindow();
        } else {
          result->NotImplemented();
          return;
        }
        result->Success();
      });

  main_ = std::make_unique<Channel>(msg, "worship_slides/presentation_main", codec);
}

// ── window management ─────────────────────────────────────────────────────────

void PresentationChannel::OpenWindow() {
  if (hwnd_) { SetForegroundWindow(hwnd_); return; }

  // Place on secondary monitor when available, else center on primary.
  struct MonInfo { HMONITOR primary; HMONITOR second; };
  MonInfo mi = { MonitorFromWindow(main_hwnd_, MONITOR_DEFAULTTOPRIMARY), nullptr };
  EnumDisplayMonitors(nullptr, nullptr,
    [](HMONITOR mon, HDC, LPRECT, LPARAM lp) -> BOOL {
      auto* m = reinterpret_cast<MonInfo*>(lp);
      if (mon != m->primary) { m->second = mon; return FALSE; }
      return TRUE;
    }, reinterpret_cast<LPARAM>(&mi));

  RECT wr;
  DWORD exStyle;
  if (mi.second) {
    MONITORINFO info = { sizeof(info) };
    GetMonitorInfo(mi.second, &info);
    wr = info.rcMonitor;  // full screen including taskbar
    exStyle = WS_EX_TOPMOST;
  } else {
    MONITORINFO info = { sizeof(info) };
    GetMonitorInfo(mi.primary, &info);
    int sw = info.rcWork.right - info.rcWork.left;
    int sh = info.rcWork.bottom - info.rcWork.top;
    wr.left   = info.rcWork.left + (sw - 1280) / 2;
    wr.top    = info.rcWork.top  + (sh - 720)  / 2;
    wr.right  = wr.left + 1280;
    wr.bottom = wr.top  + 720;
    exStyle = 0;
  }

  DWORD style = mi.second ? WS_POPUP : WS_OVERLAPPEDWINDOW;

  hwnd_ = CreateWindowExW(
      exStyle, kClass, L"발표 화면", style,
      wr.left, wr.top,
      wr.right - wr.left, wr.bottom - wr.top,
      nullptr, nullptr, GetModuleHandle(nullptr), nullptr);

  ShowWindow(hwnd_, SW_SHOW);
  UpdateWindow(hwnd_);
}

void PresentationChannel::CloseWindow() {
  if (hwnd_) { DestroyWindow(hwnd_); hwnd_ = nullptr; }
}

// ── data parsing ──────────────────────────────────────────────────────────────

namespace {
  template<class T>
  const T* Get(const flutter::EncodableMap& m, const char* key) {
    auto it = m.find(flutter::EncodableValue(key));
    if (it == m.end()) return nullptr;
    return std::get_if<T>(&it->second);
  }
  std::string GetStr(const flutter::EncodableMap& m, const char* k, const std::string& d = "") {
    const std::string* v = Get<std::string>(m, k); return v ? *v : d;
  }
  bool GetBool(const flutter::EncodableMap& m, const char* k, bool d = false) {
    const bool* v = Get<bool>(m, k); return v ? *v : d;
  }
  double GetDbl(const flutter::EncodableMap& m, const char* k, double d = 0.0) {
    if (const double* v = Get<double>(m, k)) return *v;
    if (const int* v    = Get<int>(m, k))    return static_cast<double>(*v);
    return d;
  }
  int VOf(const std::string& s) {
    if (s == "top")    return 0;
    if (s == "bottom") return 2;
    return 1;
  }
  int HOf(const std::string& s) {
    if (s == "left")  return 0;
    if (s == "right") return 2;
    return 1;
  }
}

void PresentationChannel::Apply(const flutter::EncodableMap& data) {
  const bool isBible = GetBool(data, "is_bible");

  slide_.main    = W(GetStr(data, "main_text"));
  slide_.english = W(GetStr(data, "english_text"));
  const std::string* ttl = Get<std::string>(data, "title");
  slide_.title   = ttl ? W(*ttl) : std::wstring{};
  slide_.isBible = isBible;

  const flutter::EncodableMap* style = nullptr;
  auto it = data.find(flutter::EncodableValue("style"));
  if (it != data.end())
    style = std::get_if<flutter::EncodableMap>(&it->second);

  if (!style) return;
  const flutter::EncodableMap& s = *style;

  slide_.bg = HexRgb(GetStr(s, "background_color", "#1b1b1b"), RGB(27,27,27));

  if (isBible) {
    slide_.mainSz  = GetDbl(s, "bible_font_size", 30.0);
    slide_.txt     = HexRgb(GetStr(s, "bible_text_color", "#ffffff"), RGB(255,255,255));
    slide_.boxTop  = GetDbl(s, "bible_text_box_top", 0.6);
    slide_.vAlign  = VOf(GetStr(s, "bible_text_position", "middle"));
    slide_.hAlign  = HOf(GetStr(s, "bible_text_align", "center"));
    slide_.showTitle  = GetBool(s, "show_bible_title");
    slide_.ttlSz      = GetDbl(s, "bible_title_font_size", 14.0);
    slide_.ttlClr     = HexRgb(GetStr(s, "bible_title_text_color", "#ffffff"), RGB(255,255,255));
    slide_.ttlH       = HOf(GetStr(s, "bible_title_horizontal_position", "right"));
    slide_.ttlV       = VOf(GetStr(s, "bible_title_vertical_position", "bottom"));
  } else {
    slide_.mainSz  = GetDbl(s, "font_size", 30.0);
    slide_.txt     = HexRgb(GetStr(s, "text_color", "#ffffff"), RGB(255,255,255));
    slide_.boxTop  = GetDbl(s, "text_box_top", 0.6);
    slide_.vAlign  = VOf(GetStr(s, "text_position", "middle"));
    slide_.hAlign  = HOf(GetStr(s, "lyrics_text_align", "center"));
    slide_.showTitle  = GetBool(s, "show_song_title");
    slide_.ttlSz      = GetDbl(s, "title_font_size", 14.0);
    slide_.ttlClr     = HexRgb(GetStr(s, "title_text_color", "#ffffff"), RGB(255,255,255));
    slide_.ttlH       = HOf(GetStr(s, "title_horizontal_position", "right"));
    slide_.ttlV       = VOf(GetStr(s, "title_vertical_position", "bottom"));
  }

  slide_.inclEng = GetBool(s, "include_english_lyrics", true);
  slide_.eng     = HexRgb(GetStr(s, "english_text_color", "#fff176"), RGB(255,241,118));
  double baseSz  = GetDbl(s, "font_size", 30.0);
  slide_.engSz   = baseSz * 0.8;
}

// ── rendering ─────────────────────────────────────────────────────────────────

void PresentationChannel::Paint(HDC hdc, RECT cli) const {
  const int W = cli.right, H = cli.bottom;

  // Background
  HBRUSH bg = CreateSolidBrush(slide_.bg);
  FillRect(hdc, &cli, bg);
  DeleteObject(bg);

  SetBkMode(hdc, TRANSPARENT);

  // Font factory: size in "slide points", height scaled to window height
  // fontScale = H / (7.5 * 72) = H / 540  (matches Flutter _PreviewBox)
  auto makeFont = [&](double ptSize, bool bold) -> HFONT {
    int h = -(int)(ptSize * H / 540.0 + 0.5);
    return CreateFontW(h, 0, 0, 0,
      bold ? FW_BOLD : FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"\xB9DE\xC740 \xACE0\xB515"); // 맑은 고딕
  };

  // Body box (matches macOS HTML: left=5%, right=95%)
  double boxH    = 7.5 - slide_.boxTop - 1.5;  // 1.5 = lyricsBoxBottom
  int bodyLeft   = (int)(0.05 * W);
  int bodyRight  = (int)(0.95 * W);
  int bodyTop    = (int)(slide_.boxTop / 7.5 * H);
  int bodyBottom = (int)((slide_.boxTop + boxH) / 7.5 * H);
  int bodyBoxH   = bodyBottom - bodyTop;

  UINT hf = HFlag(slide_.hAlign);
  UINT calcFlags = hf | DT_WORDBREAK | DT_NOPREFIX | DT_CALCRECT;
  UINT drawFlags = hf | DT_WORDBREAK | DT_NOPREFIX;

  // Measure main text
  HFONT mainFont = makeFont(slide_.mainSz, true);
  HFONT old      = (HFONT)SelectObject(hdc, mainFont);

  RECT mainCalc = { bodyLeft, bodyTop, bodyRight, bodyTop + bodyBoxH };
  if (!slide_.main.empty())
    DrawTextW(hdc, slide_.main.c_str(), -1, &mainCalc, calcFlags);
  int mainH = slide_.main.empty() ? 0 : mainCalc.bottom - mainCalc.top;

  // Measure english text
  int engGap = 0, engH = 0;
  HFONT engFont = nullptr;
  RECT  engCalc = {};
  if (slide_.inclEng && !slide_.english.empty()) {
    engGap  = (int)(slide_.mainSz * H / 540.0 * 0.4 + 0.5);
    engFont = makeFont(slide_.engSz, true);
    SelectObject(hdc, engFont);
    engCalc = { bodyLeft, bodyTop, bodyRight, bodyTop + bodyBoxH };
    DrawTextW(hdc, slide_.english.c_str(), -1, &engCalc, calcFlags);
    engH = engCalc.bottom - engCalc.top;
  }

  int totalH = mainH + (engFont ? engGap + engH : 0);

  // Vertical offset
  int startY;
  switch (slide_.vAlign) {
    case 0: startY = bodyTop; break;
    case 2: startY = bodyBottom - totalH; break;
    default: startY = bodyTop + (bodyBoxH - totalH) / 2; break;
  }
  startY = std::max(bodyTop, startY);

  // Draw main text
  SelectObject(hdc, mainFont);
  SetTextColor(hdc, slide_.txt);
  if (!slide_.main.empty()) {
    RECT r = { bodyLeft, startY, bodyRight, startY + mainH + bodyBoxH };
    DrawTextW(hdc, slide_.main.c_str(), -1, &r, drawFlags);
  }

  // Draw english text
  if (engFont) {
    SelectObject(hdc, engFont);
    SetTextColor(hdc, slide_.eng);
    int ey = startY + mainH + engGap;
    RECT r = { bodyLeft, ey, bodyRight, ey + engH + bodyBoxH };
    DrawTextW(hdc, slide_.english.c_str(), -1, &r, drawFlags);
    SelectObject(hdc, old);
    DeleteObject(engFont);
  } else {
    SelectObject(hdc, old);
  }
  DeleteObject(mainFont);

  // Title
  if (slide_.showTitle && !slide_.title.empty()) {
    double ttlBoxH = 0.55 / 7.5 * H;
    double ttlPad  = 0.2  / 7.5 * H;

    double ty;
    switch (slide_.ttlV) {
      case 0: ty = ttlPad; break;
      case 1: ty = (H - ttlBoxH) / 2; break;
      default: ty = H - ttlPad - ttlBoxH; break;
    }

    RECT ttlBox;
    UINT tf;
    int pad = (int)(W * 0.015);
    switch (slide_.ttlH) {
      case 0: // left
        ttlBox = { pad, (int)ty, W - pad, (int)(ty + ttlBoxH) };
        tf = DT_LEFT; break;
      case 1: { // center
        int cw = (int)(W * 10.0 / 13.333);
        ttlBox = { (W - cw) / 2, (int)ty, (W + cw) / 2, (int)(ty + ttlBoxH) };
        tf = DT_CENTER; break;
      }
      default: // right
        ttlBox = { pad, (int)ty, W - pad, (int)(ty + ttlBoxH) };
        tf = DT_RIGHT; break;
    }

    HFONT ttlFont = makeFont(slide_.ttlSz, false);
    old = (HFONT)SelectObject(hdc, ttlFont);
    SetTextColor(hdc, slide_.ttlClr);
    DrawTextW(hdc, slide_.title.c_str(), -1, &ttlBox,
              tf | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
    SelectObject(hdc, old);
    DeleteObject(ttlFont);
  }
}

// ── window procedure ──────────────────────────────────────────────────────────

LRESULT CALLBACK PresentationChannel::WndProc(
    HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      RECT cli; GetClientRect(hwnd, &cli);

      // Double-buffer to avoid flicker
      HDC mdc  = CreateCompatibleDC(hdc);
      HBITMAP bmp = CreateCompatibleBitmap(hdc, cli.right, cli.bottom);
      HBITMAP old = (HBITMAP)SelectObject(mdc, bmp);

      if (s_) s_->Paint(mdc, cli);

      BitBlt(hdc, 0, 0, cli.right, cli.bottom, mdc, 0, 0, SRCCOPY);
      SelectObject(mdc, old);
      DeleteObject(bmp);
      DeleteDC(mdc);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;  // handled in WM_PAINT

    case WM_KEYDOWN:
      if (wp == VK_ESCAPE) {
        SendMessage(hwnd, WM_CLOSE, 0, 0);
        return 0;
      }
      break;

    case WM_CLOSE:
      if (s_) {
        if (s_->main_) s_->main_->InvokeMethod("presentationClosed", nullptr);
        s_->hwnd_ = nullptr;
      }
      DestroyWindow(hwnd);
      return 0;

    case WM_SIZE:
      InvalidateRect(hwnd, nullptr, TRUE);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
