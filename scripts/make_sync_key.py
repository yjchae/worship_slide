#!/usr/bin/env python3
"""찬양·콘티 동기화 접속 키 만들기 (관리자가 한 번만 실행).

준비 (Google Cloud 콘솔, https://console.cloud.google.com):
  1. 프로젝트를 만들고 'API 및 서비스 → 라이브러리'에서 Google Drive API 사용
  2. 'OAuth 동의 화면': 외부 → 앱 이름만 넣고 저장 → '앱 게시'(프로덕션)
     (테스트 상태로 두면 7일마다 키가 만료된다. drive.file 권한만 쓰므로 검증 심사는 필요 없다)
  3. '사용자 인증 정보 → OAuth 클라이언트 ID → 데스크톱 앱' → JSON 다운로드

실행:
  python3 scripts/make_sync_key.py <다운로드한 client_secret_….json> [폴더 이름]

브라우저에서 동기화 파일을 맡을 구글 계정으로 로그인하면 그 계정 드라이브에 동기화 폴더를 만들고
`WS1-…` 접속 키를 출력한다. 이 키를 쓸 사람들에게만 따로 건네고, git 에는 올리지 않는다.
키를 끊으려면 https://myaccount.google.com/permissions 에서 이 앱의 접근을 없앤다
(그러면 모든 PC 가 막히니 새 키를 만들어 다시 건넨다).
"""

import base64
import http.server
import json
import secrets
import sys
import urllib.parse
import urllib.request
import webbrowser

SCOPE = "https://www.googleapis.com/auth/drive.file"


def post(url, data, token=None, as_json=False):
    body = json.dumps(data).encode() if as_json else urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json" if as_json else "application/x-www-form-urlencoded")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req) as res:
        return json.load(res)


def login(client_id, client_secret):
    """루프백으로 로그인 코드를 받아 refresh token 으로 바꾼다."""
    state = secrets.token_urlsafe(16)
    got = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if q.get("state", [""])[0] == state:
                got.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write("로그인 완료. 이 창을 닫고 터미널로 돌아가세요.".encode())

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    redirect = f"http://127.0.0.1:{server.server_port}"
    url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect,
        "response_type": "code",
        "scope": SCOPE,
        "access_type": "offline",
        "prompt": "consent",  # 다시 실행해도 refresh token 을 새로 받는다
        "state": state,
    })
    print("브라우저에서 로그인하세요. 안 열리면 이 주소를 여세요:\n" + url + "\n")
    webbrowser.open(url)
    while "code" not in got and "error" not in got:
        server.handle_request()
    if "error" in got:
        sys.exit(f"로그인 실패: {got['error']}")
    tokens = post("https://oauth2.googleapis.com/token", {
        "code": got["code"],
        "client_id": client_id,
        "client_secret": client_secret,
        "redirect_uri": redirect,
        "grant_type": "authorization_code",
    })
    if "refresh_token" not in tokens:
        sys.exit(f"refresh token 을 받지 못했습니다: {tokens}")
    return tokens


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as f:
        client = json.load(f)
    client = client.get("installed") or client.get("web") or client
    folder_name = sys.argv[2] if len(sys.argv) > 2 else "worship_slides_sync"

    tokens = login(client["client_id"], client["client_secret"])
    # drive.file 은 이 앱이 만든 파일만 보므로 폴더도 여기서 만든다(손으로 만든 폴더는 앱이 못 본다).
    folder = post(
        "https://www.googleapis.com/drive/v3/files",
        {"name": folder_name, "mimeType": "application/vnd.google-apps.folder"},
        token=tokens["access_token"],
        as_json=True,
    )
    key = {
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "refresh_token": tokens["refresh_token"],
        "folder_id": folder["id"],
        "folder_name": folder_name,
    }
    encoded = base64.urlsafe_b64encode(json.dumps(key).encode()).decode().rstrip("=")
    print(f"드라이브에 '{folder_name}' 폴더를 만들었습니다. 아래 접속 키를 쓸 사람들에게만 건네세요:\n")
    print("WS1-" + encoded)


if __name__ == "__main__":
    main()
