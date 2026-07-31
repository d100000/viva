#!/bin/bash
# Viva 一键安装
#
#   curl -fsSL https://raw.githubusercontent.com/d100000/viva/main/install.sh | bash
#
# 干四件事：查最新 Release → 下 zip → 去 Gatekeeper 隔离属性 → 装进 /Applications
#
# 装到 ~/Applications（不需要 sudo）：
#   curl -fsSL .../install.sh | VIVA_PREFIX="$HOME/Applications" bash
# 装指定版本：
#   curl -fsSL .../install.sh | VIVA_VERSION=v0.3.0 bash
# 从已下载好的本地包装（网络差时有用，也是本脚本的自测入口）：
#   ./install.sh            # 需配合 VIVA_ZIP=./Viva-0.3.0.zip
set -euo pipefail

REPO="d100000/viva"
PREFIX="${VIVA_PREFIX:-/Applications}"
APP_NAME="Viva.app"
TARGET="${PREFIX}/${APP_NAME}"

# 这个脚本可能通过管道运行（stdin 不是终端），交互式确认要从 /dev/tty 读。
if [ -t 1 ]; then B=$(printf '\033[1m'); D=$(printf '\033[2m'); R=$(printf '\033[0m')
else B=""; D=""; R=""; fi
say()  { printf '%s▸%s %s\n' "$D" "$R" "$1"; }
die()  { printf '\n✖ %s\n' "$1" >&2; exit 1; }

printf '\n%sViva%s —— 话音未落，字已上屏\n\n' "$B" "$R"

# ── 环境检查 ──────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "Viva 只支持 macOS。"

# macOS 14+：Package.swift 里 platforms 写的是 .macOS(.v14)
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "${OS_MAJOR}" -lt 14 ]; then
  die "需要 macOS 14 (Sonoma) 或更高，当前是 $(sw_vers -productVersion)。"
fi

# Intel Mac 上会跑 Rosetta，能用但没实测过，只提示不拦
if [ "$(uname -m)" != "arm64" ]; then
  say "注意：发布的二进制是 arm64，Intel Mac 需要 Rosetta 且未经实测。"
fi

# ── 确定装哪个包 ──────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

if [ -n "${VIVA_ZIP:-}" ]; then
  # 本地包模式：跳过 GitHub 查询，直接用给定的 zip
  [ -f "${VIVA_ZIP}" ] || die "找不到本地包：${VIVA_ZIP}"
  say "使用本地包 ${B}${VIVA_ZIP}${R}"
  cp "${VIVA_ZIP}" "${TMP}/pkg.zip"
  VER=""   # 版本号稍后从 bundle 里读
else
  if [ -n "${VIVA_VERSION:-}" ]; then
    TAG="${VIVA_VERSION}"
    say "指定版本 ${B}${TAG}${R}"
  else
    say "查询最新版本…"
    # 只用 curl + grep，不依赖 jq
    TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
          | grep -m1 '"tag_name"' | cut -d'"' -f4) \
      || die "查询 GitHub Release 失败，检查网络后重试。"
    [ -n "${TAG}" ] || die "没找到任何 Release。"
    say "最新版本 ${B}${TAG}${R}"
  fi

  VER="${TAG#v}"
  ZIP="Viva-${VER}.zip"
  URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIP}"

  # 已装同版本就别白折腾
  if [ -d "${TARGET}" ]; then
    CUR=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "${TARGET}/Contents/Info.plist" 2>/dev/null || echo "?")
    if [ "${CUR}" = "${VER}" ]; then
      printf '\n✅ 已经是最新版 %s，无需重装。\n\n' "${VER}"
      exit 0
    fi
    say "检测到已安装 ${CUR}，将升级到 ${VER}"
  fi

  say "下载 ${ZIP} …"
  curl -fL# -o "${TMP}/pkg.zip" "${URL}" || die "下载失败：${URL}"
fi

say "解压…"
ditto -x -k "${TMP}/pkg.zip" "${TMP}/x" || die "解压失败，包可能不完整。"
[ -d "${TMP}/x/${APP_NAME}" ] || die "包里没有 ${APP_NAME}。"

# 本地包模式下版本号只能从 bundle 里读
if [ -z "${VER}" ]; then
  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "${TMP}/x/${APP_NAME}/Contents/Info.plist" 2>/dev/null || echo "?")
  say "包内版本 ${VER}"
fi

# ── 去 Gatekeeper 隔离 ────────────────────────────────────────────
# Viva 的默认发布包使用自签名而非 Apple Developer ID，尚未公证。
# 从浏览器/curl 下载的文件会被打上 com.apple.quarantine，双击直接被拦。
# 这一步必须在安装前做，否则用户看到的是「已损坏，应移到废纸篓」。
say "移除下载隔离属性…"
xattr -dr com.apple.quarantine "${TMP}/x/${APP_NAME}" 2>/dev/null || true

# ── 安装 ──────────────────────────────────────────────────────────
mkdir -p "${PREFIX}" 2>/dev/null || true
if [ ! -w "${PREFIX}" ]; then
  die "没有写入 ${PREFIX} 的权限。
    用 sudo：curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash
    或装到用户目录：curl -fsSL ... | VIVA_PREFIX=\"\$HOME/Applications\" bash"
fi

# 运行中的旧版本先退掉，否则替换后行为诡异。
# ⚠️ 只退「正要被替换的那一个」——按可执行文件路径匹配，不是见 Viva 就杀。
# 装到自定义 PREFIX 时，用户在 /Applications 里跑着的那个不该受影响。
#
# 两个坑：
#   1. `ps -eo comm=` 会把路径按列宽截断成 "/System/Library/"，只有
#      `ps -p <pid> -o comm=` 才给完整路径。
#   2. ps 报的是物理路径（/private/var/…），而 PREFIX 可能是符号链接路径
#      （/var/…、/tmp/…）。直接字符串比较会漏判，两边都要先解析。
physdir() {  # 解析目录的物理路径；解析不了就原样返回
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"
}

if [ -d "${TARGET}" ] && pgrep -x "Viva" >/dev/null 2>&1; then
  WANT="$(physdir "${TARGET}")/Contents/MacOS/Viva"
  for pid in $(pgrep -x "Viva"); do
    GOT=$(ps -p "${pid}" -o comm= 2>/dev/null || true)
    [ "${GOT}" = "${WANT}" ] || continue

    say "退出正在运行的 Viva…"
    kill -TERM "${pid}" 2>/dev/null || true
    # 等它自己退，最多 3 秒；真赖着不走再强杀
    for _ in 1 2 3 4 5 6; do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
  done
fi

say "安装到 ${PREFIX} …"
# 先搬到旁边再删，避免中途失败把用户的旧版本弄没了
if [ -d "${TARGET}" ]; then
  BACKUP="${TMP}/old-${APP_NAME}"
  mv "${TARGET}" "${BACKUP}" || die "无法替换 ${TARGET}，可能正被占用。"
fi
if ! ditto "${TMP}/x/${APP_NAME}" "${TARGET}"; then
  [ -d "${TMP}/old-${APP_NAME}" ] && mv "${TMP}/old-${APP_NAME}" "${TARGET}"
  die "安装失败，已回滚。"
fi

printf '\n✅ 安装完成：%s%s%s\n\n' "$B" "${TARGET}" "$R"
cat <<EOF
${B}接下来${R}
  1. 启动：  open -a Viva
  2. 首次启动会走引导：邮箱注册或登录 → 麦克风授权 → 辅助功能授权
  3. 授权辅助功能后${B}必须重启 App${R}，热键才生效

${D}默认热键是按住右 ⌘ 说话。菜单栏没图标？大概是卡在麦克风授权弹窗上了。${R}
EOF
