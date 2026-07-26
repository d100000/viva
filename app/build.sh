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

# 代码签名。TCC 授权(辅助功能/麦克风)绑定的是签名身份的「指定要求(DR)」:
#   - 固定证书签名 → DR = certificate leaf 指纹,换版本、重编译都不变 → 授权跨更新存活。
#   - ad-hoc 签名  → DR = cdhash(这一份二进制的哈希),一重编译就变 → 每次都要重新授权。
# 身份优先级:环境变量 VIVA_SIGN_IDENTITY > 固定自签证书「Viva Self-Signed」> ad-hoc 兜底。
# 还没有自签证书?先跑一次:./make-signing-cert.sh
# 将来换 Developer ID:导入付费证书后 export VIVA_SIGN_IDENTITY="Developer ID Application: 名字 (TEAMID)"，本脚本无需改。
SIGN_IDENTITY="${VIVA_SIGN_IDENTITY:-Viva Self-Signed}"
if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
  echo "▸ 签名（${SIGN_IDENTITY}，固定身份 → 授权可跨更新保留）…"
  codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${APP_DIR}"
else
  echo "▸ 签名（ad-hoc 兜底）…"
  echo "  ⚠️ 未找到证书「${SIGN_IDENTITY}」，回退 ad-hoc：每次重编后 TCC 授权都会失效。"
  echo "     根治:先跑 ./make-signing-cert.sh 生成固定自签证书，再重新构建。"
  codesign --force --sign - --timestamp=none "${APP_DIR}" 2>/dev/null
fi

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
