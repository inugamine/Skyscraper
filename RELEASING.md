# Skyscraper リリース手順

新しいバージョンを出すときは、上から順にやる。

## 0. 準備（初回だけ）

```sh
brew install create-dmg gh
gh auth login
xcrun notarytool store-credentials Skyscraper \
    --apple-id <Apple ID> --team-id 3WNHDR762B --password <App 用パスワード>
```

## 1. バージョンを上げる

Xcode → Target → General、あるいは Build Settings で:

| 項目 | 設定 | 例（1.0 → 1.1） |
|---|---|---|
| `MARKETING_VERSION` | 表示用バージョン | `1.0` → `1.1` |
| `CURRENT_PROJECT_VERSION` | ビルド番号 | `1` → `2` |

**ビルド番号は必ず上げる。** Sparkle は `CFBundleVersion`（= ビルド番号）だけを見て
新しいかどうか判断する。ここを上げ忘れると、誰にも更新が降りない。

上げたらコミットしておく。

```sh
git commit -am "Bump version to 1.1 (build 2)"
git push
```

## 2. アプリを書き出す

Xcode → Product → Archive → Distribute App → **Direct Distribution**
→ 書き出した `Skyscraper.app` を（例えば）デスクトップに置く。

Apple の公証が終わるまで待つ。Organizer に "Ready to distribute" が出たら OK。

## 3. パッケージング

```sh
./release.sh 1.1 ~/Desktop/Skyscraper.app
```

やってくれること:

- 署名・公証の確認
- Sparkle 用 zip の作成（`dist/Skyscraper-1.1.zip`）
- dmg の作成・署名・公証・staple（`dist/Skyscraper-1.1.dmg`）

## 4. リリースノートを書く

```sh
vi dist/notes-1.1.md
```

箇条書きで書く。これが GitHub Release の本文にも、appcast の更新内容にもなる。

```md
- ブックマークバーの並び替えを追加
- ⌘F でページ内検索できるようにした
```

## 5. 公開

```sh
./publish.sh 1.1 2 dist/notes-1.1.md
```

やってくれること:

1. zip の Sparkle 署名とバイト数を取得
2. GitHub Release を作成（タグ `v1.1`、dmg と zip を添付）
3. `appcast.xml` に item を追加
4. `appcast.xml` を commit & push
5. `inugamine.live-on.net` に dmg を転送（`scp`）

**順番が大事。** Release で zip を上げてから appcast を push する。逆にやると、
まだ存在しない URL を Sparkle が掴んで 404 になる。

## 6. 確認

- Release ページに dmg と zip が両方あるか
- `https://raw.githubusercontent.com/inugamine/Skyscraper/master/appcast.xml` が更新されてるか
- **古いバージョンの Skyscraper.app を起動して、更新ダイアログが出るか**
  （ここまでやらないと、リリースが成功したとは言えない）

## 手動で直す場合

`publish.sh` が途中でコケたら、以下を手でやれる。

```sh
# Sparkle 署名（edSignature と length が出る）
$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f | head -1) dist/Skyscraper-1.1.zip

# Release だけ作り直す
gh release delete v1.1 --cleanup-tag
gh release create v1.1 dist/Skyscraper-1.1.dmg dist/Skyscraper-1.1.zip \
    --title "Skyscraper 1.1" --notes-file dist/notes-1.1.md

# サーバーへ転送
scp dist/Skyscraper-1.1.dmg pi5@raspi5:/var/www/flask_static/skyscraper/Skyscraper-1.1.dmg
```
