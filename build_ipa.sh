#!/bin/bash
# 编译 CameraImport 并打包为未签名 ipa（供 LiveContainer 等自行签名/管理的工具使用）
#
# 用法：
#   ./build_ipa.sh              # 默认 Release
#   CONFIGURATION=Debug ./build_ipa.sh
#   CLEAN=1 ./build_ipa.sh      # 清理后重新编译

set -euo pipefail

# ---------- 配置 ----------
PROJECT="CameraImport.xcodeproj"
SCHEME="CameraImport"
CONFIGURATION="${CONFIGURATION:-Release}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="$ROOT_DIR/build"
OUTPUT_DIR="$ROOT_DIR/output"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos"

cd "$ROOT_DIR"

# ---------- 检查 ----------
if [ ! -d "$PROJECT" ]; then
    echo "错误：在 $ROOT_DIR 下找不到 $PROJECT，请把脚本放到项目根目录再运行。" >&2
    exit 1
fi

if [ "${CLEAN:-0}" = "1" ]; then
    echo "==> 清理旧的构建产物"
    rm -rf "$DERIVED_DATA" "$OUTPUT_DIR"
fi

# 有 xcbeautify / xcpretty 就用它美化输出
if command -v xcbeautify >/dev/null 2>&1; then
    PRETTY=(xcbeautify)
elif command -v xcpretty >/dev/null 2>&1; then
    PRETTY=(xcpretty)
else
    PRETTY=(cat)
fi

# ---------- 编译（真机架构，不签名） ----------
echo "==> 开始编译：scheme=$SCHEME configuration=$CONFIGURATION"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_ENTITLEMENTS="" \
    build 2>&1 | "${PRETTY[@]}"

# ---------- 定位 .app ----------
APP_PATH="$(find "$PRODUCTS_DIR" -maxdepth 1 -name '*.app' -type d | head -n 1)"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "错误：在 $PRODUCTS_DIR 下没有找到 .app，编译可能失败。" >&2
    exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"
echo "==> 编译产物：$APP_PATH"

# ---------- 读取版本号，用于文件名 ----------
INFO_PLIST="$APP_PATH/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo "")"
BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || echo "")"

if [ -n "$VERSION" ]; then
    IPA_NAME="${APP_NAME}_${VERSION}${BUILD_NO:+_$BUILD_NO}.ipa"
else
    IPA_NAME="${APP_NAME}.ipa"
fi

# ---------- 打包 ipa ----------
echo "==> 打包 ipa"
mkdir -p "$OUTPUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Payload"
cp -R "$APP_PATH" "$TMP_DIR/Payload/"

IPA_PATH="$OUTPUT_DIR/$IPA_NAME"
rm -f "$IPA_PATH"

# -y 保留符号链接，-r 递归，-q 静默
(cd "$TMP_DIR" && zip -qry "$IPA_PATH" Payload)

echo
echo "==> 完成：$IPA_PATH"
ls -lh "$IPA_PATH"
