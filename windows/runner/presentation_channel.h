#pragma once

#include <windows.h>
#include <memory>
#include <string>

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

// gdiplus.h 는 NOMINMAX 충돌 때문에 .cpp 에서 순서를 맞춰 include 한다.
// 여기서는 전방 선언만 하고, 소멸은 타입이 완전한 .cpp 쪽에서 이뤄진다.
namespace Gdiplus {
class Image;
}

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
  void PaintPointer(HDC hdc, int w, int h) const;

  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  static void Register();
  static COLORREF HexRgb(const std::string& hex, COLORREF def);
  static std::wstring W(const std::string& utf8);
  static UINT HFlag(int h);

  HWND main_hwnd_ = nullptr;
  HWND hwnd_      = nullptr;
  ULONG_PTR gdiplus_token_ = 0;  // 이미지 슬라이드 렌더링용 GDI+ 토큰
  Slide slide_;

  // 발표자 보기에서 보내온 관객 화면 포인터. 0=숨김 1=손가락 2=레이저 점.
  int    ptr_mode_ = 0;
  double ptr_x_    = 0.0;   // 0~1
  double ptr_y_    = 0.0;   // 0~1
  double ptr_size_ = 100.0; // px

  // 포인터를 움직이면 매 프레임 다시 그리는데, 이미지 슬라이드를 그때마다
  // 디코딩하면 창이 버벅인다. 경로가 같으면 디코딩한 것을 재사용한다.
  mutable std::unique_ptr<Gdiplus::Image> image_cache_;
  mutable std::wstring image_cache_path_;
  std::unique_ptr<Channel> cmd_;
  std::unique_ptr<Channel> main_;

  static PresentationChannel* s_;
  static constexpr wchar_t kClass[] = L"WorshipPresentation";
};
