#include "speech_channel.h"

#include <chrono>
#include <fstream>
#include <string>
#include <thread>
#include <utility>

#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Storage.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace winrt::Windows::Media::SpeechRecognition;
using winrt::Windows::Storage::StorageFile;

constexpr UINT kSpeechDone = WM_APP + 0x41;   // start/stop 응답
constexpr UINT kSpeechEvent = WM_APP + 0x42;  // partial/final/error
constexpr wchar_t kWindowClass[] = L"WorshipSlidesSpeechChannel";

struct Done {
  std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
  // 비어 있지 않으면 PlatformException 메시지. 한글 안내는 Dart(SpeechListener)가 코드로 붙인다
  // (이 프로젝트 C++ 은 한글 문자열을 그대로 쓰지 않는다 — 소스 인코딩).
  std::string error;
};

struct Event {
  std::string method;
  std::string key;  // "text" | "message"
  std::string value;
};

void Post(HWND hwnd, std::string method, std::string key, std::string value) {
  auto* event = new Event{std::move(method), std::move(key), std::move(value)};
  if (!PostMessageW(hwnd, kSpeechEvent, 0, reinterpret_cast<LPARAM>(event))) delete event;
}

bool KoreanSupported() {
  for (const auto& language : SpeechRecognizer::SupportedGrammarLanguages()) {
    if (language.LanguageTag() == L"ko-KR") return true;
  }
  return false;
}

}  // namespace

SpeechChannel::~SpeechChannel() {
  {
    // 켜는 중이면 끝날 때까지 기다린다(앱 종료 때 한 번, 길어야 1~2초). 안 기다리면 켜기가 닫은 뒤에
    // 인식기를 다시 넣어 마이크가 남는다.
    std::lock_guard<std::mutex> op(state_->op);
    std::lock_guard<std::mutex> guard(state_->mutex);
    state_->requested++;  // 아직 기다리는 켜기는 하지 않게
    if (state_->recognizer) {
      try {
        state_->recognizer.Close();
      } catch (...) {
      }
      state_->recognizer = nullptr;
    }
  }
  if (hwnd_) DestroyWindow(hwnd_);
}

void SpeechChannel::Start(const std::shared_ptr<State>& state, unsigned seq, std::string grammar,
                          HWND hwnd, void* raw) {
  auto* done = static_cast<Done*>(raw);
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  try {
    Stop(state);
    bool stale;
    {
      std::lock_guard<std::mutex> guard(state->mutex);
      stale = state->requested != seq;
    }
    if (stale) {
      // 그 사이 끄기(또는 다시 켜기)가 왔다. 뒤 요청이 정한다.
    } else if (!KoreanSupported()) {
      done->error = "no_korean";
    } else {
      // 문법은 파일로만 넘길 수 있다. 앱 패키지가 아니라 ApplicationData 를 못 써서 임시 폴더에 둔다.
      wchar_t temp[MAX_PATH];
      GetTempPathW(MAX_PATH, temp);
      std::wstring path = std::wstring(temp) + L"worship_bible_voice.grxml";
      {
        std::ofstream out(path, std::ios::binary | std::ios::trunc);
        out << grammar;
      }
      auto file = StorageFile::GetFileFromPathAsync(winrt::hstring(path)).get();
      SpeechRecognizer recognizer(winrt::Windows::Globalization::Language(L"ko-KR"));
      recognizer.Constraints().Append(SpeechRecognitionGrammarFileConstraint(file, L"bible"));
      auto compiled = recognizer.CompileConstraintsAsync().get();
      if (compiled.Status() != SpeechRecognitionResultStatus::Success) {
        done->error = "grammar";
        recognizer.Close();
      } else {
        auto session = recognizer.ContinuousRecognitionSession();
        // 조용해도 끝내지 않는다(설교 내내 켜 둔다).
        session.AutoStopSilenceTimeout(std::chrono::hours(24));
        recognizer.HypothesisGenerated(
            [hwnd](const auto&, const SpeechRecognitionHypothesisGeneratedEventArgs& args) {
              Post(hwnd, "partial", "text", winrt::to_string(args.Hypothesis().Text()));
            });
        session.ResultGenerated(
            [hwnd](const auto&, const SpeechContinuousRecognitionResultGeneratedEventArgs& args) {
              const auto result = args.Result();
              // 문법 인식기는 아무 소리나 문법에 억지로 맞추므로 확신이 낮은 것은 버린다.
              if (result.Status() != SpeechRecognitionResultStatus::Success) return;
              const auto confidence = result.Confidence();
              if (confidence != SpeechRecognitionConfidence::High &&
                  confidence != SpeechRecognitionConfidence::Medium) {
                Post(hwnd, "partial", "text", "");
                return;
              }
              Post(hwnd, "final", "text", winrt::to_string(result.Text()));
            });
        session.Completed(
            [hwnd](const auto&, const SpeechContinuousRecognitionCompletedEventArgs& args) {
              // 끈 경우에도 온다. Dart 는 이미 꺼져 있으면 무시한다.
              if (args.Status() != SpeechRecognitionResultStatus::Success) {
                Post(hwnd, "error", "message",
                     "stopped " + std::to_string(static_cast<int>(args.Status())));
              }
            });
        session.StartAsync().get();
        std::lock_guard<std::mutex> guard(state->mutex);
        state->recognizer = recognizer;
      }
    }
  } catch (const winrt::hresult_error& e) {
    if (e.code() == E_ACCESSDENIED) {
      done->error = "mic_denied";
    } else {
      done->error = winrt::to_string(e.message());
    }
  } catch (...) {
    // 작업 스레드에서 예외가 새어 나가면 앱이 통째로 죽는다.
    done->error = "failed";
  }
  winrt::uninit_apartment();
}

void SpeechChannel::Stop(const std::shared_ptr<State>& state) {
  SpeechRecognizer recognizer{nullptr};
  {
    std::lock_guard<std::mutex> guard(state->mutex);
    std::swap(recognizer, state->recognizer);
  }
  if (!recognizer) return;
  try {
    recognizer.ContinuousRecognitionSession().StopAsync().get();
  } catch (...) {
    // 이미 멈췄으면 실패한다 — 닫기만 하면 된다.
  }
  try {
    recognizer.Close();
  } catch (...) {
  }
}

void SpeechChannel::Setup(flutter::FlutterEngine* engine) {
  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kWindowClass;
  RegisterClassW(&wc);
  hwnd_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                          nullptr, wc.hInstance, nullptr);
  SetWindowLongPtrW(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));

  channel_ = std::make_unique<Channel>(
      engine->messenger(), "worship_slides/speech",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        const std::string& method = call.method_name();
        if (method != "start" && method != "stop") {
          result->NotImplemented();
          return;
        }
        std::string grammar;
        if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
          auto it = args->find(EncodableValue("grammar"));
          if (it != args->end()) {
            if (const auto* text = std::get_if<std::string>(&it->second)) grammar = *text;
          }
        }
        auto* done = new Done{std::move(result), std::string()};
        HWND target = hwnd_;
        const bool start = method == "start";
        unsigned seq;
        {
          std::lock_guard<std::mutex> guard(state_->mutex);
          seq = ++state_->requested;
        }
        std::thread([state = state_, seq, start, grammar = std::move(grammar), done, target]() {
          std::lock_guard<std::mutex> op(state->op);
          if (start) {
            Start(state, seq, grammar, target, done);
          } else {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            Stop(state);
            winrt::uninit_apartment();
          }
          if (!PostMessageW(target, kSpeechDone, 0, reinterpret_cast<LPARAM>(done))) {
            // 창이 없다 = 앱이 닫혔다. 엔진이 사라진 뒤 작업 스레드에서 응답 객체를 지우면 죽을 수 있어 그냥 둔다.
            done->result.release();
            delete done;
          }
        }).detach();
      });
}

LRESULT CALLBACK SpeechChannel::WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kSpeechDone) {
    std::unique_ptr<Done> done(reinterpret_cast<Done*>(lp));
    if (!done->error.empty()) {
      done->result->Error("speech_unavailable", done->error);
    } else {
      done->result->Success();
    }
    return 0;
  }
  if (msg == kSpeechEvent) {
    std::unique_ptr<Event> event(reinterpret_cast<Event*>(lp));
    auto* self = reinterpret_cast<SpeechChannel*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self && self->channel_) {
      self->channel_->InvokeMethod(
          event->method,
          std::make_unique<EV>(EncodableMap{
              {EV(event->key), EV(event->value)},
          }));
    }
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
