#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "=== 1. Python 바이너리 빌드 ==="
if [ ! -x ".venv/bin/python" ]; then
  echo "  -> .venv not found. Creating it now."
  python3 -m venv .venv
fi

VENV_PYTHON="$(pwd)/.venv/bin/python"
"$VENV_PYTHON" -m pip install -q -r python/requirements.txt
rm -rf python/ppt_tool
"$VENV_PYTHON" -m PyInstaller --onefile python/ppt_tool.py \
                       --distpath python \
                       --workpath /tmp/ppt_tool_build \
                       --specpath /tmp/ppt_tool_build \
                       --name ppt_tool \
                       --add-data "$(pwd)/assets/fonts/Pretendard-Bold.ttf:fonts" \
                       --add-data "$(pwd)/assets/fonts/Pretendard-Regular.ttf:fonts"
echo "  → python/ppt_tool 생성 완료"

echo ""
echo "=== 2. Flutter macOS 릴리즈 빌드 ==="
flutter build macos --release
echo "  → build/macos/Build/Products/Release/Worship Slides.app 생성 완료"

echo ""
echo "=== 3. 배포 폴더 생성 ==="
DIST_DIR="dist/worship_slides"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/python"

cp -R "build/macos/Build/Products/Release/Worship Slides.app" "$DIST_DIR/"
cp python/ppt_tool "$DIST_DIR/python/"

cat > "$DIST_DIR/Unlock Worship Slides.command" <<'EOF'
#!/bin/bash
set -e

cd "$(dirname "$0")"

xattr -cr .
xattr -rd com.apple.quarantine . 2>/dev/null || true
xattr -rd com.apple.provenance . 2>/dev/null || true

echo "Worship Slides 잠금 해제를 완료했습니다."
echo "이제 앱을 더블클릭해서 실행하세요."
echo
read -n 1 -s -r -p "아무 키나 누르면 닫습니다..."
echo
EOF
chmod +x "$DIST_DIR/Unlock Worship Slides.command"
xattr -cr "$DIST_DIR"
xattr -rd com.apple.quarantine "$DIST_DIR" 2>/dev/null || true
xattr -rd com.apple.provenance "$DIST_DIR" 2>/dev/null || true

cat > "$DIST_DIR/처음 실행 안내.txt" <<'EOF'
macOS가 Unlock Worship Slides.command 실행을 막으면 아래 둘 중 하나로 실행하세요.

1. Unlock Worship Slides.command를 우클릭한 뒤 열기를 선택합니다.

2. 터미널에서 아래 명령을 실행합니다.
   cd "이 폴더 경로"
   xattr -cr .

그 다음 Worship Slides.app을 더블클릭하면 됩니다.
EOF

echo "  → $DIST_DIR 폴더 생성 완료"
echo ""
echo "배포 구조:"
find "$DIST_DIR" -maxdepth 2 | sort
