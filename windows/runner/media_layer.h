#pragma once

#include <windows.h>
#include <wrl.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include <WebView2.h>

// 발표 창 위에 얹는 미디어 레이어(동영상·음악·유튜브). WebView2 자식 창으로 띄운다.
// GDI 로 그리는 슬라이드는 그대로 두고 그 위에서 재생한다 — 페이지를 다시 그려도
// (디자인 변경·같은 동영상이 든 애니메이션 단계) key 가 같으면 끊지 않는다.
// 페이드는 레이어 페이지(Dart mediaPlayerHtml)의 JS 가 한다. 여기선 부르기만 한다.
//
// WebView2 런타임(Windows 10/11 기본 탑재)이 없으면 레이어만 안 뜨고 슬라이드는 그대로다.
class MediaLayer {
 public:
  struct Media {
    std::string key, kind, html;
    std::wstring path;          // 동영상·음악 파일. 유튜브는 비어 있다.
    std::vector<double> rect;   // 슬라이드 기준 [x,y,w,h]. 비면 화면 전체.
    double fadeOut = 0.0;
    // 배경 영상(가사 뒤 반복 재생): 가사 PNG 폴더와 PNG 를 바꾸는 JS. 같은 key 로 페이지만
    // 넘어가면 레이어는 그대로 두고 overlay_js 만 다시 실행한다(Dart SlideBackdrop).
    std::wstring overlay_dir;
    std::wstring overlay_js;
  };

  // on_state: 지금 레이어의 재생 위치 JSON({"t","d","p"}). 발표 보기 재생바가 받는다.
  MediaLayer(HWND parent, std::function<void(const std::wstring&)> on_state);
  ~MediaLayer();
  MediaLayer(const MediaLayer&) = delete;
  MediaLayer& operator=(const MediaLayer&) = delete;

  // 페이지가 바뀔 때마다. media == nullptr 이면 지금 것을 페이드 아웃하고 끝.
  // image_aspect: PPT 안 동영상 자리를 레터박스에 맞추는 데 쓰는 페이지 이미지 비율.
  // 새 미디어일 때만 읽는다(0 이하 = 16:9).
  void Update(const Media* media, double image_aspect);
  void Layout();
  void Run(const std::wstring& script);  // toggle()·setBlack(..)
  void OnTimer();
  const std::string& current_key() const;

  static constexpr UINT_PTR kTimerId = 0x4D44;  // 'MD'

 private:
  struct Slot;

  void EnsureEnvironment();
  void CreateController(const std::shared_ptr<Slot>& slot);
  void Retire();
  void LayoutSlot(Slot& slot) const;
  static void Close(Slot& slot);

  HWND parent_;
  std::function<void(const std::wstring&)> on_state_;
  double image_aspect_ = 16.0 / 9.0;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> env_;
  bool env_pending_ = false;
  bool env_failed_ = false;
  std::shared_ptr<Slot> current_;
  std::vector<std::shared_ptr<Slot>> retiring_;
  unsigned counter_ = 0;
  // WebView2 콜백은 나중에 UI 스레드로 온다. 그 사이 이 객체가 사라졌는지(발표 종료) 본다.
  std::shared_ptr<int> alive_ = std::make_shared<int>(0);
};
