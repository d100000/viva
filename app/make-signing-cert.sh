#!/bin/bash
# 生成 / 恢复 Viva 的固定自签代码签名证书。
#
# 为什么需要它:
#   macOS 的 TCC(辅助功能/麦克风授权)记录 App 时,存的是它的「指定要求(DR)」。
#   - 固定证书签名 → DR = certificate leaf 指纹,换版本、重编译都不变 → 授权跨更新存活。
#   - ad-hoc 签名  → DR = cdhash(这一份二进制的哈希),一重编译就变 → 每次都要在
#                    「系统设置 → 隐私与安全性 → 辅助功能」里删掉再重新添加。
#   所以给 App 一张固定证书,是「更新后不用重新授权」的根本解法。
#
# 用法:
#   ./make-signing-cert.sh            # 首次生成 / 或从备份恢复(幂等)
#   ./make-signing-cert.sh --force    # 强制重建新证书(指纹会变,下次授权失效一次)
#
# 生成后 build.sh 会自动用它签名(优先级见 build.sh 注释)。
#
# 私密信息一律留在仓库外的 ~/.config/viva/signing/,绝不进 git:
#   viva-signing.p12        私钥(证书本体)
#   viva-signing.p12.pass   上面这份 p12 的传输密码(随机生成,权限 600)
# 换机器/重装系统前把这**两个文件**一起拷走,再在新机上跑本脚本 → 自动恢复同一张证书
# (指纹不变,授权无需重来)。丢了则只能重建,会要求重新授权一次。
#
# 将来换 Developer ID:把付费证书导入登录钥匙串后,
#   export VIVA_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)"
# 再 build 即可,无需本脚本。

set -uo pipefail

IDENTITY_CN="Viva Self-Signed"
KEYCHAIN_PATH="$HOME/Library/Keychains/viva-signing.keychain-db"
KEYCHAIN_PW=""                 # 专用钥匙串,自设空密码 → 设 partition-list 不用登录密码、不弹窗
BACKUP_DIR="$HOME/.config/viva/signing"
P12_PATH="${BACKUP_DIR}/viva-signing.p12"
PASS_PATH="${BACKUP_DIR}/viva-signing.p12.pass"   # p12 传输密码,只存本机、仓库外

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# 幂等:证书已在钥匙串且非强制 → 直接退出
if [ "$FORCE" -eq 0 ] && security find-certificate -c "$IDENTITY_CN" >/dev/null 2>&1; then
  echo "✅ 已存在签名证书「$IDENTITY_CN」,无需重建。"
  echo "   (强制重建新证书:$0 --force —— 注意指纹会变,已装 App 的授权失效一次)"
  exit 0
fi

mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --force:清掉旧备份,走全新生成
if [ "$FORCE" -eq 1 ]; then
  rm -f "$P12_PATH" "$PASS_PATH"
fi

if [ -f "$P12_PATH" ] && [ -f "$PASS_PATH" ]; then
  # —— 恢复路径:用已有备份导入,保持指纹一致(跨机器迁移就走这条)——
  echo "▸ 发现备份,恢复证书「$IDENTITY_CN」(保持指纹一致)…"
  P12_PW=$(cat "$PASS_PATH")
elif [ -f "$P12_PATH" ] && [ ! -f "$PASS_PATH" ]; then
  echo "❌ 有 $P12_PATH 但缺密码文件 $PASS_PATH,无法导入。"
  echo "   请把当初一起备份的 .pass 文件放回,或 --force 重建新证书。"
  exit 1
else
  # —— 全新生成:随机传输密码,只写到仓库外的 .pass ——
  echo "▸ 生成新的固定自签证书「$IDENTITY_CN」…"
  P12_PW=$(openssl rand -hex 16)
  printf '%s' "$P12_PW" > "$PASS_PATH"; chmod 600 "$PASS_PATH"

  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${IDENTITY_CN}
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null || {
      echo "❌ openssl 生成证书失败"; exit 1; }

  openssl pkcs12 -export -out "$P12_PATH" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY_CN" -passout "pass:${P12_PW}" 2>/dev/null || {
      echo "❌ 打包 p12 失败"; exit 1; }
  chmod 600 "$P12_PATH"
fi

# 专用钥匙串(空密码,自己可控)
security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_PATH"
security set-keychain-settings "$KEYCHAIN_PATH"          # 不自动上锁
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_PATH"

# 导入身份,授权 codesign 使用
security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "$P12_PW" -T /usr/bin/codesign -A >/dev/null 2>&1 || {
    echo "❌ 导入 p12 到钥匙串失败(密码不匹配?)"; exit 1; }

# partition-list:codesign 用私钥签名时不弹窗(空钥匙串密码,故无需登录密码)
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1

# 把专用钥匙串加入用户搜索列表(否则 codesign/find-certificate 看不到)
EXISTING=$(security list-keychains -d user | sed 's/[",]//g' | xargs)
case " $EXISTING " in
  *" $KEYCHAIN_PATH "*) security list-keychains -d user -s $EXISTING >/dev/null ;;
  *) security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING >/dev/null ;;
esac

# 自检:能否真的用它签名,且 DR 为证书指纹
cp /bin/echo "$TMP/probe"
if codesign --force --sign "$IDENTITY_CN" --timestamp=none "$TMP/probe" >/dev/null 2>&1; then
  DR=$(codesign -d -r- "$TMP/probe" 2>&1 | grep -o 'certificate leaf = H"[0-9a-f]*"' || true)
  echo
  echo "✅ 完成。签名身份「$IDENTITY_CN」可用。"
  echo "   指定要求(DR): ${DR:-未取到,但签名成功}"
  echo "   私钥+密码备份: $BACKUP_DIR/ (viva-signing.p12 与 .pass 两个文件,换机器前一起拷走)"
  echo
  echo "下一步:cd app && ./build.sh —— 会自动用这张证书签名。"
  echo "首次切换后,系统会视为「新身份」,需在辅助功能里重新授权最后一次;之后所有更新都保留授权。"
else
  echo "❌ 生成/恢复了证书但 codesign 试签失败,请检查上面的报错。"
  exit 1
fi
