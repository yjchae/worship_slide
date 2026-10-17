#pragma once

#include <windows.h>
#include <memory>

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

// 악보 가사 OCR (Windows.Media.Ocr).
// 오선·가사 줄 찾기는 Python(ppt_tool sheet --ocr-lines)이 하고, 잘라 낸 가사 줄
// 이미지 읽기만 여기서 한다. 한국어 OCR 은 Windows 의 한국어 언어 팩(또는 선택적
// 기능 'OCR 한국어')이 깔려 있어야 쓸 수 있다. 없으면 isAvailable 이 false 이고
// 앱은 Tesseract 로 읽는다.
class OcrChannel {
 public:
  OcrChannel() = default;
  ~OcrChannel();
  void Setup(flutter::FlutterEngine* engine);

 private:
  using EV      = flutter::EncodableValue;
  using Channel = flutter::MethodChannel<EV>;

  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);

  // WinRT 비동기 호출은 UI(STA) 스레드에서 기다릴 수 없어서 작업 스레드에서 읽는다.
  // 결과는 이 메시지 전용 창으로 UI 스레드에 넘겨 받아 Dart 에 돌려준다
  // (Flutter 채널 응답은 UI 스레드에서만 보낼 수 있다).
  HWND hwnd_ = nullptr;
  std::unique_ptr<Channel> channel_;
};
