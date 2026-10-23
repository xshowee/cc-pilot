#!/bin/zsh -f
# 准备 Sparkle 发布包（框架 + generate_appcast / generate_keys / sign_update），输出它的目录。
#   SPARKLE=$(./scripts/fetch-sparkle.sh)
#
# 固定版本，首次运行时从 GitHub Release 下载到
# build/deps/Sparkle-<版本>/，校验 SHA-256，先解压到临时目录再改名（中断后不会留下半成品）；
# 已存在则直接输出路径，不联网。
#
# 环境变量：
#   CCP_SPARKLE_DIR  直接使用这个目录（例如别处已解压好的同版本 Sparkle，或测试用的假目录），不下载

emulate -R zsh
setopt err_exit pipe_fail

ROOT=${0:A:h:h}
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

if [[ -n ${CCP_SPARKLE_DIR-} ]]; then
  [[ -d $CCP_SPARKLE_DIR/Sparkle.framework ]] || {
    print -u2 -r -- "CCP_SPARKLE_DIR=$CCP_SPARKLE_DIR 里没有 Sparkle.framework"; exit 1
  }
  print -r -- ${CCP_SPARKLE_DIR:A}
  exit 0
fi

DEPS=$ROOT/build/deps
SPARKLE=$DEPS/Sparkle-$SPARKLE_VERSION
if [[ ! -d $SPARKLE/Sparkle.framework ]]; then
  print -u2 -r -- "==> 下载 Sparkle $SPARKLE_VERSION"
  archive=$DEPS/Sparkle-$SPARKLE_VERSION.tar.xz
  mkdir -p -- $DEPS
  curl -fsSL --retry 3 -o $archive \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  if ! shasum -a 256 -c <<<"$SPARKLE_SHA256  $archive" > /dev/null; then
    rm -f -- $archive
    print -u2 -r -- "Sparkle 发布包 SHA-256 校验失败"
    exit 1
  fi
  rm -rf -- $SPARKLE.tmp
  mkdir -p -- $SPARKLE.tmp
  tar -xf $archive -C $SPARKLE.tmp
  mv -- $SPARKLE.tmp $SPARKLE
  rm -f -- $archive
fi
print -r -- $SPARKLE
