#!/bin/zsh
# LAME 4.0 の公式ソースを取得し、SHA-256 を検証して ThirdParty/LAME/Sources/CLAME に展開する。
#
#   ./scripts/fetch-lame.sh                   # 取得・展開（展開済みなら照合だけ）
#   ./scripts/fetch-lame.sh --print-manifest  # 照合用の一覧を作り直して標準出力に出す（LAME の更新時に使う）
#
# - 取得するのは下の固定 URL・固定バージョンのアーカイブだけで、展開前にアーカイブの SHA-256 を確かめる。
# - 展開先に置くのは、libmp3lame のビルドに使うソースとヘッダー、include/lame.h、ライセンス文、
#   ThirdParty/LAME/config.h のコピーだけ。configure などの配布物内のスクリプトは実行しない。
# - 展開先のファイルは、毎回（展開済みのときも）Git で管理している一覧 ThirdParty/LAME/CLAME.sha256 と
#   照合する。変更・欠落・追加（シンボリックリンクを含む）があればビルドを止める。
#   一覧はこのスクリプトが書き換えることはない（--print-manifest は標準出力に出すだけ）。
set -euo pipefail
cd "$(dirname "$0")/.."

version="4.0"
url="https://downloads.sourceforge.net/project/lame/lame/${version}/lame-${version}.tar.gz"
sha256="3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"
dest="ThirdParty/LAME/Sources/CLAME"
manifest="ThirdParty/LAME/CLAME.sha256"

# フォルダ内のファイルの SHA-256 をパスの順に出す。Finder が作る .DS_Store は数えない（ビルドに使われない）
tree_hashes() {
  (cd "$1" && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
}

# フォルダの中身が一覧と完全に一致するか
verify_tree() {
  local dir="$1" diff_out
  if [[ -L "$dir" || -n "$(find "$dir" -type l -print -quit)" ]]; then
    echo "LAME のソースにシンボリックリンクがあります: $dir" >&2
    return 1
  fi
  if ! diff_out="$(diff <(tree_hashes "$dir") "$manifest")"; then
    echo "LAME のソースが一覧（$manifest）と一致しません: $dir" >&2
    echo "（< が展開先、> が一覧。先頭 20 行）" >&2
    print -r -- "$diff_out" | head -20 >&2
    return 1
  fi
}

# 公式アーカイブを取得・検証し、ビルドに使うファイルだけを $1 に組み立てる
assemble() {
  local out="$1" work="$2"
  echo "==> LAME $version を取得" >&2
  curl -fsSL --proto '=https' --retry 3 -o "$work/lame.tar.gz" "$url"
  local actual
  actual="$(shasum -a 256 "$work/lame.tar.gz" | awk '{print $1}')"
  if [[ "$actual" != "$sha256" ]]; then
    echo "LAME のチェックサムが一致しません（期待: $sha256 / 実際: $actual）" >&2
    exit 1
  fi
  mkdir -p "$work/src"
  tar -xzf "$work/lame.tar.gz" -C "$work/src"
  local src="$work/src/lame-$version"

  mkdir -p "$out/include"
  # libmp3lame/Makefile.am の libmp3lame_la_SOURCES と noinst_HEADERS
  for f in VbrTag bitstream encoder fft gain_analysis id3tag lame newmdct presets psymodel quantize \
           quantize_pvt reservoir set_get tables takehiro util vbrquantize version mpglib_interface; do
    cp "$src/libmp3lame/$f.c" "$out/"
  done
  cp "$src"/libmp3lame/*.h "$out/"
  cp "$src/include/lame.h" "$out/include/lame.h"
  # 一部のソースが参照するヘッダーだけ（デコーダーや SSE のコードはコンパイルしない）
  mkdir -p "$out/mpglib" "$out/vector"
  cp "$src"/mpglib/*.h "$out/mpglib/"
  cp "$src/libmp3lame/vector/lame_intrin.h" "$out/vector/"
  cp "ThirdParty/LAME/config.h" "$out/config.h"
  cp "$src/COPYING" "$out/COPYING"
  cp "$src/README" "$out/README"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ "${1:-}" == "--print-manifest" ]]; then
  assemble "$work/CLAME" "$work"
  tree_hashes "$work/CLAME"
  exit 0
fi

[[ -f "$manifest" ]] || { echo "照合用の一覧がありません: $manifest" >&2; exit 1; }
for d in "ThirdParty/LAME/Sources" "$dest"; do
  if [[ -L "$d" ]]; then
    echo "シンボリックリンクは使えません: $d" >&2
    exit 1
  fi
done

if [[ -d "$dest" ]]; then
  # 以前の版のこのスクリプトが作った目印（中身を確かめずに信頼していたもの）は使わない
  rm -f "$dest/.lame-$version"
  if verify_tree "$dest"; then
    exit 0
  fi
  echo "ビルドを中止しました。公式のソースを取得し直すには、次を実行してからやり直してください:" >&2
  echo "  rm -rf $dest" >&2
  exit 1
fi

assemble "$work/CLAME" "$work"
verify_tree "$work/CLAME" || { echo "取得したソースが一覧と一致しません。一覧またはこのスクリプトを確認してください。" >&2; exit 1; }
mkdir -p "$(dirname "$dest")"
mv "$work/CLAME" "$dest"
verify_tree "$dest"
echo "==> 展開しました: $dest"
