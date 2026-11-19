---
paths:
  - "Packages/SurimonoKit/Sources/SurimonoCore/Resources/*.css"
  - "Packages/SurimonoKit/Sources/SurimonoFormats/**"
  - "Packages/SurimonoKit/Sources/SurimonoRendering/**"
  - "App/**/*.swift"
---

# 見た目の回帰

描画・スタイル・LaTeX の読み取り・UI を変更したら `make snapshots && make snapshots-report` を実行する。report.html の該当ページと report.json を読み、ケース ID と差の大きさを報告する。意図した差だけを `make snapshots-approve ONLY="id id"` で承認し、原因の変更と同じコミットに含める。確認前に承認しない。手順は AGENTS.md「スナップショット（見た目の回帰）」と project-surimono-snapshots を参照する。

UI 撮影を変更したら `make snapshots-selfcheck` で独立した2巡と同倍率の承認画像をレポートと同じ許容値で比較する。`within tolerance` も完全一致と区別し、変更画素数と外接矩形を報告する。キー状態・アプリのアクティブ状態は診断用。`unstable` や描画待ちの失敗は承認せず、ケースID・変更画素数・外接矩形または待ちの理由を報告する。

文書とUIの基準はメインディスプレイの倍率別。倍率を替えたらレポート見出しの倍率を確認する。基準なし（ツール終了コード3）の場合は、その倍率で全件を撮影し、現在の画像・本文・実TeXとの差を確認してから初回承認する。タイムアウトは `run.json` の `timeoutDetails` とケースフォルダーの sample を確認する。
