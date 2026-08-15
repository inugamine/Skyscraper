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

# dmg の背景画像（等倍 660x420。--window-size と必ず一致させること）
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

# ───────────────────────────────────────
# 0.1 バージョンの照らし合わせ
# ───────────────────────────────────────

# 引数で渡されたバージョンと、実際にビルドされた app の中身が
# 食い違っていないか見る。ここを見ておかないと、
# バージョンを上げ忘れた app を 1.1 として出してしまう
echo ""
echo "▸ バージョンを確認..."

APP_PLIST="$APP_PATH/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo '')"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST" 2>/dev/null || echo '')"

if [ -z "$APP_BUILD" ]; then
    echo "エラー: app からビルド番号を読めなかった"
    exit 1
fi

echo "  表示バージョン: $APP_VERSION"
echo "  ビルド番号    : $APP_BUILD"

if [ "$APP_VERSION" != "$VERSION" ]; then
    echo ""
    echo "エラー: 引数のバージョン（${VERSION}）と"
    echo "       app の MARKETING_VERSION（${APP_VERSION}）が違う。"
    echo "       どちらかが間違っている。"
    exit 1
fi

# ビルド番号を控えておく。publish.sh がこれを読むので、
# 向こうで手打ちする必要がなくなる（打ち間違えの事故を潰す）
echo "$APP_BUILD" > "$OUT_DIR/build-$VERSION.txt"

# ───────────────────────────────────────
# 0.2 同梱した拡張機能の確認
# ───────────────────────────────────────

# Run Script フェーズが黙って失敗してもビルドは通るので、
# ここで実物を見る。見ないと「広告が消えない版」を出荷しかねない
echo ""
echo "▸ 同梱した拡張機能を確認..."

EXT_DIR="$APP_PATH/Contents/Resources/Extensions"

if [ ! -d "$EXT_DIR" ]; then
    echo "エラー: $EXT_DIR がない。"
    echo ""
    echo "       思い当たる原因:"
    echo "       ・./fetch-extensions.sh を叩いていない"
    echo "       ・Build Settings の User Script Sandboxing が Yes"
    echo "         （Release 構成だけ Yes のことがある）"
    echo "       ・Run Script フェーズ「Copy Bundled Extensions」が無いか、"
    echo "         Copy Bundle Resources より前にある"
    exit 1
fi

EXT_COUNT=0
for ext in "$EXT_DIR"/*/; do
    [ -d "$ext" ] || continue
    name="$(basename "$ext")"
    if [ ! -f "$ext/manifest.json" ]; then
        echo "エラー: $name に manifest.json がない"
        exit 1
    fi
    # manifest から "version": "x.y.z" を拾う。
    # set -u の下では代入が飛ぶと即死するので、
    # 先に空で初期化してから入れる
    ext_version=""
    ext_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ext/manifest.json" | head -1)"
    [ -n "$ext_version" ] || ext_version="?"
    ext_size="$(du -sh "$ext" | cut -f1)"
    # 変数名の直後に全角括弧を置くと、bash がその先頭バイトまで
    # 変数名として食うことがある。必ず ${} で区切る
    echo "  ${name} ${ext_version}（${ext_size}）"
    EXT_COUNT=$((EXT_COUNT + 1))
done

if [ "$EXT_COUNT" -eq 0 ]; then
    echo "エラー: Extensions はあるが中身が空だ。"
    echo "       ./fetch-extensions.sh を叩いてから Archive し直すこと。"
    exit 1
fi

# ───────────────────────────────────────
# 0.25 プロビジョニングプロファイルの確認
# ───────────────────────────────────────

# iCloud（CloudKit）を使うようになった時点で、この app は
# 「プロファイルが埋まっていないと動かない」代物になった。
#
# 埋め忘れが恐ろしいのは、こちらの手元では気づけないことだ。
# Xcode から走らせる分には Development の署名で動いてしまうし、
# 出荷した dmg も普通に開いてインストールできる。
# 起動しなくなるのは配った先だけだ。
#
# しかも Gatekeeper はプロファイルを「毎回の起動時」に見る。
# 期限が切れた日に、既に入っている全員の手元で一斉に起動しなくなる。
# 出す前にここで見ておく
echo ""
echo "▸ プロビジョニングプロファイルを確認..."

PROFILE="$APP_PATH/Contents/embedded.provisionprofile"

if [ ! -f "$PROFILE" ]; then
    echo "エラー: $PROFILE がない。"
    echo ""
    echo "       この app は iCloud の権限を持っているので、"
    echo "       プロファイルが埋まっていないと配った先で起動しない。"
    echo ""
    echo "       Xcode の Archive → Distribute App からやり直すこと。"
    echo "       署名なしで書き出したり、後から codesign で上書きすると"
    echo "       このファイルが落ちる。"
    exit 1
fi

# プロファイルは CMS で包まれているので、剥いてから中の plist を読む
PROFILE_PLIST="$(mktemp -t skyscraper-profile)"
trap 'rm -f "$PROFILE_PLIST"' EXIT

if ! security cms -D -i "$PROFILE" -o "$PROFILE_PLIST" 2>/dev/null; then
    echo "エラー: プロファイルを開けない（壊れている可能性）"
    exit 1
fi

PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST" 2>/dev/null || echo '?')"
echo "  名前: $PROFILE_NAME"

# ── 期限 ──
#
# 2017年2月22日より後に作ったものは作成から18年もつので、
# 普通は引っかからない。それでも見るのは、切れた時の被害が
# 「配った全員の手元で起動しなくなる」という形で出るからだ。
# 一年を切ったら知らせる
EXPIRY="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$PROFILE_PLIST" 2>/dev/null || echo '')"

if [ -n "$EXPIRY" ]; then
    # PlistBuddy が返すのは "Sat Aug 15 15:21:00 JST 2044" の形。
    # date に食わせて数字に直す（失敗しても止めない——
    # 期限の読み取りに失敗したくらいで出荷を止める筋合いはない）
    EXPIRY_EPOCH="$(date -j -f "%a %b %d %T %Z %Y" "$EXPIRY" "+%s" 2>/dev/null || echo '')"
    if [ -n "$EXPIRY_EPOCH" ]; then
        NOW_EPOCH="$(date "+%s")"
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
        if [ "$DAYS_LEFT" -lt 0 ]; then
            echo "エラー: プロファイルの期限が切れている（${EXPIRY}）"
            echo "       このまま出すと、配った先で起動しない。"
            exit 1
        elif [ "$DAYS_LEFT" -lt 365 ]; then
            echo "  警告: 期限まで残り ${DAYS_LEFT} 日（${EXPIRY}）"
            echo "        切れる前にプロファイルを作り直すこと"
        else
            echo "  期限: ${EXPIRY}（残り ${DAYS_LEFT} 日）"
        fi
    else
        echo "  期限: $EXPIRY"
    fi
fi

# ── 実際に署名へ乗った権限 ──
#
# 見るのは entitlements ファイルの中身ではなく、署名済みの app から
# 取り出したものだ。書いたつもりと、実際に焼かれたものは別物になり得る
ECHO_ENT="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null || echo '')"

if [ -z "$ECHO_ENT" ]; then
    echo "エラー: app から entitlements を読めなかった"
    exit 1
fi

for key in \
    com.apple.developer.icloud-services \
    com.apple.developer.icloud-container-identifiers
do
    if ! echo "$ECHO_ENT" | grep -q "$key"; then
        echo "エラー: 署名に $key が乗っていない"
        echo "       Skyscraper.entitlements が Build Settings の"
        echo "       CODE_SIGN_ENTITLEMENTS に結ばれているか確かめること"
        exit 1
    fi
done
echo "  iCloud の権限 OK"

# ── 見に行く先が本番かどうか ──
#
# ここが Development のまま出ると、配った先は誰も居ない物置を覗く。
# 起動もするし操作もできるので、事故に気づくのが遅れる質の悪い失敗だ。
#
# この値は entitlements ファイルには書いていない。Xcode が
# 署名の種類（Developer ID か否か）を見て自分で足す。
# だからこそ、こちらで書いた覚えのない値を目で確かめる意味がある。
#
# 読み取りに plutil を使うのは、XML を行で切ると事故るからだ。
# grep -A1 で「鍵の次の行」を取る手は、別の鍵の値を掍むことがある
#（実際、チーム ID を拾って誤報を出した）。
# 一旦ファイルに落として、構造として引く
ENT_PLIST="$(mktemp -t skyscraper-ent)"
trap 'rm -f "$PROFILE_PLIST" "$ENT_PLIST"' EXIT
echo "$ECHO_ENT" > "$ENT_PLIST"

ENV_VALUE="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$ENT_PLIST" 2>/dev/null || echo '')"

if [ -n "$ENV_VALUE" ]; then
    if [ "$ENV_VALUE" != "Production" ]; then
        echo "エラー: CloudKit の環境が Production ではない（${ENV_VALUE}）"
        echo "       Development のまま出すと、配った先は空の物置を見る。"
        echo "       Developer ID で署名し直すこと。"
        exit 1
    fi
    echo "  CloudKit の環境: Production"
else
    echo "  警告: icloud-container-environment が署名に無い"
    echo "        既定では Development 側を見に行く可能性がある"
fi

# ───────────────────────────────────────
# 0.3 ライセンス表記の照らし合わせ
# ───────────────────────────────────────

# uBOL は GPL-3.0 だ。「対応するソースの入手先」を示す義務があり、
# NOTICE と THIRD-PARTY-NOTICES.md にタグを書いている。
# UBOL_TAG を上げた時にここを直し忘れると、嘘の入手先を示すことになる。
# 実際にビルドしたタグ（.skyscraper-version）と見比べる
echo ""
echo "▸ ライセンス表記を確認..."

UBOL_STAMP="$EXT_DIR/uBOLite/.skyscraper-version"

if [ ! -f "$UBOL_STAMP" ]; then
    echo "  （uBOLite のタグ控えがないので飛ばす）"
else
    UBOL_TAG="$(cat "$UBOL_STAMP")"
    echo "  同梱している uBOL: $UBOL_TAG"

    NOTICE_NG=false

    for f in NOTICE THIRD-PARTY-NOTICES.md; do
        [ -f "$f" ] || continue
        # ファイルの中のバージョンらしい並びを拾って、
        # 実際のタグと違うものが混ざっていないか見る
        stale="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$f" 2>/dev/null \
                 | grep -v "^${UBOL_TAG}\$" | sort -u || true)"
        if ! grep -q "$UBOL_TAG" "$f" 2>/dev/null; then
            echo "エラー: $f に $UBOL_TAG の記述がない"
            NOTICE_NG=true
        elif [ -n "$stale" ]; then
            echo "  警告: $f に古いバージョン表記が残っているかもしれない"
            echo "$stale" | sed 's/^/        /'
        else
            echo "  $f OK"
        fi
    done

    if [ "$NOTICE_NG" = true ]; then
        echo ""
        echo "       uBOL のタグを上げたなら、下記を直すこと。"
        echo "       GPL-3.0 の「対応するソースの入手先」にあたる部分だ："
        echo "       ・NOTICE                  ... built from tag X.Y.Z"
        echo "       ・THIRD-PARTY-NOTICES.md  ... 同梱しているバージョン / tree の URL"
        exit 1
    fi
fi

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
    --icon-size 100
    --icon "Skyscraper.app" 165 190
    --app-drop-link 495 190
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
echo "  ./publish.sh ${VERSION}"
echo ""
echo "  ・ビルド番号（${APP_BUILD}）は dist/build-${VERSION}.txt に控えてあるので"
echo "    publish.sh に手で渡す必要はない"
echo "  ・GitHub Release・appcast.xml 更新・push・サーバー配置まで一括で行われる"
echo ""
