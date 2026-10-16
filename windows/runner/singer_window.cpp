#include "singer_window.h"

#include <algorithm>
#include <cwchar>
#include <memory>
#include <utility>

// gdiplus.h는 min/max를 한정자 없이 쓰는데 이 타깃은 NOMINMAX로 빌드되므로
// std 버전을 먼저 끌어와야 컴파일된다 (presentation_channel.cpp 와 같다).
using std::max;
using std::min;

#include <objidl.h>
#include <gdiplus.h>

// 소스 인코딩에 휘둘리지 않게 한글 문자열은 코드 포인트로 적는다.
namespace {
constexpr wchar_t kTitle[]       = L"\xC2F1\xC5B4 \xD654\xBA74";        // 싱어 화면
constexpr wchar_t kNext[]        = L"\xB2E4\xC74C";                     // 다음
constexpr wchar_t kBlank[]       = L"\xBE48 \xD654\xBA74";              // 빈 화면
constexpr wchar_t kLastPage[]    = L"\xB9C8\xC9C0\xB9C9 \xD398\xC774\xC9C0";  // 마지막 페이지
constexpr wchar_t kBlackout[]    = L"\xAD00\xAC1D \xD654\xBA74 \xAEBC\xC9D0";  // 관객 화면 꺼짐
constexpr wchar_t kFontFace[]    = L"Malgun Gothic";

// 앱 화면 어두운 테마와 비슷한 차분한 색. 싱어가 무대 조명 아래서 보기 쉽게 어둡게 둔다.
const COLORREF kBg          = RGB(13, 15, 18);
const COLORREF kCurrentFill = RGB(27, 32, 40);
const COLORREF kCurrentLine = RGB(90, 100, 114);
const COLORREF kNextFill    = RGB(15, 18, 21);
const COLORREF kNextLine    = RGB(35, 41, 48);
const COLORREF kDivider     = RGB(58, 66, 77);
const COLORREF kMuted       = RGB(154, 164, 177);
const COLORREF kLabel       = RGB(139, 149, 162);
const COLORREF kPlaceholder = RGB(89, 98, 110);
const COLORREF kBadge       = RGB(229, 72, 77);

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (n <= 0) return {};
  std::wstring out(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, out.data(), n);
  return out;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& m, const char* key) {
  auto it = m.find(flutter::EncodableValue(key));
  return it == m.end() ? nullptr : &it->second;
}

std::wstring GetWStr(const flutter::EncodableMap& m, const char* key) {
  const auto* v = Find(m, key);
  const auto* s = v ? std::get_if<std::string>(v) : nullptr;
  return s ? Utf8ToWide(*s) : std::wstring{};
}

bool GetBool(const flutter::EncodableMap& m, const char* key) {
  const auto* v = Find(m, key);
  const auto* b = v ? std::get_if<bool>(v) : nullptr;
  return b ? *b : false;
}

int GetInt(const flutter::EncodableMap& m, const char* key) {
  const auto* v = Find(m, key);
  if (!v) return 0;
  if (const auto* i = std::get_if<int32_t>(v)) return *i;
  if (const auto* l = std::get_if<int64_t>(v)) return static_cast<int>(*l);
  return 0;
}

HFONT MakeFont(int px, bool bold) {
  return CreateFontW(-px, 0, 0, 0, bold ? FW_BOLD : FW_SEMIBOLD, FALSE, FALSE, FALSE,
                     DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                     CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, kFontFace);
}

void FillRounded(HDC hdc, RECT r, int radius, COLORREF fill, COLORREF line,
                 int width = 1) {
  HBRUSH brush = CreateSolidBrush(fill);
  HPEN pen = CreatePen(PS_SOLID, width, line);
  HGDIOBJ old_brush = SelectObject(hdc, brush);
  HGDIOBJ old_pen = SelectObject(hdc, pen);
  RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius, radius);
  SelectObject(hdc, old_brush);
  SelectObject(hdc, old_pen);
  DeleteObject(brush);
  DeleteObject(pen);
}

// 한 줄 글자를 rect 안에 그린다(넘치면 … 처리).
void DrawLine(HDC hdc, const std::wstring& text, RECT r, int px, bool bold,
              COLORREF color, UINT align) {
  if (text.empty()) return;
  HFONT font = MakeFont(px, bold);
  HGDIOBJ old = SelectObject(hdc, font);
  SetTextColor(hdc, color);
  DrawTextW(hdc, text.c_str(), -1, &r,
            align | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
  SelectObject(hdc, old);
  DeleteObject(font);
}

// 글자 묶음의 크기를 잰다. wrap 이 false 면 원본 줄(\n)대로 — 폭은 가장 긴 줄,
// true 면 width 에서 자동 줄바꿈.
SIZE Measure(HDC hdc, const std::wstring& text, int px, int width, bool wrap) {
  if (text.empty()) return {0, 0};
  HFONT font = MakeFont(px, true);
  HGDIOBJ old = SelectObject(hdc, font);
  RECT r = {0, 0, width, 0};
  DrawTextW(hdc, text.c_str(), -1, &r,
            DT_CENTER | DT_NOPREFIX | DT_CALCRECT | (wrap ? DT_WORDBREAK : 0));
  SelectObject(hdc, old);
  DeleteObject(font);
  return {r.right - r.left, r.bottom - r.top};
}
}  // namespace

// ── lifecycle ─────────────────────────────────────────────────────────────────

SingerWindow::SingerWindow(HWND main_hwnd, Notify notify)
    : main_hwnd_(main_hwnd), notify_(std::move(notify)) {
  Register();
}

SingerWindow::~SingerWindow() { Close(); }

void SingerWindow::Register() {
  static bool registered = false;
  if (registered) return;
  WNDCLASSEXW wc = {};
  wc.cbSize        = sizeof(wc);
  wc.style         = CS_DBLCLKS;  // 더블클릭 = 전체화면 켜고 끄기
  wc.lpfnWndProc   = WndProc;
  wc.hInstance     = GetModuleHandle(nullptr);
  wc.hCursor       = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kClass;
  RegisterClassExW(&wc);
  registered = true;
}

void SingerWindow::Open(HMONITOR avoid, HMONITOR chosen) {
  if (hwnd_) {
    if (chosen && chosen != MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONULL)) {
      // 일반 창으로 풀고 고른 모니터로 옮긴 뒤 다시 전체화면(ToggleFullScreen 은 지금 모니터 기준).
      if (full_) ToggleFullScreen();
      MONITORINFO info = {sizeof(info)};
      GetMonitorInfo(chosen, &info);
      SetWindowPos(hwnd_, nullptr, info.rcWork.left, info.rcWork.top, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
      ToggleFullScreen();
    } else if (chosen && !full_) {
      ToggleFullScreen();
    }
    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
    return;
  }

  // 메인 창 모니터도, 관객 화면 모니터도 아닌 모니터가 있으면 거기에 전체화면으로.
  struct Pick { HMONITOR main; HMONITOR avoid; HMONITOR found; };
  Pick pick = {MonitorFromWindow(main_hwnd_, MONITOR_DEFAULTTOPRIMARY), avoid, nullptr};
  EnumDisplayMonitors(nullptr, nullptr,
    [](HMONITOR mon, HDC, LPRECT, LPARAM lp) -> BOOL {
      auto* p = reinterpret_cast<Pick*>(lp);
      if (mon != p->main && mon != p->avoid) { p->found = mon; return FALSE; }
      return TRUE;
    }, reinterpret_cast<LPARAM>(&pick));
  if (chosen) pick.found = chosen;

  // 없으면 메인 창 모니터 가운데 일반 창. 사용자가 원하는 모니터로 끌어 놓는다.
  MONITORINFO info = {sizeof(info)};
  GetMonitorInfo(pick.found ? pick.found : pick.main, &info);
  const int sw = info.rcWork.right - info.rcWork.left;
  const int sh = info.rcWork.bottom - info.rcWork.top;
  const int w = (std::min)(960, sw);
  const int h = (std::min)(600, sh);

  full_ = false;
  hwnd_ = CreateWindowExW(
      0, kClass, kTitle, WS_OVERLAPPEDWINDOW,
      info.rcWork.left + (sw - w) / 2, info.rcWork.top + (sh - h) / 2, w, h,
      nullptr, nullptr, GetModuleHandle(nullptr), this);
  if (!hwnd_) return;

  if (pick.found) ToggleFullScreen();
  // 포커스는 메인 창에 남긴다. 넘기기 단축키가 계속 메인 창에서 먹어야 한다.
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  UpdateWindow(hwnd_);
}

void SingerWindow::Close() {
  image_cache_.clear();
  // DestroyWindow 는 WM_CLOSE 를 거치지 않으므로 Dart 에 singerClosed 를 다시 보내지 않는다.
  if (hwnd_) {
    HWND h = hwnd_;
    hwnd_ = nullptr;
    DestroyWindow(h);
  }
}

void SingerWindow::Update(const flutter::EncodableMap& data) {
  auto read = [&](const char* key, Page* page) {
    *page = Page{};
    const auto* v = Find(data, key);
    const auto* m = v ? std::get_if<flutter::EncodableMap>(v) : nullptr;
    if (!m) return;  // 마지막 페이지면 next 가 null 이다
    page->present   = true;
    page->blank     = GetBool(*m, "is_blank");
    page->main      = GetWStr(*m, "main_text");
    page->sub       = GetWStr(*m, "english_text");
    page->title     = GetWStr(*m, "title");
    page->imagePath = GetWStr(*m, "image_path");
  };
  read("current", &current_);
  read("next", &next_);
  page_number_ = GetInt(data, "page_number");
  total_pages_ = GetInt(data, "total_pages");
  blackout_    = GetBool(data, "blackout");
  // 지금·다음 페이지가 안 쓰는 이미지는 놓아 준다(파일 잠금·메모리).
  for (auto it = image_cache_.begin(); it != image_cache_.end();) {
    if (it->first == current_.imagePath || it->first == next_.imagePath) ++it;
    else it = image_cache_.erase(it);
  }
  if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

// 일반 창 ↔ 지금 모니터 전체화면. 창 위치는 WINDOWPLACEMENT 로 기억했다 되돌린다.
void SingerWindow::ToggleFullScreen() {
  if (!hwnd_) return;
  const LONG_PTR style = GetWindowLongPtrW(hwnd_, GWL_STYLE);
  if (!full_) {
    MONITORINFO info = {sizeof(info)};
    if (!GetWindowPlacement(hwnd_, &placement_) ||
        !GetMonitorInfo(MonitorFromWindow(hwnd_, MONITOR_DEFAULTTOPRIMARY), &info)) {
      return;
    }
    SetWindowLongPtrW(hwnd_, GWL_STYLE, (style & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
    SetWindowPos(hwnd_, HWND_TOP, info.rcMonitor.left, info.rcMonitor.top,
                 info.rcMonitor.right - info.rcMonitor.left,
                 info.rcMonitor.bottom - info.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
    full_ = true;
  } else {
    SetWindowLongPtrW(hwnd_, GWL_STYLE, (style & ~WS_POPUP) | WS_OVERLAPPEDWINDOW);
    SetWindowPlacement(hwnd_, &placement_);
    SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                 SWP_FRAMECHANGED | SWP_NOACTIVATE);
    full_ = false;
  }
}

// ── rendering ─────────────────────────────────────────────────────────────────
//
//  ┌ 곡 제목 ─────────────────── [관객 화면 꺼짐]  3 / 20 ┐
//  │ ┌ 현재 페이지 (63%) ──────────────────────────────┐ │
//  │ └──────────────────────────────────────────────────┘ │
//  │ 다음 · 다음 곡 제목                                   │
//  │ ┌ 다음 페이지 (37%) ──────────────────────────────┐ │
//  └ └──────────────────────────────────────────────────┘ ┘
void SingerWindow::Paint(HDC hdc, RECT cli) const {
  const int W = cli.right, H = cli.bottom;
  HBRUSH bg = CreateSolidBrush(kBg);
  FillRect(hdc, &cli, bg);
  DeleteObject(bg);
  if (W <= 0 || H <= 0) return;
  SetBkMode(hdc, TRANSPARENT);

  const int padX    = (std::max)(12, W * 24 / 1000);
  const int padY    = (std::max)(10, H * 22 / 1000);
  const int headerH = (std::max)(20, H * 6 / 100);
  const int labelH  = (std::max)(18, H * 5 / 100);
  const int radius  = (std::max)(8, H * 28 / 1000);

  // 머리줄: 제목(왼쪽) · 페이지 번호(오른쪽) · 블랙아웃 표시
  const int headerPx = (std::max)(12, H * 30 / 1000);
  RECT header = {padX, padY, W - padX, padY + headerH};
  wchar_t pageText[32];
  swprintf_s(pageText, L"%d / %d", page_number_, total_pages_);
  // 페이지 수가 세 자리여도 잘리지 않게 실제 글자 폭을 잰다.
  int pageW = 0;
  {
    HFONT font = MakeFont(headerPx, true);
    HGDIOBJ old = SelectObject(hdc, font);
    RECT r = {0, 0, 0, 0};
    DrawTextW(hdc, pageText, -1, &r, DT_SINGLELINE | DT_NOPREFIX | DT_CALCRECT);
    SelectObject(hdc, old);
    DeleteObject(font);
    pageW = r.right - r.left + headerPx / 2;
  }
  DrawLine(hdc, pageText, {header.right - pageW, header.top, header.right, header.bottom},
           headerPx, true, RGB(230, 233, 238), DT_RIGHT);
  int titleRight = header.right - pageW;
  if (blackout_) {
    const int badgeW = headerPx * 8;
    const int badgeH = headerPx * 16 / 10;
    const int cy = (header.top + header.bottom) / 2;
    RECT badge = {titleRight - badgeW, cy - badgeH / 2, titleRight - headerPx / 2,
                  cy + badgeH / 2};
    FillRounded(hdc, badge, badgeH, kBadge, kBadge);
    DrawLine(hdc, kBlackout, badge, headerPx * 8 / 10, true, RGB(255, 255, 255), DT_CENTER);
    titleRight = badge.left - headerPx / 2;
  }
  DrawLine(hdc, current_.title, {header.left, header.top, titleRight, header.bottom},
           headerPx, true, kMuted, DT_LEFT);

  // 상자 두 개: 남은 높이를 63 : 37 로 나눈다.
  const int gap    = padY * 7 / 10;
  const int top    = header.bottom + gap;
  const int remain = H - padY - top - labelH - gap * 2;
  const int curH   = remain * 63 / 100;
  RECT curBox  = {padX, top, W - padX, top + curH};
  RECT label   = {padX, curBox.bottom + gap, W - padX, curBox.bottom + gap + labelH};
  RECT nextBox = {padX, label.bottom, W - padX, H - padY};

  FillRounded(hdc, curBox, radius, kCurrentFill, kCurrentLine, 2);
  FillRounded(hdc, nextBox, radius, kNextFill, kNextLine);
  // 현재와 다음 사이 구분선
  {
    HPEN pen = CreatePen(PS_SOLID, 1, kDivider);
    HGDIOBJ old = SelectObject(hdc, pen);
    const int ly = curBox.bottom + gap / 2;
    MoveToEx(hdc, padX, ly, nullptr);
    LineTo(hdc, W - padX, ly);
    SelectObject(hdc, old);
    DeleteObject(pen);
  }

  // 다음 페이지가 다른 곡·말씀이면 그 제목을 같이 알려 준다.
  std::wstring labelText = kNext;
  if (next_.present && !next_.title.empty() && next_.title != current_.title) {
    labelText += L" \x00B7 ";
    labelText += next_.title;
  }
  DrawLine(hdc, labelText, label, (std::max)(11, H * 25 / 1000), true, kLabel, DT_LEFT);

  auto paintBox = [&](RECT box, const Page& page, const wchar_t* emptyText, bool dim) {
    const int ix = (std::max)(8, W * 3 / 100);
    const int iy = (std::max)(6, H * 2 / 100);
    RECT inner = {box.left + ix, box.top + iy, box.right - ix, box.bottom - iy};
    if (inner.right <= inner.left || inner.bottom <= inner.top) return;
    if (!page.present || page.blank) {
      DrawLine(hdc, page.present ? kBlank : emptyText, inner,
               (std::max)(12, H * 34 / 1000), true, kPlaceholder, DT_CENTER);
    } else if (!page.imagePath.empty()) {
      PaintPageImage(hdc, inner, page.imagePath);
    } else {
      PaintText(hdc, inner, page, dim, H * 35 / 1000);
    }
  };
  paintBox(curBox, current_, kBlank, false);
  paintBox(nextBox, next_, kLastPage, true);
}

void SingerWindow::PaintText(HDC hdc, RECT box, const Page& page, bool dim,
                             int minPx) const {
  const int bw = box.right - box.left;
  const int bh = box.bottom - box.top;

  // 상자에 꼭 맞는 가장 큰 글자 크기를 이분 탐색으로 찾는다. 보조 가사는 본문의 78%.
  struct Layout { int mainPx, subPx, gap, mainH, subH; };
  bool wrap = false;
  auto layout = [&](int px) {
    Layout l = {px, px * 78 / 100, page.sub.empty() ? 0 : px * 45 / 100, 0, 0};
    const SIZE m = Measure(hdc, page.main, l.mainPx, bw, wrap);
    const SIZE s = Measure(hdc, page.sub, l.subPx, bw, wrap);
    l.mainH = m.cy;
    l.subH = s.cy;
    const bool fits = m.cx <= bw && s.cx <= bw && m.cy + l.gap + s.cy <= bh;
    return std::make_pair(fits, l);
  };
  auto fit = [&] {
    int lo = 8, hi = (std::max)(12, bh * 45 / 100);
    while (hi - lo > 1) {
      const int mid = (lo + hi) / 2;
      if (layout(mid).first) lo = mid; else hi = mid;
    }
    return lo;
  };
  // 원본 줄 그대로(관객 화면과 줄 수가 같게). 긴 줄 때문에 너무 작아지면 그때만 줄바꿈.
  int px = fit();
  if (px < minPx) {
    wrap = true;
    px = fit();
  }
  const Layout l = layout(px).second;

  // 최소 글자로도 넘치면 가운데 맞춤 대신 위에서부터 그리고 상자 밖은 잘라 낸다
  // (머리줄·'다음' 표시를 덮지 않게).
  int y = box.top + (std::max)(0, (bh - (l.mainH + l.gap + l.subH)) / 2);
  const int saved = SaveDC(hdc);
  IntersectClipRect(hdc, box.left, box.top, box.right, box.bottom);
  auto draw = [&](const std::wstring& text, int px, int height, COLORREF color) {
    if (text.empty()) return;
    HFONT font = MakeFont(px, true);
    HGDIOBJ old = SelectObject(hdc, font);
    SetTextColor(hdc, color);
    RECT r = {box.left, y, box.right, y + height};
    DrawTextW(hdc, text.c_str(), -1, &r, DT_CENTER | DT_NOPREFIX | (wrap ? DT_WORDBREAK : 0));
    SelectObject(hdc, old);
    DeleteObject(font);
  };
  draw(page.main, l.mainPx, l.mainH, dim ? RGB(195, 202, 212) : RGB(255, 255, 255));
  y += l.mainH + l.gap;
  draw(page.sub, l.subPx, l.subH, dim ? RGB(184, 162, 90) : RGB(255, 213, 79));
  RestoreDC(hdc, saved);
}

// 외부 PPT 페이지 이미지: 비율을 지켜 상자 가운데에 그린다(contain).
// 창 크기 조절·블랙아웃 표시에도 다시 그리므로 디코딩한 이미지는 경로별로 들고 있는다.
void SingerWindow::PaintPageImage(HDC hdc, RECT box, const std::wstring& path) const {
  auto& slot = image_cache_[path];
  if (!slot) slot = std::make_unique<Gdiplus::Image>(path.c_str());
  Gdiplus::Image& image = *slot;
  if (image.GetLastStatus() != Gdiplus::Ok) return;
  const UINT iw = image.GetWidth();
  const UINT ih = image.GetHeight();
  if (iw == 0 || ih == 0) return;
  const int bw = box.right - box.left;
  const int bh = box.bottom - box.top;
  const double scale = (std::min)(static_cast<double>(bw) / iw,
                                  static_cast<double>(bh) / ih);
  const int dw = static_cast<int>(iw * scale + 0.5);
  const int dh = static_cast<int>(ih * scale + 0.5);
  Gdiplus::Graphics g(hdc);
  g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  g.DrawImage(&image, box.left + (bw - dw) / 2, box.top + (bh - dh) / 2, dw, dh);
}

// ── window procedure ──────────────────────────────────────────────────────────

LRESULT CALLBACK SingerWindow::WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self = reinterpret_cast<SingerWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (!self) return DefWindowProcW(hwnd, msg, wp, lp);

  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      RECT cli;
      GetClientRect(hwnd, &cli);
      // 깜빡임 방지용 더블 버퍼
      HDC mdc = CreateCompatibleDC(hdc);
      HBITMAP bmp = CreateCompatibleBitmap(hdc, cli.right, cli.bottom);
      HGDIOBJ old = SelectObject(mdc, bmp);
      self->Paint(mdc, cli);
      BitBlt(hdc, 0, 0, cli.right, cli.bottom, mdc, 0, 0, SRCCOPY);
      SelectObject(mdc, old);
      DeleteObject(bmp);
      DeleteDC(mdc);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;  // WM_PAINT 에서 칠한다

    case WM_SIZE:
      InvalidateRect(hwnd, nullptr, FALSE);
      return 0;

    case WM_LBUTTONDBLCLK:
      self->ToggleFullScreen();
      return 0;

    case WM_KEYDOWN:
      switch (wp) {
        case VK_ESCAPE:
          // 전체화면 풀기만. 닫기는 Ctrl+F4(잘못 눌러 꺼지는 사고 방지)
          if (self->full_) self->ToggleFullScreen();
          return 0;
        case VK_F4:
          if (!(GetKeyState(VK_CONTROL) & 0x8000)) break;
          SendMessage(hwnd, WM_CLOSE, 0, 0);
          return 0;
        case 'F':
        case VK_F11:
          self->ToggleFullScreen();
          return 0;
        // 싱어 화면을 클릭해 포커스가 여기 있어도 넘기기는 메인 창과 똑같이 되게 한다.
        case VK_RIGHT: case VK_DOWN: case VK_SPACE: case VK_NEXT:
          if (self->notify_) self->notify_("singerKey", "next");
          return 0;
        case VK_LEFT: case VK_UP: case VK_PRIOR:
          if (self->notify_) self->notify_("singerKey", "prev");
          return 0;
      }
      break;

    case WM_CLOSE:
      // 사용자가 닫았다. Dart 에 알려 버튼 상태를 맞춘다.
      self->hwnd_ = nullptr;
      if (self->notify_) self->notify_("singerClosed", "");
      DestroyWindow(hwnd);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
