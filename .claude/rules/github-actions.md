---
paths:
  - ".github/workflows/**"
  - ".github/dependabot.yml"
---

# GitHub Actions の細則

- Action はコミット SHA で固定し、行末にバージョンコメントを付ける（例: `actions/checkout@<sha> # v7.0.1`）。更新は Dependabot に任せる。
- `permissions` は最小にする（CI は `contents: read`、リリースと `stats` ブランチへ書くダウンロード数の集計だけ `contents: write`）。
- `ci.yml` のジョブ ID `build-and-test` は master の ruleset の必須チェック名。原則として変えない。変える場合は ruleset も同時に更新する。
- Xcode は `DEVELOPER_DIR` で固定する。上げるときは GitHub の runner image の README で存在を確認し、AGENTS.md の CI の記述も更新する。
- `${{ }}` をシェルに直接埋め込まず、`env:` 経由で渡す。
- Secrets をログに出さない。フォークからの PR で Secrets が必要な処理を動かさない。
