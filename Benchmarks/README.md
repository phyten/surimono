# 描画の基準値

Surimono の描画時間と資源使用量を同じ手順で記録するための任意実行の計測です。性能の合否は付けず、測定結果による最適化も行いません。

## 実行

リポジトリのルートで、ほかの重い処理を止めて実行します。

```sh
make bench
SURIMONO_BENCH_RUNS=5 SURIMONO_BENCH_OUT=build/bench/local.json make bench
make bench-compare BASE=Benchmarks/baseline.json NEW=build/bench/local.json
make bench-compare BASE=Benchmarks/baseline.json NEW=build/bench/local.json BENCH_THRESHOLD=30
```

`make bench` は Debug の `RenderingBenchmarks` だけを直列実行します。各場面は準備運動 1 回を除外して既定 5 回測り、`SURIMONO_BENCH_RUNS` で正の整数に変更できます。全テーマと耐久の準備運動は、それぞれ全テーマ 1 周・100 回の切り替え 1 周です。計測全体には数十分かかることがあり、この任意テストだけ時間上限を 60 分にしています。個々の WebKit 処理は既存のタイムアウトを使います。

`SURIMONO_BENCH=1` がなければ `.enabled(if:)` によりスイート全体をスキップします。通常の `make test-kit` と必須 CI では計測処理を実行しません（テストコードのコンパイルは行います）。`SURIMONO_BENCH` を普段のシェルに常設しないでください。

結果は `build/bench/<UTC日時>-<8桁SHA>.json` に保存し、最後に絶対パスを表示します。`SURIMONO_BENCH_OUT` の相対パスはリポジトリルート基準です。処理に失敗した場合は不完全な結果を基準値として保存しません。

## 測る場面

| JSON の場面 ID | 内容と計測範囲 |
| --- | --- |
| `prepare/markdown-short` | `Samples/sample.md` の論理ページ作成 |
| `prepare/markdown-booklet` | `Samples/booklet-demo.md`（従来の目安 38 ページ）の論理ページ作成 |
| `prepare/org`, `html`, `csv` | それぞれ `Samples/sample.*` の論理ページ作成 |
| `prepare/markdown-200` | テスト内で 200 セクションと明示的な改ページを生成した Markdown |
| `prepare/latex` | テスト内で生成した見出し・本文・数式の短い LaTeX |
| `prepare/pdf-50` | テスト内で生成した 50 ページの PDF を準備 |
| `prepare/images-20` | テスト内で生成した 1024×768 px の色の異なる TIFF 20 枚を画像の束として準備 |
| `compose/a4Single`, `a4Duplex`, `a3BookletA4`, `a3TwoUp` | booklet-demo の準備済み論理 PDF を `PDFComposer` で面付け。組版を含めず、PDF のシリアライズを含む |
| `switch/<theme-id>` | 標準テーマで組版済みの renderer に別テーマを適用。目録順で標準以外の先頭 10 テーマを各 5 回。標準への復帰・キャッシュ消去は計測外 |
| `sample/<theme-id>` | `ThemeSampler` による booklet-demo の 1 ページ目。全組み込みテーマを目録順に描く。最初のテーマには WebView 初期読み込みも含む |
| `sample/all` | 全テーマの描画と、全見本を保持した時点のメモリ。各周で sampler を作り直し、計測後に close |
| `endurance/100-switches` | 1 つの renderer で 10 テーマを循環して 100 回切り替え。0 回目と以後 10 回ごとのメモリを `endurance` に保存 |

Samples は `#filePath` からルートをたどって読み、コピーも変更もしません。入力読み込み・テスト入力生成は計測外です。組版は毎回新しい renderer を使い、切り替えは毎回標準から始めるので、論理ページのキャッシュヒットを描画速度として数えません。面付けは用紙キャッシュを通しません。「乗せて試す」の文書全体の組版を測り、UI の待ち時間や最近 6 件の表示キャッシュは含めません。

ページ数は書体・OS・テーマで変わるため、38・200 を合否に使いません。各回の `outputCount` に実際の論理ページ数・用紙面数を記録します。見本では 1 または全テーマ数、耐久では切り替え回数 100 です。

## JSON と表の読み方

スキーマ版は `schemaVersion: 1` です。UTC 日時、完全なコミット SHA、未コミット変更の有無 (`dirty`)、macOS・Xcode、`sysctl hw.model`、CPU 数、回数、ビルド構成を保存します。`dirty: true` は同じ SHA でもコードが一致する保証がないため、変更差分と一緒に管理してください。

- 時間は `ContinuousClock` の経過時間をミリ秒にしたものです。`medianMS`・`minMS`・`maxMS` に準備運動を除いた中央値・最小・最大を保存します。偶数回では中央 2 値の平均です。
- `measurements` は各回の時間、開始前・終了後の `phys_footprint`（`beforeBytes`・`afterBytes`）、観測最大値 (`peakBytes`)、出力数です。増加量は `afterBytes - beforeBytes`（符号付き）で読めます。
- `task_vm_info` の `phys_footprint` は**テストプロセス自身だけ**です。WebKit の WebContent/GPU などの子プロセスやシステム全体の使用量は含みません。全体の調査には Instruments を併用します。
- 最大値は別 Task から約 10 ms 間隔で観測し、開始前・終了後も含めます。OS のスケジューリングにより間隔は揺れ、短いピークを取りこぼす可能性があります。厳密な高水位ではありません。観測の負荷も含みます。
- 標準出力のメモリ欄は MiB（1,048,576 bytes）。前後は最後の計測回、最大は全計測回の観測最大値です。JSON には全回を残します。
- `sample/all` の前後差は、同じ sampler が全テーマの見本を保持したままの増加量です。`endurance` は準備運動を除く各周の配列で、各点に `iteration` と `bytes` を持ちます。増え続ける傾向を読みますが、アロケータや遅延解放の影響もあるため、この値だけでリークとは断定しません。

比較コマンドは `(NEW / BASE - 1) × 100` を表示し、既定で +20% を**超えた**場面に `*` を付けます。追加・欠落した場面や環境差も表示します。遅延があっても終了コードは 0 です。壊れた JSON、未対応のスキーマ、存在しないファイルなど比較自体の失敗はエラーになります。

## 基準値の更新

機種・電源状態・CPU 負荷・空きメモリ・OS・Xcode・書体・ビルド構成により数字は変わります。異なる機械、とくに GitHub の共有 runner と手元の値は直接の性能判定に使わず、同じ環境・同じ回数で比較します。準備運動をしてもファイルや OS のキャッシュが完全に一定になるわけではありません。

1. 通常の macOS ログインセッションで `make bench` を完走する。
2. JSON の環境情報、出力ページ数、各回のばらつき、耐久の推移を確認する。
3. 既存基準値があれば `make bench-compare` で比較する。
4. 採用する JSON を `Benchmarks/baseline.json` にコピーし、採用理由と環境を変更の説明に残す。

サンドボックスで WebKit や WindowServer が使えない場合、基準値は作らず、通常環境で上記を実行します。ダミーの基準値は置きません。

`.github/workflows/bench.yml` は手動と週 1 回（月曜 03:00 JST / 日曜 18:00 UTC）のみ動き、JSON を 90 日の artifact として保存します。PR・push の必須チェックには組み込みません。artifact は自動でローカルの基準値を上書きしません。

## Instruments で調べる

1. `make build` で作った Surimono Dev を起動し、調べたい文書を開く。あるいはテスト実行プロセスを対象にする場合、`make bench` を開始してそのプロセスへ接続する。
2. Xcode の Open Developer Tool → Instruments から Time Profiler を開き、対象プロセスを選ぶ。Points of Interest / os_signpost の instrument を追加する。
3. 記録を開始し、文書を開く・スタイルを切り替える・印刷画面へ入る・見本パレットを表示する。
4. subsystem `io.github.phyten.Surimono`、category `Rendering` で絞り、`prepare`（組版）、`composeSheet`（面付け）、`themeSample`（見本 1 枚）の区間を選択してスタックを確認する。
5. メモリは別の記録で Allocations / VM Tracker を使う。必要に応じて WebKit の子プロセスも対象にし、切り替えを繰り返した後の残存量を確認する。Instruments を付けた時間は通常の基準値とは分けて扱う。

区間には文書の形式とページ数だけを記録し、中身・パス・ファイル名は書きません。`prepare` と `composeSheet` はキャッシュヒット時の呼び出しも含み、失敗・キャンセルでも区間を閉じます。`prepare` の終了ページ数 0 は完了前の失敗を表します。`themeSample` はキャッシュヒットを除いた実際の描画区間です。
