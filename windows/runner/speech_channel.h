#pragma once

#include <windows.h>
#include <memory>
#include <mutex>
#include <string>

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <winrt/Windows.Media.SpeechRecognition.h>

// 성경 음성 검색 (Windows.Media.SpeechRecognition, 한국어).
// Dart 가 만든 SRGS 문법(책·숫자·장·절·역본 + 앞뒤 GARBAGE)으로 계속 듣는다 — 받아쓰기와 달리
// Windows '온라인 음성 인식' 설정 없이 오프라인으로 돈다. 한국어 음성 언어 팩이 있어야 한다.
// 채널 `worship_slides/speech`: start {grammar} / stop, 네이티브 → Dart partial / final / error {text|message}.
class SpeechChannel {
 public:
  SpeechChannel() = default;
  ~SpeechChannel();
  void Setup(flutter::FlutterEngine* engine);

 private:
  using EV      = flutter::EncodableValue;
  using Channel = flutter::MethodChannel<EV>;

  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);

  // WinRT 비동기는 UI(STA) 스레드에서 기다릴 수 없어서 작업 스레드에서 켜고 끈다.
  // 인식 결과(다른 스레드)는 이 메시지 전용 창으로 UI 스레드에 넘겨 Dart 에 보낸다.
  // 작업 스레드가 이 객체보다 오래 살 수 있어 상태는 shared_ptr 로 나눠 갖는다(앱 종료 중 해제된 메모리를 쓰지 않게).
  struct State {
    // 켜기·끄기를 한 번에 하나씩. 늦게 시작한 켜기가 먼저 끝난 끄기 뒤에 마이크를 다시 켜지 않게,
    // 켜기는 그 뒤로 다른 요청이 왔으면(requested 가 바뀜) 하지 않는다.
    std::mutex op;
    std::mutex mutex;  // recognizer
    unsigned requested = 0;  // UI 스레드에서만 올리고, op 안에서 읽는다(mutex 로 보호)
    winrt::Windows::Media::SpeechRecognition::SpeechRecognizer recognizer{nullptr};
  };
  static void Start(const std::shared_ptr<State>& state, unsigned seq, std::string grammar, HWND hwnd, void* done);
  static void Stop(const std::shared_ptr<State>& state);

  HWND hwnd_ = nullptr;
  std::unique_ptr<Channel> channel_;
  std::shared_ptr<State> state_ = std::make_shared<State>();
};
