# CLAUDE.md

@AGENTS.md

## Claude Code 向けの補足

- 正本は上の AGENTS.md。ここには Claude Code 固有のことだけを書く。
- スキル: `.claude/skills/` は `.agents/skills/` へのシンボリックリンク（Codex と共有）。ビルド・起動・目視確認は `project-surimono-dev`、印刷レイアウトは `project-surimono-print-layout` を使う。
- パス別の細則は `.claude/rules/` にあり、対象ファイルを扱うときに自動で読み込まれる。
- UI を変えたら `make run` で起動し、computer-use の `app_screenshot` でライト / ダークの両方を見てから完了とする。
- `.docs/`（企画書・デザインモック）はローカル専用。参照してよいが、コミットや PR 本文に転記しない。
- `.claude/settings.json` の allow にはビルド・テスト・読み取り系のコマンドだけを入れる。make とパッケージのビルド・テストは引数まで含めた完全一致にする（`Bash(make lint *)` は `make lint clean …` まで許してしまう）。末尾のワイルドカードは、読み取りだけのサブコマンド（`xcodebuild -list`、`xcrun swift-format lint`、`gh pr view` など）に限る。push・merge・リリースを自動許可に加えない。
