---
paths:
  - ".github/workflows/**"
  - ".github/dependabot.yml"
---

# GitHub Actions の細則

- Action はコミット SHA で固定し、行末にバージョンコメントを付ける（例: `actions/checkout@<sha> # v7.0.1`）。更新は Dependabot に任せる。
- `permissions` は最小にする（CI は `contents: read`、リリースと `stats` ブランチへ書くダウンロード数の集計だけ `contents: write`）。
- `ci.yml` のジョブ ID `build-and-test` は master の ruleset の必須チェック名。原則として変えない。変える場合は ruleset も同時に更新する。
  - macOS の実行時間はビルドに使う。毎回走るのは `package`（`make package`）だけ。テストと App Store 版の確認（`lint-and-core`・`rendering`・`app-tests`・`appstore`）は、PR にラベル `ci:test` が付いているときと、ワークフローを手で起動したとき（どのブランチでも全部走る）だけ走る。
  - `build-and-test` は自分では何も組み立てない門番のジョブ（Linux）で、macOS のジョブをすべて `needs` に持ち、`if: always()` で必ず走る。`package` が `success` で、ほかのジョブが `success` か `skipped`（ラベルなしで走らなかった）のときだけ通る。走って失敗・取り消しになったジョブがあれば落ちる。ジョブを足したら `needs` にも足す（足さないと、そのジョブが落ちてもマージできてしまう）。
  - 門番に `!cancelled()` や既定の `success()` を使わない。スキップされたジョブは必須チェックとして成功の扱いになるので、取り消しや依存の失敗で門番がスキップされると、通っていないのにマージできてしまう。
  - macOS のジョブは、このアカウントで同時に 5 つまでしか走らない。5 つを超えて足さない（超えた分は待ち、全体が遅くなる）。
- Xcode は `DEVELOPER_DIR` で固定する。上げるときは GitHub の runner image の README で存在を確認し、AGENTS.md の CI の記述も更新する。
- `${{ }}` をシェルに直接埋め込まず、`env:` 経由で渡す。
- Secrets をログに出さない。フォークからの PR で Secrets が必要な処理を動かさない。
