#!/bin/zsh -f
# 重新生成 zstd 解码检查（tests/swift/ZstdDecodeChecks.swift）用的夹具。检查运行时不调用 zstd，
# 只读这里提交的 .zst 文件和 expected.tsv（解压后应得到的字节数与 SHA-256）。
# 原文全部是本脚本合成的文本 / 字节，不含任何真实会话记录。需要 zstd 1.5.x（例如 Homebrew 的）。
#
# 用法：tests/fixtures/zstd/make-fixtures.zsh [zstd 程序路径]
set -eu
zstd=${1:-/opt/homebrew/bin/zstd}
here=${0:A:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
z() { "$zstd" -q --single-thread "$@"; }

# 合成的类 JSONL 文本：固定种子的伪随机词表拼行（awk 的 srand 固定种子，结果可重复）
synth() { # <行数> <种子>
  awk -v n="$1" -v seed="$2" 'BEGIN {
    srand(seed)
    split("alpha beta gamma delta tokens input output cached reasoning shell patch apply read write " \
          "function_call message assistant user tool result summary file path line column error ok " \
          "rate_limits primary secondary window used percent resets session turn context", w, " ")
    for (i = 0; i < n; i++) {
      s = ""
      k = 3 + int(rand() * 12)
      for (j = 0; j < k; j++) s = s w[1 + int(rand() * 40)] " "
      printf "{\"seq\":%d,\"type\":\"%s\",\"n\":%d,\"text\":\"%s\"}\n", i, w[1 + int(rand() * 40)], int(rand() * 100000), s
    }
  }'
}

synth 400 7 > "$work/small.txt"
synth 2000 11 > "$work/large.txt"
: > "$work/empty.txt"
awk 'BEGIN { for (i = 0; i < 300000; i++) printf "a" }' > "$work/same-byte.txt"
awk 'BEGIN { srand(3); for (i = 0; i < 20000; i++) printf "%c", int(rand() * 256) }' > "$work/random.bin"
# 下面几份专门让编码器走到较少见的路径（用临时插桩的解码器确认过）：
# 高度重复的行（约 950 KB）-19：FSE 的 RLE 与重复模式、RLE 字面量、单流 Huffman、Treeless 字面量
awk 'BEGIN { for (i = 0; i < 30000; i++) printf "line %d: the same text again\n", i }' > "$work/lines.txt"
# 随机小写字母 -1：只有字面量、没有序列的压缩块（字面量超过 16 KB，5 字节的字面量头）
awk 'BEGIN { srand(13); for (i = 0; i < 20000; i++) printf "%c", 97 + int(rand() * 26) }' > "$work/letters.txt"
# 0–15 的偏斜字节 -3：Huffman 权重直接表示（不经 FSE）
awk 'BEGIN { srand(29); for (i = 0; i < 3000; i++) { r = rand(); c = r < 0.4 ? 0 : (r < 0.6 ? 1 : (r < 0.7 ? 2 : (r < 0.8 ? 3 : 4 + int(rand() * 12)))); printf "%c", c } }' > "$work/nibbles.bin"
# 按 de Bruijn 顺序排列的 4 字节同值片段 -19：一个块里超过 0x7F00 个序列（3 字节的序列数）、Raw 字面量
awk 'BEGIN { n = 0; for (a = 0; a < 256 && n < 33000; a++) { printf "%c%c%c%c", a, a, a, a; n++; for (b = a + 1; b < 256 && n < 33000; b++) { printf "%c%c%c%c%c%c%c%c", a, a, a, a, b, b, b, b; n += 2 } } }' > "$work/many-sequences.bin"

cd "$here"
rm -f -- *.zst(N) expected.tsv
z -1 -o small-1.zst "$work/small.txt"
z -3 -o small-3.zst "$work/small.txt"
z -19 -o small-19.zst "$work/small.txt"
z --ultra -22 -o small-22-ultra.zst "$work/small.txt"
z -3 --no-check -o small-3-nocheck.zst "$work/small.txt"
# 从标准输入压缩：帧头不带内容大小，带窗口描述符
z -3 --long < "$work/small.txt" > small-3-long-stdin.zst
z -19 --no-check < "$work/small.txt" > small-19-stdin-nocheck.zst
z -1 -o large-1.zst "$work/large.txt"
z -19 -o large-19.zst "$work/large.txt"
z -3 -o empty.zst "$work/empty.txt"
z -3 -o same-byte.zst "$work/same-byte.txt"
z -3 -o random.zst "$work/random.bin"
z -19 -o lines-19.zst "$work/lines.txt"
z -1 -o letters-1.zst "$work/letters.txt"
z -3 -o nibbles-3.zst "$work/nibbles.bin"
z -19 -o many-sequences-19.zst "$work/many-sequences.bin"
# 多帧：两帧直接拼接；中间夹一个 7 字节的跳过帧（魔数 0x184D2A5A）
cat letters-1.zst same-byte.zst > multi-frame.zst
{ cat empty.zst; printf '\x5a\x2a\x4d\x18\x07\x00\x00\x00skipped'; cat small-3-nocheck.zst; } > multi-frame-skippable.zst

expect() { # <夹具> <原文…>
  local sum size
  sum=$(cat "${@:2}" | shasum -a 256 | cut -d' ' -f1)
  size=$(cat "${@:2}" | wc -c | tr -d ' ')
  printf '%s\t%s\t%s\n' "$1" "$size" "$sum" >> expected.tsv
}
for f in small-1 small-3 small-19 small-22-ultra small-3-nocheck small-3-long-stdin small-19-stdin-nocheck; do
  expect $f.zst "$work/small.txt"
done
for f in large-1 large-19; do expect $f.zst "$work/large.txt"; done
expect empty.zst "$work/empty.txt"
expect same-byte.zst "$work/same-byte.txt"
expect random.zst "$work/random.bin"
expect lines-19.zst "$work/lines.txt"
expect letters-1.zst "$work/letters.txt"
expect nibbles-3.zst "$work/nibbles.bin"
expect many-sequences-19.zst "$work/many-sequences.bin"
expect multi-frame.zst "$work/letters.txt" "$work/same-byte.txt"
expect multi-frame-skippable.zst "$work/empty.txt" "$work/small.txt"
