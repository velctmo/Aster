#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SING_BOX_VERSION="${SING_BOX_VERSION:-1.14.0}"
if [[ "$SING_BOX_VERSION" != "1.14.0" && -z "${SING_BOX_BINARY_SHA256:-}" ]]; then
  echo "错误: 非默认 sing-box 版本必须同时提供 SING_BOX_BINARY_SHA256" >&2
  exit 1
fi
SING_BOX_BINARY_SHA256="${SING_BOX_BINARY_SHA256:-973388c3f720e918fc64dff7fd75dde14b31cc1aa6fc15855e2f00c5291dd4f4}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) SB_ARCH="arm64" ;;
  *) echo "Aster 仅支持 Apple Silicon (arm64)，当前架构: $ARCH"; exit 1 ;;
esac

echo "=================================================="
echo "▶ 正在打包 Aster 纯原生 macOS 桌面应用程序..."
echo "=================================================="

mkdir -p bin build vendor/cores vendor/rules

echo "  [1/5] 编译 Aster Core Daemon (Go)..."
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/aster-daemon ./cmd/aster-daemon
chmod +x bin/aster-daemon
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/aster-helper ./cmd/aster-helper
chmod +x bin/aster-helper

SWIFT_SOURCES=(
  macos-native/Sources/Aster/Models.swift
  macos-native/Sources/Aster/RealtimeStores.swift
  macos-native/Sources/Aster/WebDAVCredentialStore.swift
  macos-native/Sources/Aster/AsterAPI.swift
  macos-native/Sources/Aster/UIComponents.swift
  macos-native/Sources/Aster/InspectorWindow.swift
  macos-native/Sources/Aster/AddRuleModalView.swift
  macos-native/Sources/Aster/Views.swift
  macos-native/Sources/Aster/ViewsMain.swift
  macos-native/Sources/Aster/ViewsActivity.swift
  macos-native/Sources/Aster/ViewsOverview.swift
  macos-native/Sources/Aster/ViewsOutbounds.swift
  macos-native/Sources/Aster/ViewsProfiles.swift
  macos-native/Sources/Aster/ViewsScripts.swift
  macos-native/Sources/Aster/ViewsRules.swift
  macos-native/Sources/Aster/ViewsSettings.swift
  macos-native/Sources/Aster/PreviewFixtures.swift
  macos-native/Sources/Aster/AsterApp.swift
)

echo "  [2/5] 编译 Aster SwiftUI 客户端..."
SWIFT_BUILT=0
# xcodebuild 存在于 Command Line Tools，但没有完整 Xcode 时会直接失败；失败则回退 swiftc
if [[ -d macos-native/Aster.xcodeproj ]] && command -v xcodebuild >/dev/null 2>&1 \
  && xcodebuild -version >/dev/null 2>&1; then
  if xcodebuild -project macos-native/Aster.xcodeproj -scheme Aster -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build >/dev/null 2>&1; then
    BUILT_APP=$(find build/DerivedData -name 'Aster.app' -type d | head -1 || true)
    if [[ -n "${BUILT_APP:-}" ]]; then
      cp "$BUILT_APP/Contents/MacOS/Aster" bin/Aster
      SWIFT_BUILT=1
    fi
  fi
fi
if [[ "$SWIFT_BUILT" -ne 1 ]]; then
  echo "  使用 swiftc 编译（无可用 Xcode / xcodebuild 失败）..."
  mkdir -p build/ModuleCache
  SWIFT_VER="6"
  if ! swiftc --version 2>&1 | grep -Eq 'Swift version [6-9]'; then
    SWIFT_VER="5"
  fi
  swiftc -module-cache-path "$(pwd)/build/ModuleCache" -Xcc -fmodules-cache-path="$(pwd)/build/ModuleCache" -swift-version "$SWIFT_VER" -parse-as-library -O "${SWIFT_SOURCES[@]}" -o bin/Aster
fi
chmod +x bin/Aster
rm -rf build/ModuleCache

ensure_singbox() {
  local dest="vendor/cores/sing-box-${SING_BOX_VERSION}-darwin-${SB_ARCH}"
  if [[ -x "$dest" ]]; then
	if ! file "$dest" | grep -Eq 'arm64|arm 64'; then
	  echo "错误: 缓存内核不是 Apple Silicon 可执行文件: $dest" >&2
	  return 1
	fi
	verify_core "$dest"
    echo "$dest"
    return
  fi
  local asset="sing-box-${SING_BOX_VERSION}-darwin-${SB_ARCH}.tar.gz"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${asset}"
  local tmp
  tmp="$(mktemp -d)"
  echo "  下载 sing-box ${SING_BOX_VERSION} (${SB_ARCH})..." >&2
  if ! curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$tmp/$asset"; then
    rm -rf "$tmp"
    echo "错误: 无法下载 sing-box，拒绝生成缺少核心的应用包" >&2
    return 1
  fi
  tar -xzf "$tmp/$asset" -C "$tmp"
  local binpath
  binpath="$(find "$tmp" -type f -name sing-box | head -1)"
  if [[ -z "$binpath" ]]; then
    rm -rf "$tmp"
    echo "错误: sing-box 压缩包内没有可执行文件" >&2
    return 1
  fi
  if ! file "$binpath" | grep -Eq 'arm64|arm 64'; then
    rm -rf "$tmp"
    echo "错误: 下载的 sing-box 不是 Apple Silicon 可执行文件" >&2
    return 1
  fi
  cp "$binpath" "$dest"
  chmod +x "$dest"
  verify_core "$dest"
  rm -rf "$tmp"
  echo "$dest"
}

verify_core() {
  local path="$1"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$SING_BOX_BINARY_SHA256" ]]; then
    echo "错误: sing-box SHA-256 校验失败: $path" >&2
    return 1
  fi
}

echo "  [3/5] 准备可复现 sing-box 内核..."
CORE_BIN="$(ensure_singbox)"

echo "  [4/5] 组装 Aster.app..."
APP_DIR="build/Aster.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp bin/Aster "$APP_DIR/Contents/MacOS/Aster"
cp bin/aster-daemon "$APP_DIR/Contents/Resources/aster-daemon"

if [[ -f "assets/Aster.icns" ]]; then
  cp assets/Aster.icns "$APP_DIR/Contents/Resources/Aster.icns"
fi

cp "$CORE_BIN" "$APP_DIR/Contents/Resources/sing-box"
chmod +x "$APP_DIR/Contents/Resources/sing-box"

if [[ -d vendor/rules ]] && compgen -G "vendor/rules/*" >/dev/null; then
  mkdir -p "$APP_DIR/Contents/Resources/rules"
  cp -R vendor/rules/. "$APP_DIR/Contents/Resources/rules/"
fi

cat > "$APP_DIR/Contents/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>Aster</string>
    <key>CFBundleIconFile</key>
    <string>Aster</string>
    <key>CFBundleIdentifier</key>
    <string>app.aster</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Aster</string>
    <key>CFBundleDisplayName</key>
    <string>Aster</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 NoSugar Studio. All rights reserved.</string>
</dict>
</plist>
PLISTEOF

echo "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "  [5/5] ad-hoc 代码签名..."
xattr -cr "$APP_DIR" || true
codesign --force --deep -i app.aster --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ZIP_OUT="build/Aster-macos-${SB_ARCH}.zip"
rm -f "$ZIP_OUT"
(cd build && zip -qr "Aster-macos-${SB_ARCH}.zip" Aster.app)

echo "=================================================="
echo "✓ Aster 打包成功"
echo "  应用: $APP_DIR"
echo "  压缩包: $ZIP_OUT"
echo "  启动: open $APP_DIR"
echo "  Gatekeeper: 若无法打开，请右键 → 打开"
echo "=================================================="
