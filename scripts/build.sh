#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "=== 1. Python 바이너리 빌드 ==="
if [ ! -x ".venv/bin/python" ]; then
  echo "  -> .venv not found. Creating it now."
  python3 -m venv .venv
fi

source .venv/bin/activate
pip install -q -r python/requirements.txt
rm -rf python/ppt_tool
pyinstaller --onefile python/ppt_tool.py \
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
cp python/ppt_tool.py "$DIST_DIR/python/"
cp python/requirements.txt "$DIST_DIR/python/"

cat > "$DIST_DIR/Unlock Worship Slides.command" <<'EOF'
#!/bin/bash
set -e

cd "$(dirname "$0")"

xattr -cr "Worship Slides.app"

echo "Worship Slides.app 잠금 해제를 완료했습니다."
echo "이제 앱을 더블클릭해서 실행하세요."
echo
read -n 1 -s -r -p "아무 키나 누르면 닫습니다..."
echo
EOF
chmod +x "$DIST_DIR/Unlock Worship Slides.command"

echo "  → $DIST_DIR 폴더 생성 완료"
echo ""
echo "배포 구조:"
find "$DIST_DIR" -maxdepth 2 | sort
