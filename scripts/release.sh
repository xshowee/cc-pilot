#!/bin/zsh -f
# 正式发布 CC Pilot：./scripts/release.sh
#
# 一条命令完成：发布前检查 → universal 构建（arm64 + x86_64）→ Developer ID 签名（hardened runtime，
# 带时间戳）→ 公证并 staple App → 打包 DMG → 签名、公证并 staple DMG → Gatekeeper 校验 →
# 用 Sparkle 的 generate_appcast 把新版本加进仓库根目录的 appcast.xml（EdDSA 签名）。
# 产物：build/CC Pilot.app、build/CCPilot-<版本>.dmg、appcast.xml。上传与推送由用户手动完成，
# 完整步骤见 docs/release.md。
#
# 不启用 App Sandbox；唯一的 entitlement 是发送 Apple 事件（见 scripts/build-app.sh）。
#
# 环境变量（也可以写在仓库根目录的 .env 里，格式见 .env.example；命令行里设置的优先）：
#   CCP_TEAM_ID            签名所属团队，默认取钥匙串里 Developer ID Application 证书所属的团队；
#                           钥匙串里有多个团队的证书时必须指定
#   CCP_RELEASE_IDENTITY    签名身份（名称或 SHA-1），默认取该团队的 Developer ID Application 证书；
#                           "-" 表示 ad-hoc，只允许与 CCP_SKIP_NOTARIZE=1 一起用
#   CCP_NOTARY_PROFILE      notarytool 钥匙串凭据名，默认 cc-pilot-notary
#   CCP_RELEASE_NOTES       本版更新说明（Markdown 文件），嵌入 appcast，可省略
#   CCP_SKIP_NOTARIZE=1     只在本机验证打包流程：跳过公证、跳过 Sparkle 私钥检查和 appcast 生成，
#                           Sparkle 公钥为占位值时只警告。产物不能分发
#   CCP_SPARKLE_DIR         见 scripts/fetch-sparkle.sh

emulate -R zsh
setopt err_exit pipe_fail

ROOT=${0:A:h:h}
cd -- "$ROOT"

# load_env_file：读取 .env 里的 CCP_* 变量（只认 NAME=值 这样的行，值两边的引号会去掉），
# 不执行其中的命令；值为空的行当作没写，已经设置的环境变量不覆盖。
load_env_file() {
  local line name value
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ '^(CCP_[A-Z_]+)=(.*)$' ]] || continue
    name=$match[1] value=$match[2]
    [[ $value == \"*\" || $value == \'*\' ]] && value=${value[2,-2]}
    if [[ -n $value && -z ${(P)name+set} ]]; then
      export $name=$value
    fi
  done < $1
}
if [[ -f .env ]]; then
  load_env_file .env
fi

PLIST=Resources/Info.plist
# 与 Resources/Info.plist 和 Sources/App/Updater.swift 中的占位值一致（32 个零字节的 base64）
PLACEHOLDER_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
# cc-pilot 使用单独的 Sparkle 密钥，存放在钥匙串的这个账户下，不用默认账户
SPARKLE_ACCOUNT=cc-pilot
REPO_URL=https://github.com/xshowee/cc-pilot
TEAM_ID=${CCP_TEAM_ID:-}
NOTARY_PROFILE=${CCP_NOTARY_PROFILE:-cc-pilot-notary}
SKIP_NOTARIZE=${CCP_SKIP_NOTARIZE:-0}

BUILD=$ROOT/build
APP="$BUILD/CC Pilot.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" $PLIST }
VERSION=$(plist CFBundleShortVersionString)
BUILD_NUMBER=$(plist CFBundleVersion)
# DMG 文件名不能有空格：GitHub 会改写附件名里的空格，appcast 里的下载地址就对不上了
DMG=$BUILD/CCPilot-$VERSION.dmg

die() { print -u2 -r -l -- "$@"; exit 1 }  # 每个参数一行
warn() { print -u2 -r -- "提示：$*" }
step() { print -r -- "==> $*" }

# ---------- 发布前检查（全部在编译之前；占位公钥检查不联网，排在最前面） ----------

PUBLIC_KEY=$(plist SUPublicEDKey 2>/dev/null || true)
if [[ -z $PUBLIC_KEY || $PUBLIC_KEY == $PLACEHOLDER_KEY ]]; then
  if [[ $SKIP_NOTARIZE == 1 ]]; then
    warn "Info.plist 的 SUPublicEDKey 仍是占位值，这个构建里的 App 不会启动 Sparkle"
  else
    die "Info.plist 的 SUPublicEDKey 仍是占位值，拒绝发布。请先生成 cc-pilot 专用的 Sparkle 密钥：" \
      "  SPARKLE=\$(./scripts/fetch-sparkle.sh); \$SPARKLE/bin/generate_keys --account $SPARKLE_ACCOUNT" \
      "再把它输出的公钥填进 $PLIST 的 SUPublicEDKey（见 docs/release.md）"
  fi
fi

[[ $BUILD_NUMBER == <-> ]] || die "CFBundleVersion 必须是整数（Sparkle 按它比较版本），现在是 [$BUILD_NUMBER]"

if [[ $SKIP_NOTARIZE != 1 ]]; then
  # 私钥与 Info.plist 中的公钥不匹配时，已安装的 App 会拒绝这次更新
  SPARKLE=$(./scripts/fetch-sparkle.sh)
  KEYCHAIN_KEY=$("$SPARKLE/bin/generate_keys" -p --account $SPARKLE_ACCOUNT 2>/dev/null) || KEYCHAIN_KEY=
  if [[ -z $KEYCHAIN_KEY ]]; then
    die "钥匙串里没有账户 $SPARKLE_ACCOUNT 的 Sparkle 私钥。新建：$SPARKLE/bin/generate_keys --account $SPARKLE_ACCOUNT；" \
      "从备份导入：$SPARKLE/bin/generate_keys --account $SPARKLE_ACCOUNT -f <私钥文件>"
  fi
  [[ $KEYCHAIN_KEY == $PUBLIC_KEY ]] ||
    die "钥匙串里账户 $SPARKLE_ACCOUNT 的 Sparkle 公钥与 $PLIST 的 SUPublicEDKey 不匹配，拒绝发布"
fi

# dev_id_certs：钥匙串里的 Developer ID Application 证书，每行"SHA-1 Team ID"。
# Developer ID 证书名末尾括号里就是 Team ID（Apple Development 证书不是）。
dev_id_certs() {
  security find-identity -v -p codesigning |
    awk -F'"' '$2 ~ /^Developer ID Application: .*\([A-Z0-9]+\)$/ {
        split($1, f, " "); n = split($2, p, "("); team = p[n]; sub(/\)$/, "", team); print f[2], team
      }'
}

CERTS=$(dev_id_certs)
# 没有指定 CCP_TEAM_ID 时，钥匙串里只有一个团队的证书就用这个团队
if [[ -z $TEAM_ID ]]; then
  typeset -aU teams
  teams=(${${(f)CERTS}##* })
  if (( ${#teams} == 1 )); then
    TEAM_ID=$teams[1]
  elif (( ${#teams} > 1 )) && [[ -z ${CCP_RELEASE_IDENTITY+set} ]]; then
    die "钥匙串里有多个团队的 Developer ID Application 证书（${(j:、:)teams}），请用 CCP_TEAM_ID 指定"
  fi
fi

# find_identity：输出 TEAM_ID 团队的第一个 Developer ID Application 证书的 SHA-1
find_identity() {
  if [[ -n $TEAM_ID ]]; then
    local -a matched
    matched=(${(M)${(f)CERTS}:#* $TEAM_ID})
    print -r -- ${matched[1]%% *}
  fi
}

IDENTITY=${CCP_RELEASE_IDENTITY-$(find_identity)}
if [[ $IDENTITY == - ]]; then
  [[ $SKIP_NOTARIZE == 1 ]] || die "ad-hoc 签名（CCP_RELEASE_IDENTITY=-）只能与 CCP_SKIP_NOTARIZE=1 一起用"
  warn "使用 ad-hoc 签名，产物无法通过 Gatekeeper"
elif [[ -z $IDENTITY ]]; then
  die "钥匙串里没有${TEAM_ID:+团队 $TEAM_ID 的} Developer ID Application 证书（可用 CCP_RELEASE_IDENTITY 指定）"
elif ! security find-identity -v -p codesigning | grep -F -q -- "$IDENTITY"; then
  die "钥匙串里找不到签名身份 $IDENTITY"
fi

if [[ $SKIP_NOTARIZE != 1 ]] &&
   ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
  die "找不到公证凭据 \"$NOTARY_PROFILE\"，请先执行（见 docs/release.md）：" \
    "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id ${TEAM_ID:-<Team ID>}"
fi

# ---------- 构建与签名 ----------

typeset -a sign_args
sign_args=(--universal --sign "$IDENTITY")
[[ $IDENTITY == - ]] || sign_args+=(--hardened-runtime --timestamp)
./scripts/build-app.sh $sign_args

archs=$(lipo -archs "$APP/Contents/MacOS/CCPilot")
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || die "App 不是 universal：$archs"

notarize() {  # 文件：提交公证并等待结果
  local file=$1 output id
  step "公证 ${file:t}（通常需要几分钟）"
  output=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr)
  # 被拒（Invalid）时 notarytool 的退出码仍为 0，要自己判断
  if [[ $output != *"status: Accepted"* ]]; then
    id=$(awk '/^ *id:/ { print $2; exit }' <<<"$output")
    print -u2 -r -- "公证未通过，日志如下："
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
}

# 先公证并 staple App 本身，这样从 DMG 拷出来后离线也能通过 Gatekeeper（zip 只是上传载体）
if [[ $SKIP_NOTARIZE != 1 ]]; then
  ZIP=$BUILD/CCPilot.zip
  ditto -c -k --keepParent "$APP" $ZIP
  notarize $ZIP
  rm -f -- $ZIP
  xcrun stapler staple "$APP"
fi

# ---------- DMG ----------

step "打包 ${DMG:t}"
STAGING=$BUILD/dmg
rm -rf -- $STAGING $DMG
mkdir -p -- $STAGING
cp -R -- "$APP" $STAGING/
ln -s /Applications $STAGING/Applications
hdiutil create -quiet -volname "CC Pilot" -srcfolder $STAGING -fs HFS+ -format UDZO $DMG
rm -rf -- $STAGING
if [[ $IDENTITY == - ]]; then
  codesign --force --sign - $DMG
else
  codesign --force --timestamp --sign "$IDENTITY" $DMG
fi

step "校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 $DMG

if [[ $SKIP_NOTARIZE != 1 ]]; then
  notarize $DMG
  xcrun stapler staple $DMG
  step "Gatekeeper 校验"
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose $DMG
fi

# ---------- appcast ----------

if [[ $SKIP_NOTARIZE == 1 ]]; then
  print
  print -r -- "本地验证完成（未公证，不能分发）：$DMG"
  print -r -- "未生成 appcast。Gatekeeper 评估（未公证时被拒属预期）："
  spctl --assess --type execute --verbose "$APP" || true
  exit 0
fi

# 以仓库里的 appcast.xml 为底，保留历史条目；Info.plist 开启了 SURequireSignedFeed，
# generate_appcast 会同时给整个 feed 签名。更新说明嵌入 appcast，App 不需要再请求别的地址。
step "生成 appcast"
APPCAST_DIR=$BUILD/appcast
rm -rf -- $APPCAST_DIR
mkdir -p -- $APPCAST_DIR
if [[ -f appcast.xml ]]; then   # 第一次发布时还没有
  cp -- appcast.xml $APPCAST_DIR/
fi
cp -- $DMG $APPCAST_DIR/
if [[ -n ${CCP_RELEASE_NOTES-} ]]; then
  # 与 DMG 同名的 .md 会被当作该版本的更新说明
  cp -- $CCP_RELEASE_NOTES $APPCAST_DIR/${DMG:t:r}.md
fi
"$SPARKLE/bin/generate_appcast" --account $SPARKLE_ACCOUNT --embed-release-notes \
  --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
  --full-release-notes-url "$REPO_URL/releases" --link "$REPO_URL" $APPCAST_DIR
cp -- $APPCAST_DIR/appcast.xml appcast.xml

print
print -r -- "发布包：$DMG（版本 $VERSION，构建号 $BUILD_NUMBER）"
print -r -- "下一步（顺序不能反，见 docs/release.md）："
print -r -- "  1. 把 DMG 上传到 GitHub Release v$VERSION"
print -r -- "  2. 再提交并推送 appcast.xml"
