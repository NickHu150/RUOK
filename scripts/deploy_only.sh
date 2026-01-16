#!/bin/bash

# ==============================================================================
# GoWell 纯部署脚本 (仅上传现有产物)
# ==============================================================================

# --- 配置信息 ---
R2_ACCOUNT_ID="fdc0457f6056cdba8886a914a216d921"
R2_BUCKET_NAME="gowell-app"
R2_ACCESS_KEY_ID="3eacfb5550e97121dec54209366421ac"
R2_SECRET_ACCESS_KEY="9888c590362852c5dbb2e44c350d7629138186bf667fb49deccdf3cdd7ff22fc"

# 环境变量与路径补全 (兼容 Homebrew)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# --- 路径修复逻辑 ---
# 自动定位项目根目录 (寻找 pubspec.yaml)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
PROJECT_NAME=$(basename "$PROJECT_ROOT")
cd "$PROJECT_ROOT" || exit 1

if [ ! -f "pubspec.yaml" ]; then
    echo "❌ 错误: 无法定位项目根目录 (未找到 pubspec.yaml)"
    exit 1
fi
echo "📍 当前工作目录: $(pwd)"

# --- 参数解析 ---
TARGET_PLATFORM=$(echo "$1" | tr '[:upper:]' '[:lower:]')
PLATFORM_DIR="all"
[ "$TARGET_PLATFORM" == "android" ] && PLATFORM_DIR="android"
[ "$TARGET_PLATFORM" == "ios" ] && PLATFORM_DIR="ios"

# 1. 基础检查
if ! command -v rclone &> /dev/null; then
    echo "❌ 错误: 未找到 rclone。如果已安装，请确认其在 PATH 中。"
    echo "💡 尝试运行: brew install rclone"
    exit 1
fi

# 2. 获取版本与生成目录
VERSION=$(grep 'version: ' pubspec.yaml | sed 's/version: //')
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
FOLDER_NAME="${VERSION}-${TIMESTAMP}"
DIST_DIR="dist_deploy/${FOLDER_NAME}"

echo "📦 部署版本: $VERSION"
echo "📂 远程目录: $FOLDER_NAME"

mkdir -p "$DIST_DIR"

# 3. 检测并收集产物
HAD_FILES=false

# --- Android ---
AAB_PATH="build/app/outputs/bundle/release/app-release.aab"
MAPPING_PATH="build/app/outputs/mapping/release/mapping.txt"

if [ -f "$AAB_PATH" ]; then
    echo "✅ 找到 Android AAB"
    cp "$AAB_PATH" "$DIST_DIR/"
    [ -f "$MAPPING_PATH" ] && cp "$MAPPING_PATH" "$DIST_DIR/"
    HAD_FILES=true
else
    echo "⚠️ 未找到 Android AAB ($AAB_PATH)"
fi

# --- iOS ---
IPA_PATH=$(find build/ios/ipa -name "*.ipa" | head -n 1)
PLIST_PATH="build/ios/ipa/ExportOptions.plist"

if [ -n "$IPA_PATH" ] && [ -f "$IPA_PATH" ]; then
    echo "✅ 找到 iOS IPA: $(basename "$IPA_PATH")"
    cp "$IPA_PATH" "$DIST_DIR/"
    [ -f "$PLIST_PATH" ] && cp "$PLIST_PATH" "$DIST_DIR/"
    HAD_FILES=true
else
    echo "⚠️ 未找到 iOS IPA"
fi

# --- dSYMs ---
DSYM_DIR=$(find build/ios/archive -name "dSYMs" -type d | head -n 1)
if [ -d "$DSYM_DIR" ]; then
    echo "✅ 找到 dSYMs，正在压缩..."
    zip -r "$DIST_DIR/dSYMs.zip" "$DSYM_DIR" > /dev/null
else
    echo "⚠️ 未找到 dSYMs 目录"
fi

# 4. 执行上传
if [ "$HAD_FILES" = true ]; then
    echo "☁️ 正在上传到 Cloudflare R2..."
    
    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    export RCLONE_CONFIG_R2_ACL=private

    rclone copy "$DIST_DIR" "R2:${R2_BUCKET_NAME}/${PROJECT_NAME}/${PLATFORM_DIR}/${FOLDER_NAME}" --progress
    
    echo "✅ 上传完成！"
    echo "🔗 目录名称: ${FOLDER_NAME}"
    echo "----------------------------------------------------------------"
    ls -lh "$DIST_DIR"
else
    echo "❌ 失败: 未检测到任何可部署的产物 (AAB 或 IPA)。"
    exit 1
fi
