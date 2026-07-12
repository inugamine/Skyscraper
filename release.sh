#!/bin/bash
#
# release.sh — Skyscraper のリリース作業を一括で行う
#
# 使い方:
#   ./release.sh <バージョン> <Skyscraper.app のパス>
#
# 例:
#   ./release.sh 1.0 ~/Desktop/Skyscraper.app
#
# 事前に必要なもの:
#   - 署名・公証済みの Skyscraper.app（Xcode の Archive → Distribute で書き出したもの）
#   - create-dmg（brew install create-dmg）
#   - xcrun notarytool store-credentials で保存した認証プロファイル
#

set -euo pipefail

# ─────────────────────────────────────────
# 設定（環境に合わせてここを直す）
# ─────────────────────────────────────────

# notarytool のプロファイル名（store-credentials で付けた名前）
NOTARY_PROFILE="${NOTARY_PROFILE:-Skyscraper}"

# Developer ID Application 証明書の名前
SIGN_ID="Developer ID Application: Shota Nakamura (3WNHDR762B)"

# dmg の背景画像
BG_IMAGE="$(dirname "$0")/dmg-background.png"

# ─────────────────────────────────────────
# 引数チェック
# ─────────────────────────────────────────

if [ $# -lt 2 ]; then
    echo "使い方: $0 <バージョン> <Skyscraper.app のパス>"
    echo "例:     $0 1.0 ~/Desktop/Skyscraper.app"
    exit 1
fi

VERSION="$1"
APP_PATH="$2"

if [ ! -d "$APP_PATH" ]; then
    echo "エラー: $APP_PATH が見つからない"
    exit 1
fi

OUT_DIR="$(pwd)/dist"
mkdir -p "$OUT_DIR"

DMG_PATH="$OUT_DIR/Skyscraper-$VERSION.dmg"
ZIP_PATH="$OUT_DIR/Skyscraper-$VERSION.zip"

echo "══════════════════════════════════════"
echo " Skyscraper $VERSION のリリース作業"
echo "══════════════════════════════════════"

# ─────────────────────────────────────────
# 0. アプリが署名・公証済みか確認
# ─────────────────────────────────────────

echo ""
echo "▸ アプリの署名を確認..."
if ! spctl -a -vvv -t install "$APP_PATH" 2>&1 | grep -q "accepted"; then
    echo "エラー: このアプリは署名・公証されていない。"
    echo "       Xcode の Archive → Distribute App から書き出したものを使うこと。"
    exit 1
fi
echo "  OK（署名・公証済み）"

# ─────────────────────────────────────────
# 1. Sparkle 用の zip を作る
# ─────────────────────────────────────────

echo ""
echo "▸ 自動更新用の zip を作成..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
echo "  $ZIP_PATH"

# ─────────────────────────────────────────
# 2. dmg を作る
# ─────────────────────────────────────────

echo ""
echo "▸ dmg を作成..."
rm -f "$DMG_PATH"

DMG_ARGS=(
    --volname "Skyscraper"
    --window-pos 200 120
    --window-size 660 420
    --icon-size 110
    --icon "Skyscraper.app" 195 200
    --app-drop-link 465 200
    --no-internet-enable
)

# 背景画像があれば使う
if [ -f "$BG_IMAGE" ]; then
    DMG_ARGS+=(--background "$BG_IMAGE")
else
    echo "  （背景画像が見つからないので、無地で作る）"
fi

create-dmg "${DMG_ARGS[@]}" "$DMG_PATH" "$APP_PATH"
echo "  $DMG_PATH"

# ─────────────────────────────────────────
# 3. dmg に署名する
# ─────────────────────────────────────────

echo ""
echo "▸ dmg に署名..."
codesign --force --sign "$SIGN_ID" "$DMG_PATH"
echo "  OK"

# ─────────────────────────────────────────
# 4. dmg を公証する
# ─────────────────────────────────────────

echo ""
echo "▸ dmg を Apple に送って公証（数分かかる）..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# ─────────────────────────────────────────
# 5. 公証結果を dmg に貼り付ける
# ─────────────────────────────────────────

echo ""
echo "▸ 公証結果を dmg に貼り付け（staple）..."
xcrun stapler staple "$DMG_PATH"
echo "  OK"

# ─────────────────────────────────────────
# 6. 最終確認
# ─────────────────────────────────────────

echo ""
echo "▸ 最終確認..."
spctl -a -vvv -t install "$DMG_PATH" 2>&1 | sed 's/^/  /'

# ─────────────────────────────────────────
# 7. Sparkle 用の署名を出す
# ─────────────────────────────────────────

echo ""
echo "▸ 自動更新用の署名を生成..."
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1)"

if [ -n "$SIGN_UPDATE" ]; then
    SIG_LINE="$("$SIGN_UPDATE" "$ZIP_PATH")"
    echo "  $SIG_LINE"
else
    echo "  sign_update が見つからない。手動で実行すること。"
    SIG_LINE=""
fi

# ─────────────────────────────────────────
# 完了
# ─────────────────────────────────────────

echo ""
echo "══════════════════════════════════════"
echo " 完了"
echo "══════════════════════════════════════"
echo ""
echo "できたもの:"
echo "  配布用   : $DMG_PATH"
echo "  自動更新用: $ZIP_PATH"
echo ""
echo "次にやること:"
echo "  1. GitHub Releases に zip と dmg を上げる（タグ: v$VERSION）"
echo "  2. appcast.xml を更新する:"
if [ -n "$SIG_LINE" ]; then
    echo "     $SIG_LINE"
fi
echo "  3. appcast.xml を master に push する"
echo "  4. 自分のサーバーの公開ページから dmg にリンクする"
echo ""
