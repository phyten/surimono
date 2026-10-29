# AGENTS.md — Surimono

このリポジトリで作業する AI エージェント（Codex、Claude Code など）共通の指示。人間向けの案内は [CONTRIBUTING.md](CONTRIBUTING.md)。

## プロダクト

- **Surimono（摺物）**: Markdown / PDF / 画像 / Org / テキスト / HTML を「雑に開いて、雑に見て、さっと刷る」macOS アプリ。主役は印刷。
- 主な機能: 出てくる用紙をそのまま並べる印刷モード（刷り台）、印刷テーマ（CSS）の切替とユーザー CSS・文字の大きさ、HTML のノイズ除去プリセット（ユーザー追加可）とスマート削除（ベータ）、印刷レイアウト（A4 片面・両面、中綴じ冊子 A3→A4 / A4→A5、2アップ）、刷り台で選んだプリンターへのダイアログなしの印刷（システムの印刷画面も選べる）、PDF 書き出し、余白のない表示モード（段階表示のメニュー、見開き / 単ページ、拡大縮小、最前面に固定）、内容のハッシュごとの設定の保存、複数の画像や ZIP の中の画像をまとめた「画像の束」（並び替え・印刷・PDF 書き出し）。外観はシステムの設定に従う（アプリに切替は置かない）。
- 守ること:
  - **開いたファイルを絶対に変更しない**（ビューア。保存・上書き・隣へのファイル生成もしない）
  - **オフラインで完結する**（ネットワークは、ユーザーの文書自身が参照するリソースの読み込みに限る。テレメトリなし）
  - **2 手で印刷できる**（開く → 印刷）。迷ったら操作を減らす方を選ぶ

## リポジトリ構成

```text
App/                    アプリ本体（SwiftUI）。Xcode の synchronized folder なので、ファイル追加で pbxproj を編集しない
AppTests/               アプリのテスト（ホストアプリ付き）
Configs/                xcconfig・Info.plist・entitlements。ビルド設定はここで変える
Packages/SurimonoKit/   ロジック本体（SwiftPM）
  Sources/SurimonoCore/       純粋ロジック（形式判定、HTML への変換、テーマ・プリセット、用紙・レイアウト、面付け計算）。AppKit / WebKit / PDFKit に依存しない
  Sources/SurimonoRendering/  AppKit / WebKit / PDFKit / CoreGraphics を使う描画（ページ分割、画像の PDF 化、面付け PDF の合成、印刷設定）
  Tests/                      Swift Testing のテスト
Samples/                手動確認用のサンプル文書
Design/                 アプリアイコンの原画（AppIcon.svg。App/Assets.xcassets の PNG はここから書き出す）
Surimono.xcodeproj      手書きの最小プロジェクト（objectVersion 77）
.github/workflows/      CI（ci.yml）とリリース（release.yml）
.agents/skills/         プロジェクト固有スキル（正本。Codex が読む）
.claude/                Claude Code 用（settings.json、rules/、skills は .agents/skills へのシンボリックリンク）
.docs/                  ローカル専用の開発資料（gitignore 済み。コミットしない）
```

## コマンド

```bash
make build                      # Debug ビルド（build/DerivedData）
make run FILE=Samples/sample.md # ビルドしてファイルを開く（FILE 省略可）
make test                       # test-kit と test-app の両方
make test-kit                   # SurimonoKit のテスト（swift test）
make test-app                   # アプリのテスト（xcodebuild test）
make lint                       # swift-format lint --strict
make format                     # swift-format で整形
make package                    # Release ビルド → build/release/Surimono-<version>.zip
make clean
```

- 変更したら最低限 `make lint` と、変更範囲のテスト（Kit なら `make test-kit`、アプリなら `make build` と `make test-app`）を通す。
- CI（`.github/workflows/ci.yml` の `build-and-test`）は Xcode 26.6 / macOS 26、ローカルは Xcode 27 系を想定。**両方でビルドできるコードにする**。`if #available` は実行時の OS の分岐で、古い SDK でのコンパイルは助けない。CI の SDK（Xcode 26.6）に無い API は使わず、どうしても使う場合は `#if compiler(>=…)` などの条件付きコンパイルと代替の実装を用意する。

## アーキテクチャ（印刷パイプライン）

```text
ファイル → DocumentFormat 判定
  ├ Markdown / Org / テキスト / CSV → HTML 断片（SurimonoCore）→ 印刷テーマ CSS を付けて HTML 文書化（テーマは `common.css` の後に重ね、その後に文字の大きさを重ねる。WebKit の印刷では CSS の段組みが効かないので、段組みのテーマは作れない）
  ├ HTML → そのまま。ノイズ除去プリセット（CSS / JS）を注入
  ├ PDF  → PDFDocument
  └ 画像 → PDF ページ（ImagePageRenderer）
→ 論理ページの PDF（WebPaginator: WKWebView を NSPrintOperation で論理ページ寸法に組版）
→ 面付け（PDFComposer: レイアウトに従って用紙へ配置。冊子・2アップ・ページ番号・裏面回転）
→ プレビュー（PDFView）/ 印刷（PrintJobFactory: 用紙・向き・両面を設定した NSPrintInfo）/ PDF 書き出し
```

- これらを束ねるのが `DocumentRenderer`（SurimonoRendering）。文書ごとに 1 つ持ち、論理ページの PDF を使い回す（両面設定やページ番号の変更だけなら組版し直さない）。ファイルが変わったら `clearCache()` を呼ぶ。
- Markdown と Org のコードは SurimonoCore の `SyntaxHighlighter` で色付けする（JavaScript は使わない）。Markdown の `:::` と `> [!note]` は囲み（`callout-*`）にする。
- `:::` は markdown-it-container と同じく、段落・参照定義・引用・リストの続きを打ち切る（コード・HTML・明示的な引用行・字下げしたリスト本文・AST のブロックに属さない行は除く）。
- JavaScript: Markdown / Org / テキスト / CSV から作る HTML では常に無効。HTML 文書は設定（既定は許可）とプリセットの両方が許すときだけ有効。

- 論理ページ寸法: 通常は用紙そのもの。冊子と 2アップは用紙の半分（A3 → A4、A4 → A5、B4 → B5）。Web 系の文書は論理ページ寸法で組版し直し、PDF と画像は縮小して収める。
- 中綴じ面付け（ページは 1 始まり、n は元のページ数）:

  ```text
  N = ceil(n / 4) * 4、用紙枚数 = N / 4
  用紙 s（0 が一番外側）: 表 = [左 N-2s | 右 2s+1]、裏 = [左 2s+2 | 右 N-2s-1]
  n を超えるページは白紙。両面は短辺綴じ
  ```

  例: n = 8 → 用紙1 表[8|1] 裏[2|7]、用紙2 表[6|3] 裏[4|5]。この式はテストで固定している。変更するときはテストと `.agents/skills/project-surimono-print-layout` を先に更新する。
- 依存の向き: App → SurimonoRendering → SurimonoCore。Core から AppKit / WebKit を import しない。
- アプリの既定値（既定のレイアウト・余白など）は `AppPreferences` が `UserDefaults` に保存する。ユーザー CSS とユーザープリセットは `~/Library/Application Support/Surimono/` 配下の `Styles/`（*.css）と `Presets/`（*.json）に置く（`UserLibrary`）。
- 文書ごとの設定（表示の型・向き・送り方・表紙・拡大率・窓の大きさ・印刷レイアウト・スタイル / プリセット・文字の大きさ・印刷のオプション・画像の並び順）は `DocumentSettings` にまとめ、**ファイル名ではなく内容の SHA-256（`ContentHash`）をキーに** `~/Library/Application Support/Surimono/DocumentSettings/`（`KeyedRecordStore`）へ保存する。
  - キー: 1 ファイルはその内容、ZIP は ZIP ファイル自体、画像の束は各画像のハッシュを並べ替えて作る集合のハッシュ（`ContentHash.imageSet`。書式は永続化の形式なので変えない）。並び順は各画像のハッシュの列で保存する。
  - 保存は利用者が何かを変えたときだけ（`DocumentViewModel` が読み込み・復元・既定に戻した時点の値と比べる）。開いている間にファイルが変わったら、表示中の設定を新しいハッシュへ引き継ぐ。

## ウィンドウとファイルの開き方

- **1 つの刷り物（1 ファイル、または画像の束）= 1 つのウィンドウ**。表示中のウィンドウにドロップしても置き換えず、新しいウィンドウで開く。すでに開いているファイルは前面に出す。
- ユーザーがファイルを選ぶ・渡す・ドロップする経路は、標準メニューの「最近使った項目」を除いて `OpenRouter`（App）を通す。分類は `OpenRequest`（SurimonoCore）:
  - 1 つ → 文書として開く（DocumentGroup / `NSDocumentController`）
  - 2 つ以上ですべて画像（種類の混在は可）→ 画像の束（ファイル名の自然順）
  - 2 つ以上で画像以外を含む → 何も開かずに警告（ウィンドウへのドロップならそのウィンドウのシート）
- 経路ごとの入口:
  - Finder / Dock / 「このアプリケーションで開く」: `AppDelegate` が open-documents の Apple Event を受ける（`applicationWillFinishLaunching` で登録）
  - ファイル > 開く…: 標準の項目が送る `openDocument:` を `AppDelegate` が受ける（SwiftUI の AppDelegate が応答チェーンで転送する）。独自の「開く…」をメニューに足さない（標準の項目と重複し、標準の側は文書コントローラが 1 つずつ開いてしまう）
  - ドロップ: 文書・画像の束・ウェルカム画面の `.dropDestination`
  - 最近使った項目: 標準メニューの項目は文書コントローラが 1 ファイルを開く（規則と同じ結果になるので、ルーターを通さないままでよい）。ウェルカム画面の最近使ったファイルは `OpenRouter` を通す
- 画像の束は NSDocument ではなく、`ImageBundleWindows` が AppKit の NSWindow に SwiftUI の `DocumentContent` を載せて開く。メニュー操作は `DocumentWindows.activeModel`（キーウィンドウのモデル）に届ける。
- ZIP は 1 つのファイルとして DocumentGroup で開き、中の画像を `ZipArchive`・`ZipImageSelection`（SurimonoCore）で集めて `ImageBundleModel` の束にする。ディスクへ展開せず、メモリ上で必要なときに 1 枚ずつ展開する。
- 新しい「開く」経路を足すときは `OpenRouter` を通し、`OpenRouterTests` にケースを足す。

## HTML のスマート削除（ベータ）

- 選んだプリセットのあとに、本文でない部分（広告・おすすめ記事・SNS ボタン・Cookie バナー・追従ヘッダー・ニュースレター欄・ポップアップ）を見つけて消す。判定は組版の準備スクリプトとして WKWebView の中だけで行い、外には何も送らない（`SmartRemovalScript`、SurimonoCore）。
- 本文の領域を 1 つに絞り、本文とその祖先、本文らしい見出しと段落の塊は消さない。候補の識別子は同じ HTML なら毎回同じで、「残す」の選択に左右されない。
- アプリは `RenderSettings.smartRemoval`（HTML のときだけ）で頼み、`RenderResult.smartRemovalCandidates` で候補を受け取る。確かめている間は消さずに点線の枠で示す。オンかどうかと「残す」の一覧は、文書ごとの設定として内容のハッシュで覚える。
- 確かめるパネルは表示モードにだけある。メニューとトーストからは `reviewSmartRemoval()` で開き、刷り台からなら表示モードへ戻る。枠つきのページは出力に使わない（`canOutput` が偽）。印刷モードに入ると確認を終え、確認中の印刷と PDF の書き出しは、確認を終えて枠のないページができてから行う。

## 印刷モード（刷り台）

- 表示モードの「印刷」・⌘P で入り、Esc・「表示に戻る」で戻る。印刷モードの朱の「印刷」と ⌘P は、刷り台で選んだプリンターへダイアログなしで送る（プリンターはアプリ全体で `AppPreferences.printerName` に覚え、外されていればシステムの既定。1 台もないときと、刷り台に出ていたプリンターが印刷の直前に外されていたときは、別のプリンターへ黙って送らずにシステムの印刷画面を開く。判断は `PrinterList.request`）。システムの印刷画面は ⌥⌘P と、プリンターのメニューの「システムの印刷画面で印刷…」から。⌘1〜⌘5 はレイアウトを選んで印刷モードへ。モードはウィンドウごと（`DocumentViewModel.mode`）。
- 入るときに `PrintModeWindow` が窓の枠を覚えて刷り台の大きさ（約 1000×760）へ広げ、戻るときに元の枠へ戻す。表示モードの縦横比の固定は入るときに外し、戻ってから付け直す。
- 刷り台は面付けした PDF（`sheetDocument`）の各面をベクターのまま描く。用紙ごとのまとめ方・見出し・ラベルは純粋な型 `PrintTray` にあり、テストで固定している。冊子は「折ってみる」で、読む順にめくって確かめられる。
- 配色は案 C の和紙・墨・朱・藍（`PrintPalette`。ダークでは夜の色）。朱は「印刷」ボタンだけに使う。

## 表示モードのウィンドウ

- ウィンドウには紙だけを余白なしで出す（`ViewerWindow`: タイトルバーを隠し、信号機はメニューと一緒に出す）。窓の縦横比は表示中のページか見開きに固定する。
- メニューは段階表示（`OverlayMenuState`）: 乗せると約 80 ms でファイル名と「印刷」、上部に留まると全部、離れて約 800 ms・静止 2.5 秒・ページ送りで隠す。Tab / M で出す、Esc で隠す、V で表示のオプション、T で文字を選択、⌥⌘T でメニューを固定（窓を上へ帯の高さだけ伸ばし、紙は動かさない）。
- 帯には、スタイル・表示の型・向き・スクロール・送り方・表紙（見開きのとき）・文字を選択（画像以外）・拡大率（拡大中）・サムネイル（画像の束）・最前面に固定・メニューを固定・「…」・印刷を直接並べる。幅が足りないときは `BandLayout`（SurimonoCore）の決まった順に畳む: まずスタイルと送り方の名前を省き、次にメニューを固定・最前面に固定・形式のバッジ・表紙・スクロール・向き・ページ表示・スタイル・送り方・表示の型の順に帯から外す。ファイル名は 80pt まで縮めて残し、印刷は最後にアイコンだけになる。外した物は「…」のメニューに並び、最後の「表示のオプション…」（V）でポップオーバーを開く。部品の幅は見えない所で形ごとに測り（`BandMeasurements`）、測った値は帯が消えても `OverlayMenuState` に残す。スクロールは、効かない送り方（切り替え・フェード・めくり）のときは隠さずに薄くする。
- 紙は `PaperView`（PDFView）。`ViewOptions`（SurimonoCore）を PDFView の表示モード・`displaysAsBook`・`displaysRTL`・`displayDirection` に当てはめ、ページ送りのアニメーション（スライド・フェード・めくり）、拡大縮小（ピンチ・⌘＋スクロール・⌘＋/−/0・ダブルクリック）、キー操作、紙のドラッグでの窓の移動を受け持つ。「文字を選択」（`DocumentViewModel.isSelectingText`。窓ごとで保存しない）のときは、ドラッグ・クリック・ダブルクリックを PDFKit の文字の選択に渡し、端のクリックでページを送らない。⌥ を押している間は二つのドラッグが入れ替わる。カーソルは、文字を選択のときだけ PDFKit の I ビームに任せ、それ以外は矢印（拡大中は手のひら）にする。拡大中に素早く閉じるピンチで 100% に戻る。100% 未満はゴムで、離すと戻る。

## コーディング規約

- Swift 6 言語モード。アプリターゲットは既定で MainActor 分離（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）。Kit では UI / WebKit を触る型に明示的に `@MainActor` を付ける。
- デプロイメントターゲットは macOS 15.0。
- 依存パッケージは最小限。追加するときは理由とライセンス（MIT と両立するか）を PR に書く。現在の外部依存: swift-markdown（Apache-2.0）。
- UI 文言は英語をキーにして String Catalog（`App/Localizable.xcstrings`）で日本語訳を付ける。
- 整形は swift-format（`.swift-format`。インデント 4、行長 120）。
- コメントは「なぜそうするか」を書く。自明な処理の説明コメントは付けない。**コードコメントとドキュメントコメントは英語**で書く（テスト名は日本語）。
- ビルド設定を変えるときは `Configs/*.xcconfig` を編集する。Xcode の GUI でターゲット設定を変えない。

## 細則（.claude/rules/）

パス別の細則は `.claude/rules/` にある。Claude Code は対象ファイルを扱うときに自動で読み込む。**Claude Code 以外のエージェントも、該当するファイルを編集する前に読むこと。**

- `.claude/rules/swift.md` — Swift（並行性、エラー、ファイルの扱い、SwiftUI / AppKit）
- `.claude/rules/tests.md` — テスト
- `.claude/rules/github-actions.md` — GitHub Actions と Dependabot

## テスト

- **Swift Testing**（`import Testing`）を使い、TDD で振る舞いを先にテストにする。
- **テスト名は日本語で振る舞いを書く**: `@Test("12ページの冊子は3枚の用紙になる")`。
- 仕様として書いた制約（面付けの式、用紙寸法など）はテストで固定する。
- WebKit を使うテストは遅く不安定になりやすい。数を絞り、タイムアウトを設ける。
- fixture に個人情報や実データを入れない。

## Git / PR

- `master` は保護されている。topic ブランチ → PR → CI（`build-and-test`）成功でマージ。
- コミットは論理的な最小単位ごと。メッセージは**日本語の Conventional Commits**（例: `feat(print): A5 冊子レイアウトを追加`）。AI と協業したコミットには `Co-Authored-By` を付ける。
- **エージェントは明示的に頼まれない限り commit / push / merge をしない**。
- PR 本文は日本語で、テンプレート（`.github/PULL_REQUEST_TEMPLATE.md`）に沿って書く。

## 開発資料（.docs/）

- `.docs/` はローカル専用（gitignore 済み）。企画書、デザインモック（`.docs/design/`）、メモを置く。
- 公開リポジトリに載せる情報（README、コード、Issue）と混同しない。`.docs/` の内容をコミットやPR本文へ丸ごと転記しない。

## 地雷（ハマりどころ）

- メンテナ環境のグローバル gitignore は `AGENTS.md`・`CLAUDE.md`・`.claude`・`.agents` を無視する。リポジトリの `.gitignore` で打ち消しているので、その行を消さない。
- `Surimono.xcodeproj` は手書き。Xcode の GUI でターゲットや設定を編集すると pbxproj が大きく書き換わる。設定は xcconfig へ。
- 冊子印刷は短辺綴じが前提。プリンタによっては裏面が上下逆になるため、「裏面を 180° 回転」オプションで補正する。
- WKWebView の印刷は、ビューがウィンドウに載っていないと白紙になる。WebPaginator は非表示ウィンドウに載せ、`runModal(for:)` と別スレッドの印刷で PDF を作っている。
- `loadHTMLString(_:baseURL:)` は基準 URL が file URL でもローカルのファイルを読む権限を与えないため、文書の隣の画像が表示されない。WebPaginator は生成した HTML を一時ファイルに書いて `loadFileURL` で読み込む（生成 HTML では JavaScript を止めている）。
- DocumentGroup のアプリでは、open-documents を `application(_:open:)` だけで受けると複数選択が文書コントローラに 1 つずつ渡ることがある。Apple Event のハンドラで一括して受けている。
- 文書なしで起動すると、文書コントローラが「開く」パネルを自動で出す（このパネルの複数選択はルーターを通らない）。`NSShowAppCentricOpenPanelInsteadOfUntitledFile` を false で登録して止め、ウェルカム画面を出している。
- `@FocusedValue` / `focusedSceneValue` は AppKit で開いたウィンドウ（画像の束・ウェルカム画面）に届かない。メニューからは `DocumentWindows.activeModel` を使う。
- `NSHostingController` を `contentViewController` にすると、既定ではウィンドウが中身の理想の大きさまで縮む。`sizingOptions = [.minSize]` にして大きさを指定する。
- ホスト付きテストの中では `NSApp.mainMenu` が組み立て済みなので、メニュー構成（「開く…」が 1 つ、など）をテストで固定できる。
- PDFView は表示モードや文書を切り替えたときにも自分で倍率を変え、ピンチも内部のスクロールビューが先に受け取って自分で拡大する。`PaperPDFView` はピンチとスマートズームをローカルのイベントモニタで PDFKit より先に受け取って自分の倍率（窓に合わせた大きさに対する比）を変え、PDFKit が自分で変えた倍率はいつも窓に合わせ直す（ピンチを PDFKit に任せると、指を離した後に元の大きさへ戻ってしまう。取り違えると何も変えていない文書の設定が保存される）。
- 帯の部品を `ViewThatFits` で丸ごと別の組み立てに切り替えると、中のボタンが作り直され、そこから出したポップオーバーが閉じる（表示の型を変えて窓の幅が変わったときに起きた）。帯は `ViewThatFits` を使わずに測った幅から出す物を決め、表示のオプションのポップオーバーはいつも帯にある「…」から出す。
- `setFrame(_:display:animate:)` のアニメーションは、呼び出しから戻ったあとにライブリサイズの終了を通知する。アプリが窓の大きさを変えるときは `ViewerWindow` を通し、利用者のリサイズと区別する。
- PDFView の `displaysAsBook` は単独の表紙を中央に置く（左右どちらかに寄せる API はない）。
- メニューの `.disabled(...)` をキーウィンドウのモデルから作ると、SwiftUI はメニューを開くまで更新せず、ショートカットが効かないままになる。項目は有効のままにして、できないときはモデル側で何もしない。
- DocumentGroup の窓でツールバー項目をすべて消すと SwiftUI はツールバーごと消し、タイトルバーが縮む。ツールバーを自前の NSToolbar に差し替えると SwiftUI の監視でクラッシュする。印刷モードは見えない項目（`PrintModeToolbarPlaceholder`）でタイトルバーの高さを保つ。画像の束の窓では `sceneBridgingOptions = [.toolbars]` で同じツールバーを使う。
- SwiftUI がビューを組み直している最中に、SwiftUI が KVO で監視する窓のプロパティ（`isMovableByWindowBackground` など）を設定すると落ちる（同じ値でも通知される）。`WindowReader` は更新が終わってから窓を渡し、`ViewerWindow.configure` は値が違うときだけ設定する。
- 印刷モードとの切り替えで、表示モードのビュー（`PaperPDFView` を含む）は作り直される。戻したい状態はビューの中だけに持たず、モデルから渡す（読んでいたページは `DocumentViewModel.currentPageIndex` から `PaperView.initialPageIndex` で戻す）。
- 紙（ページ）はダークでも白い。紙の上に浮かべるパネルにマテリアルだけを敷くと、白い紙の上で中間のグレーになり補足の文字が読めない。`paperOverlayBackground` を使う。
- エージェントのサンドボックス（Codex など）では、LaunchServices（UTType の準拠関係）、testmanagerd（ホスト付きテスト）、WebKit の子プロセス、ホーム配下のキャッシュへの書き込みが拒否されることがある。ビルドだけなら `CFFIXED_USER_HOME` などを `build/` 配下に向ける回避策があるが、Makefile には入れない。テストと起動の最終確認は通常の環境で `make test` / `make run` を実行して行う。

## スキル

`.agents/skills/`（Claude Code からは `.claude/skills/` として同じものが見える）:

- `project-surimono-dev` — ビルド・起動・テスト・目視確認の手順
- `project-surimono-add-format` — 対応形式を追加する手順
- `project-surimono-print-layout` — 印刷レイアウト・面付けの追加と検証
- `project-surimono-release` — リリース手順
