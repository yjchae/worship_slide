#pragma once

#include <windows.h>

#include <algorithm>
#include <string>

// 전체화면 창이 쓰던 모니터를 해상도가 바뀐 뒤에도 다시 찾는다.
// 프로젝터는 연결 직후 해상도를 다시 잡는 일이 흔한데, 그러면 창이 옛 크기로 남아 화면 밖으로
// 넘친다(가사가 구석에 걸쳐 보였다). HMONITOR 는 화면 설정이 바뀌면 달라질 수 있어 장치 이름으로 찾는다.

// 모니터 장치 이름(\\.\DISPLAY2). 못 읽으면 빈 문자열.
inline std::wstring MonitorDevice(HMONITOR mon) {
  MONITORINFOEXW info = {};
  info.cbSize = sizeof(info);
  return mon && GetMonitorInfoW(mon, &info) ? std::wstring(info.szDevice) : std::wstring();
}

// 장치 이름이 device 인 모니터의 지금 영역. 모니터가 빠졌으면 false.
inline bool FindMonitorRect(const std::wstring& device, RECT* out) {
  struct Query { const std::wstring* device; RECT* out; bool found; };
  Query q = {&device, out, false};
  EnumDisplayMonitors(nullptr, nullptr,
    [](HMONITOR mon, HDC, LPRECT, LPARAM lp) -> BOOL {
      auto* q = reinterpret_cast<Query*>(lp);
      MONITORINFOEXW info = {};
      info.cbSize = sizeof(info);
      if (GetMonitorInfoW(mon, &info) && *q->device == info.szDevice) {
        *q->out = info.rcMonitor;
        q->found = true;
        return FALSE;
      }
      return TRUE;
    }, reinterpret_cast<LPARAM>(&q));
  return q.found;
}

// 전체화면 창을 장치 이름이 device 인 모니터의 지금 크기로. 모니터가 (잠깐) 없으면 그대로 둔다 —
// 프로젝터는 해상도를 다시 잡으며 잠깐 빠졌다 돌아오는 일이 흔하고, 돌아오면 다음 WM_DISPLAYCHANGE 에서 맞춘다.
// 크기가 그대로면 건드리지 않는다(미디어 레이어 깜빡임).
inline void RefitToDevice(HWND hwnd, const std::wstring& device, HWND insert_after, UINT flags) {
  RECT r, now;
  if (!hwnd || device.empty() || !FindMonitorRect(device, &r)) return;
  GetWindowRect(hwnd, &now);
  if (EqualRect(&now, &r)) return;
  SetWindowPos(hwnd, insert_after, r.left, r.top, r.right - r.left, r.bottom - r.top,
               flags | SWP_NOACTIVATE);
}

// 기준 모니터 작업 영역 가운데에 w x h(작업 영역보다 크면 줄인다) 일반 창 자리.
inline RECT CenteredRect(HMONITOR mon, int w, int h) {
  MONITORINFO info = {sizeof(info)};
  GetMonitorInfo(mon, &info);
  const RECT& a = info.rcWork;
  w = (std::min)(w, static_cast<int>(a.right - a.left));
  h = (std::min)(h, static_cast<int>(a.bottom - a.top));
  const LONG x = a.left + (a.right - a.left - w) / 2;
  const LONG y = a.top + (a.bottom - a.top - h) / 2;
  return {x, y, x + w, y + h};
}
