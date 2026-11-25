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

## 大容量ログと CSV の変換

`make bench-large-text` は、1・10・50 MB のログと、見出し込み 1 万・10 万・50 万行の CSV を生成し、入力ごとに新しいテストプロセスで 1 回測る。ログは 1 行 100 バイトの UTF-8、CSV は CRLF 区切りの 4 列で、引用符内にカンマを含む。1 MB は 1,000,000 バイト。

`seconds` は入力を用意した後の `TextDecoding.decode` から Formats の HTML 断片が返るまでの時間。`peakRSSBytes` は macOS の `getrusage(RUSAGE_SELF)` によるプロセス起動から変換終了までの最大常駐バイト数で、テストランナーと入力のメモリも含む。入力サイズと HTML サイズはバイト単位で併記する。アプリ側の文書上限・厳密な復号検査・CSS の付加・WebKit 組版を経由しないため、上限を超える入力でも変換部分だけを比較できる。

### ログイン中の Mac で初回表示を測る

開発版で同じファイルを開き、開く操作・最初の文字が紙に現れた時点・読み込み表示が消えた時点を別々に記録する。通常の DEBUG スナップショットは全文の完成を待つため、先頭の表示時刻は画面収録などで読む。1・10・29 MB のログと、見出し込み 5,000・5,001・10,000・59,000 行の CSV を比較する。再表示は組版キャッシュが効くため、毎回新しい文書窓で測る。

テキストは 1 MB 超で先頭 200 KB・1,000 行まで、CSV は 5,000 レコード超で見出し込み 1,000 レコードまでを先に組む。長いレコードでは約 200 KB を目安に行数を減らす。予算内に表示できる行、または見出しとデータ行が揃わなければ全文だけを組む。大きな CSV は全文で最も列の多い行に合わせて列を確保し、先頭と全文に同じ固定レイアウトを使う。後半に長い値や追加列を含む表で、差し替え前後の先頭ページの列境界を確認する。

## ページ一覧

ログイン中の Mac で `make bench-pages` を実行する。対象は booklet-demo、コーパスの beamer 083、自動生成した300ページのPDF、画像20枚の束。ビルドの時間は計測に含めない。

- `make bench-pages-rendering` は長辺160ptを1×と2×で描く。各文書でキャッシュを20回作り直し、最初の縮図と先頭20ページまでの各縮図について中央値と95パーセンタイル（ms）を出す。全ページを2×で一巡したあとの画像バイト数とプロセスのメモリ増分も出す。保存済みの論理PDFで入力を固定する場合は `SURIMONO_BENCH_READING_PDFS` に `sample-booklet-demo-md.pdf` と `latex-083.pdf` のあるフォルダーを渡す。
- `make bench-pages-window` は新しい文書窓で引き出しを開いてから最初の画像がビューに現れるまでを20回測る。開閉状態を交互に復元し、窓の作成から論理ページの表示準備完了までの中央値を比べる。スクロール中の最長フレームは表示リンクのメインスレッドへの到着間隔、スタイル変更は新しい組版の世代の画像が現れるまでの時間。短いデッキがすべて見える場合はスクロール距離がゼロになる。

## 文章の点検

`make bench-prose` は、テストの中で作った文書（日本語 2 万字・20 万字、英語 2 万語、混在、プレーンテキスト）で `ProseCheck.analyse` の時間を測る。準備運動 1 回を除いて既定 40 回（`SURIMONO_BENCH_RUNS`）で、本文の取り出しを含む全体の中央値・95 パーセンタイル・最大（ms）と、取り出しだけの中央値を `BENCH prose/<名前>` の行で出す。Debug ビルドの値で、合否は付けない。

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
4. subsystem `app.surimono.Surimono`、category `Rendering` で絞り、`prepare`（組版）、`composeSheet`（面付け）、`themeSample`（見本 1 枚）の区間を選択してスタックを確認する。
5. メモリは別の記録で Allocations / VM Tracker を使う。必要に応じて WebKit の子プロセスも対象にし、切り替えを繰り返した後の残存量を確認する。Instruments を付けた時間は通常の基準値とは分けて扱う。

区間には文書の形式とページ数だけを記録し、中身・パス・ファイル名は書きません。`prepare` と `composeSheet` はキャッシュヒット時の呼び出しも含み、失敗・キャンセルでも区間を閉じます。`prepare` の終了ページ数 0 は完了前の失敗を表します。`themeSample` はキャッシュヒットを除いた実際の描画区間です。

## 壊れた文書での耐久（`make robustness`）

読み取りが、壊れた・切れた・名前と中身の違う・極端に大きい文書でも落ちず、止まらず、メモリを使い切らないことを確かめる任意の長い試験です。合否は落ちた・止まった入力があるかどうかだけで、速さは測りません。

```sh
make robustness                                  # 全形式を順に 600 秒
make robustness SECONDS=1800 FORMAT=latex SEED=7 # 1 形式・種を指定
make robustness FORMAT=docx SEED=7 START=1234 COUNT=1   # 1 件だけ作り直して読む
make robustness FORMAT=markdown REPLAY=build/robustness/failures/markdown/<hash>.md  # 読めないファイルなら 2 で終わる
make robustness SHORT=1                          # 数 MB の手書きの文書を除く（変異に時間を回す）
make robustness FIXED=1 SECONDS=3600             # 手書きの文書と再現用の入力だけを各形式 1 回
make robustness SANITIZE=address SHORT=1         # AddressSanitizer で（test-kit-asan と同じ build/sanitize/address）
make robustness-rendering                        # 極端な HTML を実物の WebKit で組む（遅い）
```

- 読むのは子のテストプロセス（`ReaderFuzzChild`、`swift test --skip-build`）で、アプリと同じ入口（`DocumentRenderer.themedFragment`、PDF・画像・ZIP は `DocumentRenderer.prepare`）を 512 KiB のスタックのスレッドで呼ぶ。読む前に入力を実行ごとの作業フォルダー（`build/robustness/work-*/current/self.<拡張子>`。終わると消し、1 秒を超えた入力の一覧だけ `slow-<日時>.jsonl` に残す）に書くので、子が落ちると親（`Benchmarks/robustness.py`）がその入力を `build/robustness/failures/<形式>/<SHA-256 の先頭>.<拡張子>` に、経緯を同じ名前の `.report.json` に残し、続きから新しい子を始める。
- 1 件の上限は 100 KB あたり 5 秒（最短 5 秒）と、プロセスの最大常駐メモリ 4 GB。子の見張りのスレッドが超えた入力を記録してプロセスを終える（スレッドは外から止められないため）。
- 入力の番号は、手書きの極端な文書（`HostileInputs`）、`Fixtures/Robustness/<形式>/` の再現用の入力、種の文書（`Samples/`・テストの fixture・LaTeX のコーパス）を決まった乱数で変えたもの（`InputMutator`。ビットの反転、挿入・削除、塊の複製、切り詰め、2 つの文書の継ぎ合わせ、各形式の区切り記号の複製・削除・挿入）の順。形式・種・番号で 1 件が決まる。
- 結果は `build/robustness/summary-<日時>.json`。`make test-kit` には、極端な文書を 5 分の 1 の長さにした分と、種から変えた 24 件ずつ（`ReaderRobustnessTests`）だけが入る。
