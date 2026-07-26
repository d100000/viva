#!/bin/bash
# 把 dist/Viva.app 打成可发布的 DMG + ZIP。
#
# 前置：先跑 ./build.sh
# 用法：./package.sh          （版本号自动从 Info.plist 读）
#
# 为什么不用 Finder 压缩：Finder 会往 zip 里塞 __MACOSX/ 和 ._* 资源分叉，
# 用 unzip 解出来一堆垃圾文件。ditto 是 Apple 官方做法。
#
# ⚠️ 别加 --sequesterRsrc：它是**生成** __MACOSX 的那个开关（把资源分叉隔离进去），
#    不是抑制它。Apple 的公证文档里带这个参数，那是给 notary service 用的；
#    本项目 ad-hoc 签名没法公证，端用户拿到的包越干净越好。
#    实测本 bundle 唯一的 xattr 是系统自动打的 com.apple.provenance，没有值得保留的东西，
#    去掉后 codesign --verify --deep --strict 往返验签依然通过。
set -euo pipefail

cd "$(dirname "$0")"

APP_DIR="dist/Viva.app"
[ -d "${APP_DIR}" ] || { echo "✖ 没有 ${APP_DIR}，先跑 ./build.sh"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist")
ZIP_PATH="dist/Viva-${VERSION}.zip"
DMG_PATH="dist/Viva-${VERSION}.dmg"
STAGE_DIR="dist/.dmg-stage"

echo "▸ 版本 ${VERSION}"

# ── ZIP ──────────────────────────────────────────────────────────
# --keepParent 让解压后是 Viva.app 而不是散落的 Contents/
echo "▸ 打 ZIP …"
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

# ── DMG ──────────────────────────────────────────────────────────
# 布局：app + Applications 软链接，用户拖过去即装。
# 不用 create-dmg（要额外装），hdiutil 够了。
echo "▸ 打 DMG …"
rm -rf "${STAGE_DIR}" "${DMG_PATH}"
mkdir -p "${STAGE_DIR}"
ditto "${APP_DIR}" "${STAGE_DIR}/Viva.app"
ln -s /Applications "${STAGE_DIR}/Applications"

hdiutil create \
  -volname "Viva ${VERSION}" \
  -srcfolder "${STAGE_DIR}" \
  -ov -format UDZO \
  "${DMG_PATH}" >/dev/null

rm -rf "${STAGE_DIR}"

# ── 校验 ─────────────────────────────────────────────────────────
echo
echo "✅ 产物："
for f in "${ZIP_PATH}" "${DMG_PATH}"; do
  printf '   %-28s %6s  sha256 %s\n' \
    "$(basename "$f")" \
    "$(du -h "$f" | cut -f1)" \
    "$(shasum -a 256 "$f" | cut -c1-16)…"
done
echo
echo "   完整 sha256（Homebrew cask 要用 DMG 这条）："
shasum -a 256 "${DMG_PATH}" | awk '{print "   " $1}'
