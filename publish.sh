#!/bin/bash
#
# publish.sh — release.sh で作った成果物を世に出す
#
# 使い方:
#   ./publish.sh <バージョン> <ビルド番号> [リリースノートのファイル]
#
# 例:
#   ./publish.sh 1.1 2 notes-1.1.md
#
# 前提:
#   - 先に ./release.sh を通してあること（dist/ に dmg と zip がある）
#   - gh コマンドがログイン済み（gh auth login）
#   - raspi5 に鍵で ssh できること
#
# やること:
#   1. zip の長さと Sparkle 署名を取る
#   2. GitHub Release を作って dmg と zip を上げる（タグ: vX.Y）
#   3. appcast.xml に新しい item を差し込む
#   4. appcast.xml を commit & push
#   5. dmg を inugamine.live-on.net に置く
#

set -euo pipefail

cd "$(dirname "$0")"

# ─────────────────────────────────────────
# 設定
# ─────────────────────────────────────────

REPO_URL="https://github.com/inugamine/Skyscraper"
MIN_SYSTEM="26.5"
SERVER="pi5@raspi5"
SERVER_DIR="/var/www/flask_static/skyscraper"

# ─────────────────────────────────────────
# 引数チェック
# ─────────────────────────────────────────

if [ $# -lt 2 ]; then
    echo "使い方: $0 <バージョン> <ビルド番号> [リリースノートのファイル]"
    echo "例:     $0 1.1 2 notes-1.1.md"
    exit 1
fi

VERSION="$1"
BUILD="$2"
NOTES_FILE="${3:-}"

DMG="dist/Skyscraper-$VERSION.dmg"
ZIP="dist/Skyscraper-$VERSION.zip"

for f in "$DMG" "$ZIP"; do
    if [ ! -f "$f" ]; then
        echo "エラー: $f がない。先に ./release.sh $VERSION <app のパス> を通せ。"
        exit 1
    fi
done

if ! command -v gh >/dev/null 2>&1; then
    echo "エラー: gh がない。brew install gh してから gh auth login しろ。"
    exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "エラー: タグ v$VERSION がもうある。バージョンを上げ忘れてないか？"
    exit 1
fi

echo "══════════════════════════════════════"
echo " Skyscraper $VERSION (build $BUILD) を公開する"
echo "══════════════════════════════════════"

# ─────────────────────────────────────────
# 1. Sparkle 署名と長さ
# ─────────────────────────────────────────

echo ""
echo "▸ 自動更新用の署名を生成..."
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
    echo "エラー: sign_update が見つからない。一度 Xcode でビルドして Sparkle を取ってこい。"
    exit 1
fi

# 出力例: sparkle:edSignature="xxxx" length="123456"
SIG_LINE="$("$SIGN_UPDATE" "$ZIP")"
ED_SIG="$(echo "$SIG_LINE" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(stat -f%z "$ZIP")"

if [ -z "$ED_SIG" ]; then
    echo "エラー: 署名が取れなかった。出力: $SIG_LINE"
    exit 1
fi

echo "  edSignature: ${ED_SIG:0:20}..."
echo "  length     : $LENGTH bytes"

# ─────────────────────────────────────────
# 2. リリースノート
# ─────────────────────────────────────────

if [ -z "$NOTES_FILE" ]; then
    NOTES_FILE="dist/notes-$VERSION.md"
    if [ ! -f "$NOTES_FILE" ]; then
        cat > "$NOTES_FILE" <<EOF
- ここに変更点を書く
EOF
        echo ""
        echo "▸ $NOTES_FILE を作った。中身を書いてから、もう一度このスクリプトを走らせろ。"
        exit 0
    fi
fi

echo ""
echo "▸ リリースノート ($NOTES_FILE):"
sed 's/^/  /' "$NOTES_FILE"

echo ""
read -r -p "この内容で GitHub に公開していいか？ [y/N] " ans
[ "$ans" = "y" ] || { echo "やめた。"; exit 1; }

# ─────────────────────────────────────────
# 3. GitHub Release
# ─────────────────────────────────────────

echo ""
echo "▸ GitHub Release を作成（タグ: v$VERSION）..."
gh release create "v$VERSION" \
    "$DMG" "$ZIP" \
    --title "Skyscraper $VERSION" \
    --notes-file "$NOTES_FILE"
echo "  OK"

# ─────────────────────────────────────────
# 4. appcast.xml を更新
# ─────────────────────────────────────────

echo ""
echo "▸ appcast.xml に item を追加..."

PUB_DATE="$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")"

# Markdown の箇条書きを、そのまま <li> に流し込む
NOTES_HTML="$(sed -n 's/^[-*] \{0,\}//p' "$NOTES_FILE" | sed 's|^|          <li>|; s|$|</li>|')"

ITEM="$(cat <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>Skyscraper $VERSION</h2>
        <ul>
$NOTES_HTML
        </ul>
      ]]></description>
      <enclosure
        url="$REPO_URL/releases/download/v$VERSION/Skyscraper-$VERSION.zip"
        sparkle:edSignature="$ED_SIG"
        length="$LENGTH"
        type="application/octet-stream" />
    </item>

EOF
)"

# 最初の <item> の直前に差し込む（新しい順に並ぶ）
ITEM="$ITEM" python3 - <<'PY'
import os, re
path = "appcast.xml"
src = open(path, encoding="utf-8").read()
item = os.environ["ITEM"]
if "<item>" in src:
    src = src.replace("    <item>", item + "    <item>", 1)
else:
    src = src.replace("  </channel>", item + "  </channel>", 1)
open(path, "w", encoding="utf-8").write(src)
PY

echo "  OK"

# ─────────────────────────────────────────
# 5. appcast を push
# ─────────────────────────────────────────

echo ""
echo "▸ appcast.xml を push..."
git add appcast.xml
git commit -m "Update appcast for $VERSION"
git push origin HEAD
echo "  OK（ここで初めて、既存ユーザーに更新が見える）"

# ─────────────────────────────────────────
# 6. 自分のサーバーに置く
# ─────────────────────────────────────────

echo ""
read -r -p "inugamine.live-on.net にも dmg を置くか？ [y/N] " ans
if [ "$ans" = "y" ]; then
    echo "▸ 転送中..."
    scp "$DMG" "$SERVER:$SERVER_DIR/Skyscraper-$VERSION.dmg"
    echo "  OK"
fi

echo ""
echo "══════════════════════════════════════"
echo " Skyscraper $VERSION、出荷完了"
echo "══════════════════════════════════════"
echo ""
echo "確認しとけ:"
echo "  Release : $REPO_URL/releases/tag/v$VERSION"
echo "  appcast : https://raw.githubusercontent.com/inugamine/Skyscraper/master/appcast.xml"
echo "  古い版の Skyscraper.app を起動して、更新が降ってくるか見ること"
echo ""
