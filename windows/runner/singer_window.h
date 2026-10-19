#pragma once

#include <windows.h>

#include <functional>
#include <map>
#include <memory>
#include <string>

#include <flutter/encodable_value.h>

namespace Gdiplus { class Image; }

// 싱어 화면: 관객용 발표 창과 별도로 뜨는 두 번째 창.
// 디자인(배경·폰트·위치)은 무시하고 "현재 페이지(크게) + 다음 페이지(작게)"를
// 읽기 쉬운 고정 레이아웃으로 그린다. macOS 는 MainFlutterWindow.swift 의
// SingerWindowController 가 같은 일을 한다.
//
// 일반 창으로 열리므로 원하는 모니터로 끌어 놓고 더블클릭(또는 F·F11)으로 전체화면을 켠다.
// GDI+ 는 PresentationChannel 이 시작·종료하므로 이 객체가 먼저 사라져야 한다.
class SingerWindow {
 public:
  // method: "singerClosed" | "singerKey", arg: "next" | "prev" | ""
  using Notify = std::function<void(const std::string& method, const std::string& arg)>;

  SingerWindow(HWND main_hwnd, Notify notify);
  ~SingerWindow();

  // chosen: 사용자가 고른 모니터(nullptr = 자동). 자동이면 avoid(관객 화면 모니터)도
  // 메인 창 모니터도 아닌 모니터에 전체화면으로 연다. 이미 열려 있으면 chosen 으로 옮긴다.
  void Open(HMONITOR avoid, HMONITOR chosen);
  void Close();
  void Update(const flutter::EncodableMap& data);
  bool IsOpen() const { return hwnd_ != nullptr; }

 private:
  struct Page {
    bool present = false;  // 다음 페이지가 없으면 false
    bool blank   = false;
    std::wstring main, sub, title, imagePath;
  };

  struct ClockText {
    std::wstring time, elapsed, target;  // 비어 있으면 그리지 않는다
    COLORREF color = 0;                  // 경과 시간 색(목표 80% 넘으면 주황, 넘기면 빨강)
  };
  ClockText CurrentClockText() const;

  void Paint(HDC hdc, RECT cli) const;
  // 상자 안에 꼭 맞는 가장 큰 글자로 원본 + 보조 가사를 가운데 그린다.
  // 원본 줄 그대로 맞추다 글자가 minPx 보다 작아지면 그때만 자동 줄바꿈한다.
  void PaintText(HDC hdc, RECT box, const Page& page, bool dim, int minPx) const;
  void PaintPageImage(HDC hdc, RECT box, const std::wstring& path) const;
  void ToggleFullScreen();

  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  static void Register();

  HWND main_hwnd_ = nullptr;
  HWND hwnd_      = nullptr;
  Notify notify_;
  bool full_ = false;  // 전체화면 여부

  Page current_, next_;
  int  page_number_ = 0, total_pages_ = 0;
  bool blackout_    = false;

  // 시계·경과 시간(Dart PresentationTimer). 받은 순간(clock_at_, GetTickCount64)부터 이어서 센다.
  bool clock_show_ = false, clock_running_ = false;
  int64_t clock_ms_ = 0, clock_target_ = 0;
  ULONGLONG clock_at_ = 0;
  // 마지막으로 그린 시계 글자. 타이머가 이것과 다를 때만 다시 그린다.
  mutable std::wstring last_clock_;

  // 경로 → 디코딩한 페이지 이미지. Update 때 지금·다음 페이지 것만 남긴다.
  mutable std::map<std::wstring, std::unique_ptr<Gdiplus::Image>> image_cache_;

  // 전체화면을 풀 때 되돌아갈 창 위치.
  WINDOWPLACEMENT placement_ = {sizeof(WINDOWPLACEMENT)};

  static constexpr wchar_t kClass[] = L"WorshipSingerView";
};
