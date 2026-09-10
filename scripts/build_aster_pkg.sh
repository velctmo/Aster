#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

./scripts/build_aster_mac.sh
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/aster-helper ./cmd/aster-helper
chmod +x bin/aster-helper packaging/scripts/postinstall

STAGE="build/pkg-root"
SCRIPTS_STAGE="build/pkg-scripts"
rm -rf "$STAGE"
rm -rf "$SCRIPTS_STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/Library/Application Support/Aster" "$STAGE/Library/LaunchDaemons"
mkdir -p "$SCRIPTS_STAGE"
cp -R build/Aster.app "$STAGE/Applications/Aster.app"
cp bin/aster-helper "$STAGE/Library/Application Support/Aster/aster-helper"
cp packaging/app.aster.helper.plist "$STAGE/Library/LaunchDaemons/app.aster.helper.plist"
cp packaging/scripts/postinstall "$SCRIPTS_STAGE/postinstall"
chmod 755 "$STAGE/Applications/Aster.app/Contents/Resources/sing-box"
# Do this only in generated staging directories. macOS provenance xattrs would
# otherwise make pkgbuild emit AppleDouble `._*` payload and script entries.
xattr -cr "$STAGE" "$SCRIPTS_STAGE"
xattr -dr com.apple.provenance "$STAGE" "$SCRIPTS_STAGE" 2>/dev/null || true
find "$STAGE" -name '._*' -type f -delete
find "$SCRIPTS_STAGE" -name '._*' -type f -delete

pkgbuild --root "$STAGE" --scripts "$SCRIPTS_STAGE" --identifier app.aster --version 1.0.0 --install-location / build/Aster.pkg
cp -f build/Aster.pkg build/Aster-unsigned.pkg
echo "PKG: build/Aster.pkg"
echo "首次安装将请求一次管理员权限；未签名开源构建可能需要在系统设置中确认。"
