#include "ocr_channel.h"

#include <algorithm>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Graphics::Imaging::BitmapAlphaMode;
using winrt::Windows::Graphics::Imaging::BitmapDecoder;
using winrt::Windows::Graphics::Imaging::BitmapPixelFormat;
using winrt::Windows::Media::Ocr::OcrEngine;
using winrt::Windows::Storage::FileAccessMode;
using winrt::Windows::Storage::StorageFile;

constexpr UINT kOcrDone = WM_APP + 0x31;
constexpr wchar_t kWindowClass[] = L"WorshipSlidesOcrChannel";

// 작업 스레드 → UI 스레드로 넘기는 응답 한 건.
struct Done {
  std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
  EncodableValue value;
  std::string error;  // 비어 있지 않으면 Dart 에 PlatformException 으로 보낸다
};

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (n <= 0) return {};
  std::wstring out(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out.data(), n);
  return out;
}

// 한국어 엔진. 한국어 OCR 은 영문도 같이 읽는다. 언어 데이터가 없으면 nullptr.
OcrEngine KoreanEngine() {
  winrt::Windows::Globalization::Language korean(L"ko");
  if (!OcrEngine::IsLanguageSupported(korean)) return nullptr;
  return OcrEngine::TryCreateFromLanguage(korean);
}

// 이미지 한 장 → 줄마다 {text, confidence, x, y, w, h}. 좌표는 0~1, 위가 0 (Python 쪽 약속).
// Windows.Media.Ocr 는 확신도를 주지 않아 1.0 으로 둔다.
EncodableList Recognize(const OcrEngine& engine, const std::string& path) {
  EncodableList out;
  auto file = StorageFile::GetFileFromPathAsync(winrt::hstring(Wide(path))).get();
  auto stream = file.OpenAsync(FileAccessMode::Read).get();
  auto decoder = BitmapDecoder::CreateAsync(stream).get();
  auto bitmap = decoder
      .GetSoftwareBitmapAsync(BitmapPixelFormat::Bgra8, BitmapAlphaMode::Premultiplied)
      .get();
  const double width = bitmap.PixelWidth();
  const double height = bitmap.PixelHeight();
  // 이보다 큰 그림은 RecognizeAsync 가 실패한다. Python 이 미리 줄여서 보낸다.
  const double limit = OcrEngine::MaxImageDimension();
  if (width <= 0 || height <= 0 || width > limit || height > limit) return out;

  auto result = engine.RecognizeAsync(bitmap).get();
  for (const auto& line : result.Lines()) {
    double left = width, top = height, right = 0, bottom = 0;
    for (const auto& word : line.Words()) {
      const auto rect = word.BoundingRect();
      left = std::min<double>(left, rect.X);
      top = std::min<double>(top, rect.Y);
      right = std::max<double>(right, rect.X + rect.Width);
      bottom = std::max<double>(bottom, rect.Y + rect.Height);
    }
    if (right <= left || bottom <= top) continue;
    out.emplace_back(EncodableMap{
        {EncodableValue("text"), EncodableValue(winrt::to_string(line.Text()))},
        {EncodableValue("confidence"), EncodableValue(1.0)},
        {EncodableValue("x"), EncodableValue(left / width)},
        {EncodableValue("y"), EncodableValue(top / height)},
        {EncodableValue("w"), EncodableValue((right - left) / width)},
        {EncodableValue("h"), EncodableValue((bottom - top) / height)},
    });
  }
  return out;
}

// 작업 스레드 본체. paths 가 없으면 isAvailable, 있으면 recognize.
void Run(bool recognize, const std::vector<std::string>& paths, Done* done) {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  try {
    OcrEngine engine = KoreanEngine();
    if (!recognize) {
      done->value = EncodableValue(static_cast<bool>(engine));
    } else if (!engine) {
      done->error = "Korean OCR is not installed";
    } else {
      EncodableMap map;
      for (const auto& path : paths) {
        EncodableList lines;
        try {
          lines = Recognize(engine, path);
        } catch (const winrt::hresult_error&) {
          // 한 장이 실패해도 나머지는 읽는다. Python 은 빈 줄로 보고 건너뛴다.
        }
        map[EncodableValue(path)] = EncodableValue(std::move(lines));
      }
      done->value = EncodableValue(std::move(map));
    }
  } catch (const winrt::hresult_error& e) {
    if (recognize) {
      done->error = winrt::to_string(e.message());
    } else {
      done->value = EncodableValue(false);
    }
  } catch (...) {
    // 작업 스레드에서 예외가 새어 나가면 앱이 통째로 죽는다.
    if (recognize) {
      done->error = "OCR failed";
    } else {
      done->value = EncodableValue(false);
    }
  }
  winrt::uninit_apartment();
}

}  // namespace

OcrChannel::~OcrChannel() {
  if (hwnd_) DestroyWindow(hwnd_);
}

void OcrChannel::Setup(flutter::FlutterEngine* engine) {
  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kWindowClass;
  RegisterClassW(&wc);
  hwnd_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                          nullptr, wc.hInstance, nullptr);

  channel_ = std::make_unique<Channel>(
      engine->messenger(), "worship_slides/ocr",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        const std::string& method = call.method_name();
        if (method != "isAvailable" && method != "recognize") {
          result->NotImplemented();
          return;
        }
        std::vector<std::string> paths;
        if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
          auto it = args->find(EncodableValue("paths"));
          if (it != args->end()) {
            if (const auto* list = std::get_if<EncodableList>(&it->second)) {
              for (const auto& item : *list) {
                if (const auto* path = std::get_if<std::string>(&item)) {
                  paths.push_back(*path);
                }
              }
            }
          }
        }
        auto* done = new Done{std::move(result), EncodableValue(), std::string()};
        const bool recognize = method == "recognize";
        HWND target = hwnd_;
        std::thread([recognize, paths = std::move(paths), done, target]() {
          Run(recognize, paths, done);
          // 앱이 닫히는 중이라 창이 없으면 응답할 곳도 없다.
          if (!PostMessageW(target, kOcrDone, 0, reinterpret_cast<LPARAM>(done))) {
            delete done;
          }
        }).detach();
      });
}

LRESULT CALLBACK OcrChannel::WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kOcrDone) {
    std::unique_ptr<Done> done(reinterpret_cast<Done*>(lp));
    if (!done->error.empty()) {
      done->result->Error("ocr_unavailable", done->error);
    } else {
      done->result->Success(done->value);
    }
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
