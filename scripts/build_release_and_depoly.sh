#!/bin/bash

# ==============================================================================
# GoWell 自动化构建与分发脚本 (强制重新编译版)
# ==============================================================================

# --- 1. 配置信息 ---
R2_ACCOUNT_ID="fdc0457f6056cdba8886a914a216d921"
R2_BUCKET_NAME="gowell-app"
R2_ACCESS_KEY_ID="3eacfb5550e97121dec54209366421ac"
R2_SECRET_ACCESS_KEY="9888c590362852c5dbb2e44c350d7629138186bf667fb49deccdf3cdd7ff22fc"

# 环境变量与路径补全
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# --- 2. 路径修复：自动定位项目根目录 ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
PROJECT_NAME=$(basename "$PROJECT_ROOT")
cd "$PROJECT_ROOT" || exit 1

if [ ! -f "pubspec.yaml" ]; then
    echo "❌ 错误: 无法定位项目根目录 (未找到 pubspec.yaml)"
    exit 1
fi
echo "📍 当前工作目录: $(pwd)"

# --- 3. 获取目标平台 ---
TARGET_PLATFORM=$(echo "$1" | tr '[:upper:]' '[:lower:]')

if [ -n "$TARGET_PLATFORM" ] && [ "$TARGET_PLATFORM" != "android" ] && [ "$TARGET_PLATFORM" != "ios" ]; then
    echo "❌ 错误: 无效的平台 '$TARGET_PLATFORM'。请使用 'android', 'ios' 或不传参数（双端）。"
    exit 1
fi

# 环境检查
if ! command -v rclone &> /dev/null; then
    echo "❌ 错误: 未找到 rclone。"
    echo "💡 请运行此命令安装: sudo -v ; curl https://rclone.org/install.sh | sudo bash"
    exit 1
fi

# 获取版本号
VERSION=$(grep 'version: ' pubspec.yaml | sed 's/version: //')
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
FOLDER_NAME="${VERSION}-${TIMESTAMP}"
DIST_DIR="dist/${FOLDER_NAME}"

PLATFORM_DESC="双端"
PLATFORM_DIR="all"
if [ "$TARGET_PLATFORM" == "android" ]; then
    PLATFORM_DESC="Android"
    PLATFORM_DIR="android"
elif [ "$TARGET_PLATFORM" == "ios" ]; then
    PLATFORM_DESC="iOS"
    PLATFORM_DIR="ios"
fi

echo "🚀 开始构建 [$PLATFORM_DESC] 版本: $VERSION ..."
mkdir -p "$DIST_DIR"

# --- 4. 编译过程 ---
echo "🧹 清理并获取依赖..."
flutter clean && flutter pub get

# Android 编译
if [ -z "$TARGET_PLATFORM" ] || [ "$TARGET_PLATFORM" == "android" ]; then
    echo "🤖 编译 Android AAB..."
    flutter build appbundle --release
    
    echo "📂 收集 Android 产物..."
    if [ -f "build/app/outputs/bundle/release/app-release.aab" ]; then
        cp build/app/outputs/bundle/release/app-release.aab "$DIST_DIR/"
        [ -f "build/app/outputs/mapping/release/mapping.txt" ] && cp build/app/outputs/mapping/release/mapping.txt "$DIST_DIR/"
        echo "✅ Android 产物收集完成"
    else
        echo "⚠️ 警告: 未找到 Android AAB 产物"
    fi
fi

# iOS 编译
if [ -z "$TARGET_PLATFORM" ] || [ "$TARGET_PLATFORM" == "ios" ]; then
    echo "🍎 编译 iOS IPA..."
    flutter build ipa --release
    
    echo "📂 收集 iOS 产物..."
    IPA_FILE=$(find build/ios/ipa -name "*.ipa" | head -n 1)
    if [ -n "$IPA_FILE" ]; then
        cp "$IPA_FILE" "$DIST_DIR/"
        [ -f "build/ios/ipa/ExportOptions.plist" ] && cp build/ios/ipa/ExportOptions.plist "$DIST_DIR/"
        
        # dSYMs 压缩
        DSYM_DIR=$(find build/ios/archive -name "dSYMs" -type d | head -n 1)
        if [ -d "$DSYM_DIR" ]; then
            zip -r "$DIST_DIR/dSYMs.zip" "$DSYM_DIR" > /dev/null
            echo "✅ dSYMs 压缩成功"
        fi
        echo "✅ iOS 产物收集完成"
    else
        echo "⚠️ 警告: 未找到 iOS IPA 产物"
    fi
fi

# --- 5. 上传 ---
if [ "$(ls -A $DIST_DIR)" ]; then
    echo "☁️ 上传到 Cloudflare R2: ${FOLDER_NAME} ..."

    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    export RCLONE_CONFIG_R2_ACL=private

    rclone copy "$DIST_DIR" "R2:${R2_BUCKET_NAME}/${PROJECT_NAME}/${PLATFORM_DIR}/${FOLDER_NAME}" --progress

    echo "🏁 上传完成！"
    ls -lh "$DIST_DIR"
else
    echo "❌ 错误: 没有收集到任何产物，取消上传。"
    exit 1
fi
