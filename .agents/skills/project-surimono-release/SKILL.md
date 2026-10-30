---
name: project-surimono-release
description: Cuts a Surimono release by choosing the version, pinning the commit whose CI passed, pushing a v* tag for exactly that commit to start the Release workflow, and verifying the published DMG, zip, checksums, and the appcast that installed copies update from. Use when asked to release, tag, publish, or ship a new version of Surimono. Not for day-to-day builds (use project-surimono-dev).
---

# project-surimono-release

公開操作を含むため、**実行前にユーザーの明示的な許可を取る**。許可を求めるときは、バージョンと公開するコミット（SHA）を示す。

## 手順

1. 公開するコミットを決める。原則は最新の master。

   ```bash
   git fetch origin
   SHA=$(git rev-parse origin/master)
   ```

2. **そのコミット**の CI が成功していることを確かめる（master の最新の実行ではなく、SHA で絞る）。

   ```bash
   gh run list --workflow CI --commit "$SHA" --json conclusion,headSha --jq '.[0]'
   ```

   `conclusion` が `success` でなければリリースしない。
3. バージョンを決める（SemVer。1.0 までは機能追加でマイナー、修正でパッチ）。書式は `X.Y.Z` か、ベータの `X.Y.Z-beta.N` だけ（先頭に 0 を付けない。Y と Z は 0〜99、N は 1〜98）。ほかの書式（`-rc.1` など）は Release ワークフローの `Determine version` で止まる。
4. ユーザーに「v<X.Y.Z> を <SHA> から公開してよいか」を確認する。アプリ内アップデートで、入れてある全員に届くことも伝える（プレリリースは届かない）。
   - `gh secret list` に `SPARKLE_PRIVATE_KEY` があることも確かめる（無いとワークフローは署名の前に止まる）。
5. 確認した SHA にタグを付けて push する（Release ワークフローがタグで起動する）。

   ```bash
   git tag "v<X.Y.Z>" "$SHA" && git push origin "v<X.Y.Z>"
   ```

   ワークフローの手動実行（`gh workflow run release.yml`）は使わない。`--ref` はブランチの先頭を指すだけで、確認した SHA に公開対象を固定できない（承認後に master が進むと別のコミットが公開される）。
6. 実行を見届ける: `gh run watch`。失敗したらログで原因を直してから再実行する。タグやリリースが途中まで作られていたら、消すかどうかをユーザーに確認する。
7. 成果物を確かめる: `gh release view v<X.Y.Z>` に `Surimono-<X.Y.Z>.dmg`・`Surimono-<X.Y.Z>.zip` と、それぞれの `.sha256` があること。ダウンロードして `shasum -a 256 -c` で照合し、DMG を開いて（`hdiutil attach`）、中に Surimono.app と Applications へのリンクがあることを確かめる。正式版なら、`curl -sL https://github.com/phyten/surimono/releases/latest/download/appcast.xml` に、この版の `sparkle:shortVersionString`・`sparkle:version`（ビルド番号）・この版の ZIP の URL・`sparkle:edSignature` があることも確かめる。アプリの版とビルド番号が補足の決め方どおりであること（v0.3.0-beta.1 なら `0.3.0` と `30001`）を `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' Surimono.app/Contents/Info.plist` で確かめてから起動する。アドホック署名なので Gatekeeper に止められる。macOS 15 以降は Finder の右クリック →「開く」では越えられないため、リリースノートの手順（システム設定の「プライバシーとセキュリティ」→「このまま開く」）で開けることを確かめる。起動だけを手早く確かめるなら、`xattr -dr com.apple.quarantine Surimono.app`（ダウンロードで付いた隔離の印を消し、Gatekeeper の確認を省く）でもよい。
8. 正式版を出したら、`Configs/Base.xcconfig` の `MARKETING_VERSION`（開発中の既定値）を次の版（ふつうは次のマイナー。0.1.0 を出したら 0.2.0）に上げる PR を出す。手元や CI のビルドが公開版と同じ版を名乗ると、どちらなのかを版で見分けられないため。

## 補足

- アプリの `MARKETING_VERSION`（CFBundleShortVersionString）は、リリース時にワークフローがタグの `X.Y.Z` で上書きする。Apple の書式は整数 3 つだけなので、ベータの印（`-beta.N`）はタグ・リリース名・prerelease・ZIP のファイル名にだけ付ける。`Configs/Base.xcconfig` の値は開発中の既定値。
- ビルド番号（`CURRENT_PROJECT_VERSION`、CFBundleVersion）もワークフローがタグから計算する: `MAJOR×1000000 + MINOR×10000 + PATCH×100 + S`（正式版は S = 99、beta.N は S = N）。例: 0.2.0 → 20099、0.3.0-beta.1 → 30001、0.3.0 → 30099、あとから出す 0.2.1 → 20199。Sparkle などの更新の仕組みはこの値で新旧を比べるため、実行番号（`github.run_number`）は使わない（ベータのあとに旧系列の修正版を出すと大小が逆転する）。同じ版を出し直すと同じ番号になる。
- release.yml は、手動実行で既存のタグが別のコミットを指している場合、ビルドの前に停止する。
- リリースノートの起動の案内は release.yml の `Publish release` にある。macOS 15 以降は右クリック →「開く」で Gatekeeper を越えられない（[Apple の告知](https://developer.apple.com/news/?id=saqachfa)）ので、その案内に戻さない。手順は [Mac でアプリを安全に開く](https://support.apple.com/ja-jp/102445) に合わせる。
- Developer ID 署名・公証にはまだ対応していない。導入するときは Secrets（証明書、App Store Connect API キー）を追加して release.yml を拡張し、`Configs/Surimono.entitlements` の `com.apple.security.cs.disable-library-validation`（アドホック署名で Sparkle を読み込むためのもの）を消す。
- アプリ内アップデート（Sparkle）は、各リリースの `appcast.xml` を `releases/latest/download/appcast.xml` で読む。ワークフローが Secret `SPARKLE_PRIVATE_KEY` で ZIP に EdDSA 署名して appcast を作る。秘密鍵の控えはメンテナのログインキーチェーン（アカウント `io.github.phyten.Surimono`）にある。なくすと既存の利用者は更新を確かめられなくなるので、キーチェーンのバックアップを保つ。
