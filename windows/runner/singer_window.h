#pragma once

#include <windows.h>

#include <functional>
#include <string>

#include <flutter/encodable_value.h>

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

  // avoid: 관객 화면이 쓰는 모니터. 그 밖의 보조 모니터가 있으면 거기에 전체화면으로 연다.
  void Open(HMONITOR avoid);
  void Close();
  void Update(const flutter::EncodableMap& data);
  bool IsOpen() const { return hwnd_ != nullptr; }

 private:
  struct Page {
    bool present = false;  // 다음 페이지가 없으면 false
    bool blank   = false;
    std::wstring main, sub, title, imagePath;
  };

  void Paint(HDC hdc, RECT cli) const;
  // 상자 안에 꼭 맞는 가장 큰 글자로 원본 + 보조 가사를 가운데 그린다.
  void PaintText(HDC hdc, RECT box, const Page& page, bool dim) const;
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

  // 전체화면을 풀 때 되돌아갈 창 위치.
  WINDOWPLACEMENT placement_ = {sizeof(WINDOWPLACEMENT)};

  static constexpr wchar_t kClass[] = L"WorshipSingerView";
};
