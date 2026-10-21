#!/bin/bash
# Heimdall Toolbox 빌드 스크립트 (macOS 전용)
# 실행: ./build.sh
# 결과: dist/Heimdall Toolbox.app  (adb, fastboot, heimdall, lz4 와 필요한 dylib 전부 포함)
set -euo pipefail

APP_NAME="Heimdall Toolbox"
EXEC_NAME="HeimdallToolbox"
BUNDLE_ID="local.heimdall.toolbox"
VERSION="1.0.0"
MIN_MACOS="13.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 네이티브 빌드(cmake/pkg-config/make)는 경로에 공백이 있으면 깨지므로 공백 없는 캐시 폴더에서 진행
WORK="$HOME/Library/Caches/heimdall-toolbox-build"
[[ "$WORK" == *" "* ]] && WORK="/tmp/heimdall-toolbox-build-$(id -u)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ARCH="$(uname -m)"

say()  { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✔ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✖ %s\033[0m\n" "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "이 스크립트는 macOS에서만 실행할 수 있습니다."

# ---------------------------------------------------------------- 1. 도구 확인
say "빌드 도구 확인"
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "Xcode Command Line Tools가 필요합니다. 설치 창을 띄웁니다…"
  xcode-select --install || true
  die "설치가 끝나면 ./build.sh 를 다시 실행하세요."
fi

if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$b" ]] && eval "$("$b" shellenv)" && break
  done
fi
command -v brew >/dev/null 2>&1 || die "Homebrew가 필요합니다: https://brew.sh 의 설치 명령을 실행한 뒤 다시 시도하세요."

say "빌드 의존성 설치 (cmake, pkg-config, libusb)"
brew list cmake      >/dev/null 2>&1 || brew install cmake
brew list pkg-config >/dev/null 2>&1 || brew list pkgconf >/dev/null 2>&1 || brew install pkg-config
brew list libusb     >/dev/null 2>&1 || brew install libusb
ok "의존성 준비 완료"

mkdir -p "$WORK" "$DIST"

# ---------------------------------------------------------------- 2. platform-tools (adb/fastboot)
say "Android platform-tools 다운로드 (adb, fastboot)"
PT_ZIP="$WORK/platform-tools-darwin.zip"
if [[ ! -x "$WORK/platform-tools/adb" ]]; then
  curl -fL --retry 3 -o "$PT_ZIP" "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
  rm -rf "$WORK/platform-tools"
  unzip -q -o "$PT_ZIP" -d "$WORK"
fi
"$WORK/platform-tools/adb" version | head -2
ok "platform-tools 준비 완료"

# ---------------------------------------------------------------- 3. Heimdall 빌드
say "Heimdall 소스 받기 (Henrik Grimler 유지보수 포크 → 실패 시 원본)"
HSRC="$WORK/Heimdall"
if [[ ! -f "$HSRC/CMakeLists.txt" ]]; then
  rm -rf "$HSRC"
  git clone --depth 1 https://git.sr.ht/~grimler/Heimdall "$HSRC" \
    || git clone --depth 1 https://github.com/Benjamin-Dobell/Heimdall.git "$HSRC" \
    || die "Heimdall 소스를 받지 못했습니다. 네트워크를 확인하세요."
fi

say "Heimdall 빌드 (CLI만, libusb 정적 링크)"
BREW_PREFIX="$(brew --prefix)"
LIBUSB_PREFIX="$(brew --prefix libusb)"
[[ -f "$LIBUSB_PREFIX/lib/libusb-1.0.a" ]] || die "libusb 정적 라이브러리(libusb-1.0.a)가 없습니다: brew reinstall libusb"

# 정적 라이브러리만 있는 전용 prefix를 만들어 CMake/pkg-config가 dylib 대신 .a를 쓰게 함
USBP="$WORK/libusb-static"
rm -rf "$USBP"; mkdir -p "$USBP/lib/pkgconfig" "$USBP/include"
cp "$LIBUSB_PREFIX/lib/libusb-1.0.a" "$USBP/lib/"
cp -R "$LIBUSB_PREFIX/include/libusb-1.0" "$USBP/include/"
USB_FRAMEWORKS="-framework IOKit -framework CoreFoundation -framework Security -lobjc"
cat > "$USBP/lib/pkgconfig/libusb-1.0.pc" <<PC
prefix=$USBP
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libusb-1.0
Description: libusb (static)
Version: 1.0
Libs: \${libdir}/libusb-1.0.a $USB_FRAMEWORKS
Cflags: -I\${includedir}/libusb-1.0
PC
export PKG_CONFIG_PATH="$USBP/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$USBP/lib/pkgconfig"

rm -rf "$HSRC/build"
cmake -S "$HSRC" -B "$HSRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DDISABLE_FRONTEND=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
  -DCMAKE_PREFIX_PATH="$USBP" \
  -DCMAKE_EXE_LINKER_FLAGS="$USB_FRAMEWORKS" >/dev/null
cmake --build "$HSRC/build" -j"$(sysctl -n hw.ncpu)"
unset PKG_CONFIG_LIBDIR
HEIMDALL_BIN="$(find "$HSRC/build" -type f -name heimdall -perm -u+x | head -1)"
[[ -n "$HEIMDALL_BIN" ]] || die "heimdall 바이너리를 찾지 못했습니다."
if otool -L "$HEIMDALL_BIN" | grep -q libusb; then
  echo "  ⚠ 정적 링크가 적용되지 않아 libusb dylib을 번들에 포함합니다."
else
  ok "libusb 정적 링크 확인"
fi
"$HEIMDALL_BIN" version
ok "Heimdall 빌드 완료"

say "lz4 빌드 (정적, 외부 라이브러리 없음)"
LZ4SRC="$WORK/lz4"
[[ -f "$LZ4SRC/Makefile" ]] || git clone --depth 1 https://github.com/lz4/lz4.git "$LZ4SRC"
make -C "$LZ4SRC/programs" clean >/dev/null 2>&1 || true
MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" make -C "$LZ4SRC/programs" lz4 -j"$(sysctl -n hw.ncpu)" >/dev/null
LZ4_BIN="$LZ4SRC/programs/lz4"
"$LZ4_BIN" -V
ok "lz4 빌드 완료"

# ---------------------------------------------------------------- 4. Swift 앱 컴파일
say "앱 컴파일 (SwiftUI, $ARCH)"
swiftc -O -parse-as-library -swift-version 5 \
  -target "$ARCH-apple-macos$MIN_MACOS" \
  -o "$WORK/$EXEC_NAME" "$ROOT/Sources/App.swift"
ok "컴파일 완료"

# ---------------------------------------------------------------- 5. .app 조립
say ".app 번들 조립"
rm -rf "$APP"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/Resources/bin"
LIB="$CONTENTS/Resources/lib"
mkdir -p "$CONTENTS/MacOS" "$BIN" "$LIB"

cp "$WORK/$EXEC_NAME" "$CONTENTS/MacOS/$EXEC_NAME"
cp -R "$WORK/platform-tools/." "$BIN/"           # adb, fastboot, 기타 platform-tools 전체
cp "$HEIMDALL_BIN" "$BIN/heimdall"
cp "$LZ4_BIN" "$BIN/lz4"
chmod +x "$BIN/heimdall" "$BIN/lz4"

# Homebrew dylib을 번들 안으로 복사하고 경로를 @executable_path/../lib 로 바꿈
is_external() { [[ "$1" == /opt/homebrew/* || "$1" == /usr/local/* || "$1" == @rpath/* ]]; }

resolve_dep() {   # @rpath/xxx.dylib → 실제 경로
  local dep="$1"
  if [[ "$dep" == @rpath/* ]]; then
    local name="${dep#@rpath/}"
    for d in "$BREW_PREFIX/lib" "$BREW_PREFIX"/opt/*/lib; do
      [[ -f "$d/$name" ]] && { echo "$d/$name"; return; }
    done
    echo ""
  else
    echo "$dep"
  fi
}

bundle_deps() {   # $1 = 대상 Mach-O, $2 = 대상에서 lib 폴더까지의 상대 경로 접두사
  local target="$1" prefix="$2"
  local deps
  deps="$(otool -L "$target" | tail -n +2 | awk '{print $1}')"
  for dep in $deps; do
    is_external "$dep" || continue
    local real; real="$(resolve_dep "$dep")"
    [[ -n "$real" && -f "$real" ]] || { echo "  ⚠ 의존성 경로 확인 실패: $dep"; continue; }
    local name; name="$(basename "$real")"
    [[ "$(basename "$target")" == "$name" ]] && continue
    if [[ ! -f "$LIB/$name" ]]; then
      cp -L "$real" "$LIB/$name"
      chmod u+w "$LIB/$name"
      install_name_tool -id "@loader_path/$name" "$LIB/$name" 2>/dev/null || true
      bundle_deps "$LIB/$name" "@loader_path"
    fi
    install_name_tool -change "$dep" "$prefix/$name" "$target" 2>/dev/null || true
  done
}

for t in "$BIN/heimdall" "$BIN/lz4"; do
  chmod u+w "$t"
  if otool -L "$t" | tail -n +2 | awk '{print $1}' | while read -r d; do is_external "$d" && echo x; done | grep -q x; then
    bundle_deps "$t" "@executable_path/../lib"
  fi
done
if [[ -z "$(ls -A "$LIB")" ]]; then rmdir "$LIB"; else ls "$LIB" | sed 's/^/  포함된 라이브러리: /'; fi

# 아이콘
if [[ -f "$ROOT/Resources/icon.png" ]]; then
  ICONSET="$WORK/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/Resources/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/Resources/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------- 6. 서명 + 검증
say "애드혹 서명"
xattr -cr "$APP"
# 내부 바이너리/라이브러리 먼저, 그다음 앱 전체
find "$CONTENTS/Resources" -type f \( -name "*.dylib" -o -perm -u+x \) | while read -r f; do
  file "$f" | grep -q "Mach-O" && codesign --force --sign - "$f" 2>/dev/null || true
done
codesign --force --sign - "$APP"
codesign --verify --deep "$APP" && ok "서명 확인 완료"

say "번들 안 도구 동작 확인"
"$BIN/adb" version | head -1
"$BIN/fastboot" --version | head -1
"$BIN/heimdall" version
"$BIN/lz4" -V
echo "  외부 의존성 검사:"
if otool -L "$BIN/heimdall" "$BIN/lz4" 2>/dev/null | grep -E "/opt/homebrew|/usr/local" ; then
  die "번들 밖 라이브러리를 참조하는 항목이 남아 있습니다."
else
  ok "Homebrew 경로 참조 없음 — 다른 맥에서도 그대로 실행 가능"
fi

# ---------------------------------------------------------------- 7. 배포용 zip
say "배포용 압축"
( cd "$DIST" && rm -f "$EXEC_NAME-$ARCH.zip" && ditto -c -k --keepParent "$APP_NAME.app" "$EXEC_NAME-$ARCH.zip" )

printf "\n\033[1;32m완료!\033[0m\n  앱: %s\n  zip: %s\n\n" "$APP" "$DIST/$EXEC_NAME-$ARCH.zip"
echo "응용 프로그램 폴더로 옮기려면:  cp -R \"$APP\" /Applications/"
open -R "$APP" 2>/dev/null || true
