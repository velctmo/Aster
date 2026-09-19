#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

./scripts/build_aster_mac.sh
GIT_BUILD_NUMBER="$(git show -s --format=%ct HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
ASTER_BUILD_VERSION="${ASTER_BUILD_VERSION:-$GIT_BUILD_NUMBER}"
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/aster-helper ./cmd/aster-helper
chmod +x bin/aster-helper packaging/scripts/preinstall packaging/scripts/postinstall

STAGE="build/pkg-root"
SCRIPTS_STAGE="build/pkg-scripts"
rm -rf "$STAGE"
rm -rf "$SCRIPTS_STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/Library/Application Support/Aster/cores" "$STAGE/Library/LaunchDaemons"
mkdir -p "$SCRIPTS_STAGE"
# ditto --norsrc prevents resource-fork / AppleDouble entries from leaking
# into the installer payload on APFS volumes.
ditto --norsrc build/Aster.app "$STAGE/Applications/Aster.app"
cp bin/aster-helper "$STAGE/Library/Application Support/Aster/aster-helper"
cp build/Aster.app/Contents/Resources/sing-box "$STAGE/Library/Application Support/Aster/cores/sing-box"
cp packaging/app.aster.helper.plist "$STAGE/Library/LaunchDaemons/app.aster.helper.plist"
cp packaging/scripts/preinstall "$SCRIPTS_STAGE/preinstall"
cp packaging/scripts/postinstall "$SCRIPTS_STAGE/postinstall"
chmod 755 "$STAGE/Applications/Aster.app/Contents/Resources/sing-box"
chmod 755 "$STAGE/Library/Application Support/Aster/cores/sing-box"
# Do this only in generated staging directories. macOS provenance xattrs would
# otherwise make pkgbuild emit AppleDouble `._*` payload and script entries.
xattr -cr "$STAGE" "$SCRIPTS_STAGE"
xattr -dr com.apple.provenance "$STAGE" "$SCRIPTS_STAGE" 2>/dev/null || true
find "$STAGE" -name '._*' -type f -delete
find "$SCRIPTS_STAGE" -name '._*' -type f -delete

pkgbuild --root "$STAGE" --scripts "$SCRIPTS_STAGE" --component-plist packaging/component.plist \
  --identifier app.aster --version "$ASTER_BUILD_VERSION" --install-location / build/Aster.pkg
if pkgutil --payload-files build/Aster.pkg | grep -Eq '(^|/)\._'; then
  echo "错误: PKG payload contains AppleDouble files" >&2
  exit 1
fi
cp -f build/Aster.pkg build/Aster-unsigned.pkg
echo "PKG: build/Aster.pkg"
echo "首次安装将请求一次管理员权限；未签名开源构建可能需要在系统设置中确认。"
