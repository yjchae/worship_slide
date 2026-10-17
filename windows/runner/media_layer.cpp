#include "media_layer.h"

#include <algorithm>
#include <cmath>
#include <fstream>

#include <WebView2EnvironmentOptions.h>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

namespace {

// 레이어 페이지는 임시 폴더의 HTML 파일을 이 가상 호스트(https)로 띄운다. 유튜브는
// 출처(Referer) 없는 페이지에서 재생을 막는다(오류 153) — NavigateToString·file:// 은 출처가 없다.
constexpr wchar_t kAppHost[] = L"app.worship";
// 동영상·음악 파일 폴더. Dart kWindowsMediaHost 와 같아야 한다.
constexpr wchar_t kMediaHost[] = L"media.worship";

std::wstring TempDir() {
  wchar_t buf[MAX_PATH + 1] = {};
  const DWORD n = GetTempPathW(MAX_PATH + 1, buf);
  std::wstring dir = std::wstring(buf, n) + L"worship_slides_media";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir;
}

std::wstring FolderOf(const std::wstring& path) {
  const auto pos = path.find_last_of(L"\\/");
  return pos == std::wstring::npos ? L"." : path.substr(0, pos);
}

// 기본값(실행 파일 옆 폴더)은 설치 폴더라 쓰기가 막혀 있을 수 있다.
std::wstring UserDataFolder() {
  wchar_t buf[MAX_PATH] = {};
  const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return L"";
  std::wstring dir = std::wstring(buf, n) + L"\\worship_slides";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\WebView2";
}

}  // namespace

struct MediaLayer::Slot {
  Media media;
  std::wstring html_file;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> view;
  std::vector<std::wstring> pending;  // 페이지가 뜨기 전에 부른 스크립트
  bool loaded = false;
  bool dead = false;  // 컨트롤러가 만들어지기 전에 치웠다
  ULONGLONG retire_at = 0;
};

MediaLayer::MediaLayer(HWND parent, std::function<void(const std::wstring&)> on_state)
    : parent_(parent), on_state_(std::move(on_state)) {}

MediaLayer::~MediaLayer() {
  KillTimer(parent_, kTimerId);
  if (current_) Close(*current_);
  for (auto& slot : retiring_) Close(*slot);
}

const std::string& MediaLayer::current_key() const {
  static const std::string empty;
  return current_ ? current_->media.key : empty;
}

void MediaLayer::Update(const Media* media, double image_aspect) {
  if (current_ && media && media->key == current_->media.key) {
    LayoutSlot(*current_);
    return;
  }
  Retire();
  if (!media || media->key.empty()) return;
  image_aspect_ = image_aspect > 0 ? image_aspect : 16.0 / 9.0;

  auto slot = std::make_shared<Slot>();
  slot->media = *media;
  slot->html_file = TempDir() + L"\\m" + std::to_wstring(GetCurrentProcessId()) +
                    L"_" + std::to_wstring(++counter_) + L".html";
  {
    std::ofstream out(slot->html_file, std::ios::binary | std::ios::trunc);
    out << media->html;
    if (!out) return;
  }
  current_ = slot;
  if (env_) {
    CreateController(slot);
  } else {
    EnsureEnvironment();  // 다 만들어지면 그때의 current_ 를 띄운다
  }
}

void MediaLayer::EnsureEnvironment() {
  if (env_pending_ || env_failed_) return;
  env_pending_ = true;
  auto options = Make<CoreWebView2EnvironmentOptions>();
  // 클릭 없이 소리 있는 자동 재생 (Chromium 기본 정책은 막는다).
  options->put_AdditionalBrowserArguments(L"--autoplay-policy=no-user-gesture-required");
  const std::wstring data_dir = UserDataFolder();
  std::weak_ptr<int> alive = alive_;
  const HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, data_dir.empty() ? nullptr : data_dir.c_str(), options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this, alive](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
            if (alive.expired()) return S_OK;
            env_pending_ = false;
            if (FAILED(result) || !env) {
              env_failed_ = true;  // 런타임 없음 — 이번 발표 동안 다시 시도하지 않는다
              return S_OK;
            }
            env_ = env;
            if (current_) CreateController(current_);
            return S_OK;
          })
          .Get());
  if (FAILED(hr)) {
    env_pending_ = false;
    env_failed_ = true;
  }
}

void MediaLayer::CreateController(const std::shared_ptr<Slot>& slot) {
  std::weak_ptr<Slot> weak = slot;
  std::weak_ptr<int> alive = alive_;
  env_->CreateCoreWebView2Controller(
      parent_,
      Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
          [this, weak, alive](HRESULT result,
                              ICoreWebView2Controller* controller) -> HRESULT {
            auto s = weak.lock();
            if (alive.expired() || !s || s->dead || FAILED(result) || !controller) {
              if (controller) controller->Close();
              return S_OK;
            }
            s->controller = controller;
            controller->get_CoreWebView2(&s->view);
            ComPtr<ICoreWebView2_3> view3;
            if (!s->view || FAILED(s->view.As(&view3))) {
              Close(*s);
              return S_OK;
            }
            // ponytail: 불투명 검정. 투명(alpha 0)은 GDI 로 그린 부모 위에서 확실하지 않아서
            // 페이드 아웃이 슬라이드 대신 검정으로 빠진다. macOS 는 투명이라 겹쳐 넘어간다.
            ComPtr<ICoreWebView2Controller2> controller2;
            if (SUCCEEDED(controller->QueryInterface(IID_PPV_ARGS(&controller2)))) {
              controller2->put_DefaultBackgroundColor({255, 0, 0, 0});
            }
            ComPtr<ICoreWebView2Settings> settings;
            if (SUCCEEDED(s->view->get_Settings(&settings))) {
              settings->put_AreDefaultContextMenusEnabled(FALSE);
              settings->put_AreDevToolsEnabled(FALSE);
              settings->put_IsStatusBarEnabled(FALSE);
              settings->put_IsZoomControlEnabled(FALSE);
            }
            view3->SetVirtualHostNameToFolderMapping(
                kAppHost, TempDir().c_str(), COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
            if (!s->media.path.empty()) {
              view3->SetVirtualHostNameToFolderMapping(
                  kMediaHost, FolderOf(s->media.path).c_str(),
                  COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
            }
            EventRegistrationToken token{};
            s->view->add_NavigationCompleted(
                Callback<ICoreWebView2NavigationCompletedEventHandler>(
                    [weak](ICoreWebView2*,
                           ICoreWebView2NavigationCompletedEventArgs*) -> HRESULT {
                      auto loaded = weak.lock();
                      if (!loaded || !loaded->view) return S_OK;
                      loaded->loaded = true;
                      for (const auto& js : loaded->pending)
                        loaded->view->ExecuteScript(js.c_str(), nullptr);
                      loaded->pending.clear();
                      return S_OK;
                    })
                    .Get(),
                &token);
            // 페이드 아웃 중인 옛 레이어도 위치를 보내므로 지금 레이어 것만 넘긴다.
            s->view->add_WebMessageReceived(
                Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                    [this, weak, alive](ICoreWebView2*,
                                        ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                      auto sender = weak.lock();
                      if (alive.expired() || !sender || sender != current_ || !on_state_)
                        return S_OK;
                      LPWSTR text = nullptr;
                      if (SUCCEEDED(args->TryGetWebMessageAsString(&text)) && text) {
                        on_state_(text);
                      }
                      CoTaskMemFree(text);
                      return S_OK;
                    })
                    .Get(),
                &token);
            LayoutSlot(*s);
            controller->put_IsVisible(TRUE);
            const auto name = s->html_file.substr(s->html_file.find_last_of(L'\\') + 1);
            s->view->Navigate((std::wstring(L"https://") + kAppHost + L"/" + name).c_str());
            return S_OK;
          })
          .Get());
}

void MediaLayer::Retire() {
  if (!current_) return;
  auto slot = std::move(current_);
  current_.reset();
  if (!slot->controller || !slot->loaded) {
    slot->dead = true;  // 아직 안 떴으면 페이드할 것도 없다
    Close(*slot);
    return;
  }
  slot->view->ExecuteScript(L"window.fadeOut&&fadeOut()", nullptr);
  slot->retire_at = GetTickCount64() +
                    static_cast<ULONGLONG>(std::max(slot->media.fadeOut, 0.0) * 1000) + 200;
  retiring_.push_back(std::move(slot));
  SetTimer(parent_, kTimerId, 100, nullptr);
}

void MediaLayer::OnTimer() {
  const ULONGLONG now = GetTickCount64();
  retiring_.erase(std::remove_if(retiring_.begin(), retiring_.end(),
                                 [now](const std::shared_ptr<Slot>& s) {
                                   if (s->retire_at > now) return false;
                                   Close(*s);
                                   return true;
                                 }),
                  retiring_.end());
  if (retiring_.empty()) KillTimer(parent_, kTimerId);
}

void MediaLayer::Run(const std::wstring& script) {
  if (!current_) return;
  if (current_->loaded && current_->view) {
    current_->view->ExecuteScript(script.c_str(), nullptr);
  } else {
    current_->pending.push_back(script);
  }
}

void MediaLayer::Layout() {
  if (current_) LayoutSlot(*current_);
  for (auto& slot : retiring_) LayoutSlot(*slot);
}

void MediaLayer::LayoutSlot(Slot& slot) const {
  if (!slot.controller) return;
  RECT b;
  GetClientRect(parent_, &b);
  if (slot.media.kind == "audio") {
    // 소리만 — 한 점짜리. 숨기면(IsVisible=FALSE) 재생이 멈출 수 있다.
    b = {0, 0, 1, 1};
  } else if (slot.media.rect.size() == 4) {
    // PPT 안 동영상: 슬라이드 좌표(0~1)를 페이지 이미지 레터박스 안쪽으로 (PaintImage 와 같은 contain).
    const auto& r = slot.media.rect;
    const double w = b.right, h = b.bottom;
    const double sw = std::min(w, h * image_aspect_), sh = sw / image_aspect_;
    const double left = (w - sw) / 2, top = (h - sh) / 2;
    b.left = static_cast<LONG>(std::lround(left + r[0] * sw));
    b.top = static_cast<LONG>(std::lround(top + r[1] * sh));
    b.right = static_cast<LONG>(std::lround(left + (r[0] + r[2]) * sw));
    b.bottom = static_cast<LONG>(std::lround(top + (r[1] + r[3]) * sh));
  }
  slot.controller->put_Bounds(b);
}

void MediaLayer::Close(Slot& slot) {
  if (slot.controller) slot.controller->Close();
  slot.controller.Reset();
  slot.view.Reset();
  if (!slot.html_file.empty()) DeleteFileW(slot.html_file.c_str());
  slot.html_file.clear();
}
