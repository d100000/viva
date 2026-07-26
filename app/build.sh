#!/bin/bash
# 编译并组装成可双击运行的 .app
#
# 环境只有 Command Line Tools（没有完整 Xcode）也能跑：
# SwiftPM 出可执行文件，再手工组装 bundle，最后 ad-hoc 签名。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Viva"
BIN_NAME="Viva"
CONFIG="${1:-release}"
BUILD_TRIPLE="arm64-apple-macosx14.0"
BUILD_DIR=".build/arm64-apple-macosx/${CONFIG}"
APP_DIR="dist/${APP_NAME}.app"

echo "▸ 编译（${CONFIG} · ARM64）…"
swift build -c "${CONFIG}" --triple "${BUILD_TRIPLE}"

echo "▸ 组装 .app …"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${BIN_NAME}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
else
  echo "  (没有 AppIcon.icns，先跑：swift tools/make_icon.swift)"
fi
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# ad-hoc 签名。
# ⚠️ 辅助功能/麦克风的 TCC 授权是绑定代码签名身份的，而 ad-hoc 签名会随二进制内容变化，
#    所以每次重新编译后，系统设置里的授权可能失效 —— 表现为「热键突然不灵了」。
#    解决办法：在「系统设置 → 隐私与安全性 → 辅助功能」里把本应用**移除再重新添加**。
echo "▸ 签名（ad-hoc）…"
codesign --force --sign - --timestamp=none "${APP_DIR}" 2>/dev/null

echo
echo "✅ 完成：${PWD}/${APP_DIR}"
echo
echo "下一步："
echo "  1) 先做协议自检（不需要任何权限）："
echo "     export DOUBAO_API_KEY=你的key"
echo "     ${BUILD_DIR}/${BIN_NAME} --selftest 某段录音.wav"
echo
echo "  2) 自检通过后再启动 App："
echo "     open \"${APP_DIR}\""
