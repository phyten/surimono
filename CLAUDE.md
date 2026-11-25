# CLAUDE.md

@AGENTS.md

## Claude Code 向けの補足

- 描画・UI の変更では AGENTS.md「スナップショット（見た目の回帰）」と `project-surimono-snapshots` の手順に従う。

- 正本は上の AGENTS.md。ここには Claude Code 固有のことだけを書く。
- スキル: `.claude/skills/` は `.agents/skills/` へのシンボリックリンク（Codex と共有）。ビルド・起動・目視確認は `project-surimono-dev`、印刷レイアウトは `project-surimono-print-layout` を使う。
- パス別の細則は `.claude/rules/` にあり、対象ファイルを扱うときに自動で読み込まれる。
- UI を変えたら `make run` で起動し、computer-use の `app_screenshot` でライト / ダークの両方を見てから完了とする。
- 確認のために作った物は残さない（AGENTS.md の「テスト」）。computer-use や `open` で開発版・公開版を起動して確かめたら、自分が起動したプロセスを終了し、試した文書の設定（「この文書の設定を戻す」）、「最近使ったファイル」、scratchpad の一時ファイルを片付けてから完了とする。
- 検証用の仮想マシン（AGENTS.md の「検証用の仮想マシン」）の中は、確認を取らずに操作してよい。画面の操作は computer-use で UTM のウインドウ越しに行い、コマンドは SSH で流す。ホストの側の操作は、今までどおりの決まりに従う。
- `.docs/`（企画書・デザインモック）はローカル専用。参照してよいが、コミットや PR 本文に転記しない。
- `.claude/settings.json` の allow にはビルド・テスト・読み取り系のコマンドだけを入れる。make とパッケージのビルド・テストは引数まで含めた完全一致にする（`Bash(make lint *)` は `make lint clean …` まで許してしまう）。末尾のワイルドカードは、読み取りだけのサブコマンド（`xcodebuild -list`、`xcrun swift-format lint`、`gh pr view` など）に限る。push・merge・リリースを自動許可に加えない。
