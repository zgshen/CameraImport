#!/bin/bash
# ============================================================
#  build_ipa.sh —— 自动找到 DerivedData 中的 .app 并打包 IPA
#  放在项目根目录，直接运行: bash build_ipa.sh
# ============================================================

set -e

# ============================================================
# 🔍  自动获取项目名（取当前目录名）
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME=$(basename "$PROJECT_DIR")
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║       .app  →  IPA  打包脚本         ║"
echo "╚══════════════════════════════════════╝"
echo "  项目名: $PROJECT_NAME"

# ============================================================
# 🔍  在 DerivedData 中匹配项目目录（项目名-随机后缀）
# ============================================================

MATCH_DIR=$(find "$DERIVED_DATA" -maxdepth 1 -type d -name "${PROJECT_NAME}-*" | head -1)

if [ -z "$MATCH_DIR" ]; then
    echo "❌ 在 DerivedData 中未找到项目: ${PROJECT_NAME}-*"
    echo "   请先在 Xcode 中 Build 一次"
    exit 1
fi

echo "  DerivedData: $MATCH_DIR"

# ============================================================
# 🔍  查找 .app 文件（优先 Release，其次 Debug）
# ============================================================

BUILD_PRODUCTS="$MATCH_DIR/Build/Products"

APP_PATH=$(find "$BUILD_PRODUCTS/Release-iphoneos" -maxdepth 1 -name "*.app" 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find "$BUILD_PRODUCTS/Debug-iphoneos" -maxdepth 1 -name "*.app" 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ]; then
    echo "❌ 未找到 .app 文件，请确认已编译 iOS 真机包（iphoneos）"
    echo "   查找路径: $BUILD_PRODUCTS"
    exit 1
fi

APP_NAME=$(basename "$APP_PATH" .app)
IPA_PATH="$PROJECT_DIR/$APP_NAME.ipa"

echo "  APP:    $APP_PATH"
echo "  输出:   $IPA_PATH"
echo ""

# ============================================================
# 📦  打包 IPA：创建 Payload 文件夹 → 放入 .app → zip → .ipa
# ============================================================

TMP_DIR=$(mktemp -d)
PAYLOAD_DIR="$TMP_DIR/Payload"

mkdir -p "$PAYLOAD_DIR"
cp -r "$APP_PATH" "$PAYLOAD_DIR/"

echo "📦 正在打包..."

cd "$TMP_DIR"
zip -qr "$IPA_PATH" Payload

rm -rf "$TMP_DIR"

# ============================================================
# 🎉  完成
# ============================================================

IPA_SIZE=$(du -sh "$IPA_PATH" | awk '{print $1}')
echo "✅ 打包完成！"
echo "   文件: $IPA_PATH"
echo "   大小: $IPA_SIZE"
