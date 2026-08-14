#!/bin/bash
#
# fetch-extensions.sh — 同梱する拡張機能を取ってきて組み立てる
#
# 使い方:
#   ./fetch-extensions.sh
#
# やること:
#   uBlock Origin Lite を指定のタグからビルドして、
#   Skyscraper/Extensions/uBOLite/ に置く。
#
# ここで作られるものは生成物なので git には入れない（.gitignore 済み）。
# clone した直後は Extensions/ が空なので、ビルドの前に一度これを叩くこと。
# 拡張が無くても Skyscraper 自体はビルドも起動もできる（広告遮断が効かないだけ）。
#
# 事前に必要なもの:
#   - Node.js 17.5.0 以上（uBOL のルールセット生成に使う）
#   - git, make
#   - ネット接続（フィルタリストを配信元から落としてくる）
#

set -euo pipefail

# ─────────────────────────────────────────
# 設定
# ─────────────────────────────────────────

# 同梱する uBlock Origin Lite のタグ。
#
# master を追わずタグで固定しているのは、ビルドのたびに中身が変わると
# 「昨日は動いていた」の原因が自分のコードか uBOL かを切り分けられなくなるため。
# 上げたい時はこの一行を書き換えて叩き直す。
# タグ一覧: https://github.com/gorhill/uBlock/tags
#（b0 / rc が付くものはベータ・リリース候補。安定版を選ぶこと）
UBOL_TAG="1.73.0"

UBOL_REPO="https://github.com/gorhill/uBlock.git"

# 出力先。Xcode のソースディレクトリ（Skyscraper/Skyscraper/）の外に置く。
# 中に入れると PBXFileSystemSynchronizedRootGroup が
# 中身をターゲットへ勝手に取り込もうとして事故る
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="$ROOT/Extensions/uBOLite"
STAMP="$DEST/.skyscraper-version"

# ─────────────────────────────────────────

echo "══════════════════════════════════════"
echo " 同梱する拡張機能の取得"
echo "══════════════════════════════════════"

# 既に同じタグで取得済みなら何もしない
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$UBOL_TAG" ]; then
    echo ""
    echo "▸ uBlock Origin Lite $UBOL_TAG は取得済み。何もしない"
    echo "  （作り直したい場合は $DEST を消してから叩く）"
    exit 0
fi

# ─────────────────────────────────────────
# 前提の確認
# ─────────────────────────────────────────

echo ""
echo "▸ 前提を確認..."

for cmd in git make node npm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "エラー: $cmd が見つからない"
        exit 1
    fi
done

# Node は 17.5.0 以上が要る（uBOL のルールセット生成スクリプトの要求）
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 18 ]; then
    echo "  警告: Node.js $(node -v) は古いかもしれない（17.5.0 以上が必要）"
fi
echo "  OK（node $(node -v)）"

# ─────────────────────────────────────────
# 取得とビルド
# ─────────────────────────────────────────

WORK="$(mktemp -d)"
# 途中で失敗しても作業場は片付ける
trap 'rm -rf "$WORK"' EXIT

echo ""
echo "▸ uBlock Origin $UBOL_TAG を取得..."
git clone --quiet --depth 1 --branch "$UBOL_TAG" "$UBOL_REPO" "$WORK/uBlock"
cd "$WORK/uBlock"
git submodule --quiet init
git submodule --quiet update
echo "  OK"

# make mv3-safari は最初に ubol-codemirror（拡張の設定画面で使う
# コードエディタ）を組み立てる。そこで rollup と minify を使うが、
# これらはリポジトリ直下ではなく codemirror-ubol/ の
# node_modules に入る。先にそこで npm install を通さないと
# "rollup: command not found" で止まる
CODEMIRROR_DIR="platform/mv3/extension/lib/codemirror/codemirror-ubol"
if [ -f "$CODEMIRROR_DIR/package.json" ]; then
    echo ""
    echo "▸ codemirror-ubol の依存を入れる..."
    # rollup / minify は devDependencies にいるので --production は付けない
    (cd "$CODEMIRROR_DIR" && npm install --silent --no-audit --no-fund)
    echo "  OK"
fi

echo ""
echo "▸ uBOLite (safari) をビルド（フィルタリストを落としてくるので数分かかる）..."
make mv3-safari
echo "  OK"

BUILT="$WORK/uBlock/dist/build/uBOLite.safari"
if [ ! -f "$BUILT/manifest.json" ]; then
    echo "エラー: ビルド結果に manifest.json が無い"
    echo "       $BUILT を確認すること"
    exit 1
fi

# ─────────────────────────────────────────
# 配置
# ─────────────────────────────────────────

echo ""
echo "▸ Extensions/uBOLite/ に配置..."
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$BUILT/" "$DEST/"

# rulesets/debug は実行時に使わない（manifest から一切参照されていない）。
# 各ルールセットを人間が検証するための展開形で、これだけで 42MB ある。
# manifest には手を触れないので、消しても「改変」にはならない
if [ -d "$DEST/rulesets/debug" ]; then
    rm -rf "$DEST/rulesets/debug"
    echo "  rulesets/debug を除外（実行時には使わない）"
fi

echo "$UBOL_TAG" > "$STAMP"

# ─────────────────────────────────────────
# 完了
# ─────────────────────────────────────────

SIZE="$(du -sh "$DEST" | cut -f1)"

echo ""
echo "══════════════════════════════════════"
echo " 完了"
echo "══════════════════════════════════════"
echo ""
echo "  uBlock Origin Lite $UBOL_TAG"
echo "  $DEST（$SIZE）"
echo ""
echo "次にやること:"
echo "  Xcode でビルドすれば、Run Script フェーズが"
echo "  Skyscraper.app/Contents/Resources/Extensions/ へ写す"
echo ""
