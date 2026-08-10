#pragma once

#include <windows.h>
#include <memory>
#include <string>

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

class PresentationChannel {
 public:
  explicit PresentationChannel(HWND main_hwnd);
  ~PresentationChannel();
  void Setup(flutter::FlutterEngine* engine);

 private:
  using EV      = flutter::EncodableValue;
  using Channel = flutter::MethodChannel<EV>;

  struct Slide {
    std::wstring main, english, title, fontFamily;
    // 외부 PPT에서 구운 페이지 이미지. 비어 있지 않으면 텍스트 대신 이 이미지만 그린다.
    std::wstring imagePath;
    bool    isBible  = false, showTitle = false, inclEng = true;
    bool    blackout = false;
    COLORREF bg      = RGB(27, 27, 27);
    COLORREF txt     = RGB(255, 255, 255);
    COLORREF eng     = RGB(255, 241, 118);
    COLORREF ttlClr  = RGB(255, 255, 255);
    double   mainSz  = 30.0, engSz = 24.0, ttlSz = 14.0;
    double   boxTop  = 0.6;   // slide units (0–7.5)
    int      vAlign  = 1;     // 0=top 1=center 2=bottom
    int      hAlign  = 1;     // 0=left 1=center 2=right
    int      ttlH    = 2;     // 0=left 1=center 2=right
    int      ttlV    = 2;     // 0=top 1=middle 2=bottom
  };

  void OpenWindow();
  void CloseWindow();
  void Apply(const flutter::EncodableMap& data);
  void Paint(HDC hdc, RECT cli) const;
  void PaintImage(HDC hdc, int w, int h) const;

  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  static void Register();
  static COLORREF HexRgb(const std::string& hex, COLORREF def);
  static std::wstring W(const std::string& utf8);
  static UINT HFlag(int h);

  HWND main_hwnd_ = nullptr;
  HWND hwnd_      = nullptr;
  ULONG_PTR gdiplus_token_ = 0;  // 이미지 슬라이드 렌더링용 GDI+ 토큰
  Slide slide_;
  std::unique_ptr<Channel> cmd_;
  std::unique_ptr<Channel> main_;

  static PresentationChannel* s_;
  static constexpr wchar_t kClass[] = L"WorshipPresentation";
};
