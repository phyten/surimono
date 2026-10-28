---
name: project-surimono-release
description: Cuts a Surimono release by choosing the version, pinning the commit whose CI passed, pushing a v* tag for exactly that commit to start the Release workflow, and verifying the published zip and checksum. Use when asked to release, tag, publish, or ship a new version of Surimono. Not for day-to-day builds (use project-surimono-dev).
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
3. バージョンを決める（SemVer。1.0 までは機能追加でマイナー、修正でパッチ。プレリリースは `0.2.0-beta.1` のようにハイフン付き）。
4. ユーザーに「v<X.Y.Z> を <SHA> から公開してよいか」を確認する。
5. 確認した SHA にタグを付けて push する（Release ワークフローがタグで起動する）。

   ```bash
   git tag "v<X.Y.Z>" "$SHA" && git push origin "v<X.Y.Z>"
   ```

   ワークフローの手動実行（`gh workflow run release.yml`）は使わない。`--ref` はブランチの先頭を指すだけで、確認した SHA に公開対象を固定できない（承認後に master が進むと別のコミットが公開される）。
6. 実行を見届ける: `gh run watch`。失敗したらログで原因を直してから再実行する。タグやリリースが途中まで作られていたら、消すかどうかをユーザーに確認する。
7. 成果物を確かめる: `gh release view v<X.Y.Z>` に `Surimono-<X.Y.Z>.zip` と `.sha256` があること。ダウンロードして `shasum -a 256 -c` で照合し、展開して起動する（アドホック署名なので `xattr -dr com.apple.quarantine Surimono.app` が必要な場合がある）。

## 補足

- アプリの `MARKETING_VERSION` はリリース時にワークフローが上書きする。`Configs/Base.xcconfig` の値は開発中の既定値。
- release.yml は、手動実行で既存のタグが別のコミットを指している場合、ビルドの前に停止する。
- Developer ID 署名・公証にはまだ対応していない。導入するときは Secrets（証明書、App Store Connect API キー）を追加して release.yml を拡張する。
