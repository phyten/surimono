---
name: project-surimono-snapshots
description: Surimono の描画・テーマ・LaTeX 読み取り・UI・撮影処理を変更したとき、倍率別の見た目の回帰と実 TeX への忠実度を検証し、意図した差だけを承認する。
---

# Surimono のスナップショット

## 撮影と比較

1. ログイン中の Mac のリポジトリルートで `make snapshots`、続いて `make snapshots-report` を実行する。調査中は `ONLY="id id"` または `ONLY="tag:latex"` で絞れる。
2. `Snapshots/.runs/latest` が指す run の `report.html` と `report.json` を読む。見出しで run と基準のメインディスプレイ倍率を確認する。
3. WebKit の文書組版も画面倍率に影響される。基準は `Snapshots/baseline/<倍率>x/` と `Snapshots/.baseline-visual/<倍率>x/` から選ばれる。メインディスプレイを替えて基準がなければツールは終了コード3を返す。make の表示は `Error 3`。現在の画像と実 TeX 比較はこのときも確認できる。
4. 新しい倍率を初期化するときは全件を撮影し、現在の画像・本文・エラーの有無・実 TeX との差を確認してから承認する。元の倍率で回帰を測るには、そのディスプレイをメインに戻して撮り直す。

## 結果を読む

- `report.json` の `counts`、各ケースの `status`・`notes` を確認する。`regression.metrics` の `pageDelta`、`maxShiftPt`、`maxBoxDeltaPt`、`changedAreaRatio`、`textEdits` をケースIDとともに報告する。面積は比率を100倍するとパーセントになる。
- `regression.pages` でページ画像・配置・変更領域を、`moves` と `edits` で本文の移動・追加・削除を確認する。LaTeX の `fidelity` は実 TeX との差、`previousFidelity` と `trend` は同じ倍率で前回承認した値からの推移。
- `run.json` の `displayScale`・`macOS`・`appearance` と、取得できたケースの `appearance`・`layoutScreen` を確認する。UI の `capture.appActive` と `isKeyWindow` は診断用。`unstable` や `readinessIssue` は承認前に調べる。

## UI撮影とタイムアウト

- 撮影処理を変えたら `make snapshots-selfcheck` を実行する。独立した2巡と各巡対同倍率の承認画像を比較する。巡間の `within tolerance` は `selfcheck.json` の `pixelStatus: "noise"` に対応する。完全一致と区別し、画素数と外接矩形を報告する。
- 保存済みの2巡は `make snapshots-selfcheck FIRST=selfcheck-<run>/first SECOND=selfcheck-<run>/second` で再検査できる。異なる倍率のrunを原寸で調べる場合だけ `FORCE_SCALE=1` を使う。
- UI は60秒、文書は180秒が上限。タイムアウト時は対象プロセスを sample し、1回再試行する。`run.json` の `timeouts`・`retrySucceeded`・`timeoutDetails` とケースフォルダーの `timeout-sample.txt` を読む。2回目も停止した場合は `timeout-sample-2.txt` も確認する。

## 承認・保管・ケース追加

- レポートで意図を確認したケースだけ `make snapshots-approve ONLY="id id"` で承認する。`ONLY` を省くと最新runの全件が対象になる。数値・本文の差分は原因の変更と同じコミットに含める。コミットの実行は作業時の権限指示に従う。
- Git にはコーパス原稿・実 TeX 参照・倍率別の数値と本文を含める。画像基準と `.runs/` はローカルに保管する。画像基準は対象倍率の画面で `make snapshots-baseline REF=<ref>`、実 TeX 参照は `make snapshots-reference` で再生成できる。画像付きレポートを共有するときは run フォルダー全体を使う。
- 新規ケースは `Snapshots/cases.json` に一意の `id`、`kind`、`input`、`arguments`、`tags` を持つ1項目を追加する。ウェルカムの `input` は `null`、実 TeX 参照のある文書は `reference` に3桁のIDを指定する。追加したIDを撮影・比較してから全件を確認する。
- GUI が使えない環境では `make lint` と `make test-tools` を実行し、保存画像で検証できたことと実機で未確認のことを報告する。
