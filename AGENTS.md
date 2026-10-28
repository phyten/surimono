# AGENTS.md — Surimono

このリポジトリで作業する AI エージェント（Codex、Claude Code など）共通の指示。人間向けの案内は [CONTRIBUTING.md](CONTRIBUTING.md)。

## プロダクト

- **Surimono（摺物）**: Markdown / PDF / 画像 / Org / テキスト / HTML を「雑に開いて、雑に見て、さっと刷る」macOS アプリ。主役は印刷。
- 主な機能: 紙の出方そのままの印刷プレビュー、印刷テーマ（CSS）の切替とユーザー CSS、HTML のノイズ除去プリセット（ユーザー追加可）、印刷レイアウト（A4 片面・両面、中綴じ冊子 A3→A4 / A4→A5、2アップ）、すぐ印刷、PDF 書き出し、外観（システム / ライト / ダーク）切替、複数の画像をまとめた「画像の束」（並び替え・印刷・PDF 書き出し）。
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
  ├ Markdown / Org / テキスト / CSV → HTML 断片（SurimonoCore）→ 印刷テーマ CSS を付けて HTML 文書化
  ├ HTML → そのまま。ノイズ除去プリセット（CSS / JS）を注入
  ├ PDF  → PDFDocument
  └ 画像 → PDF ページ（ImagePageRenderer）
→ 論理ページの PDF（WebPaginator: WKWebView を NSPrintOperation で論理ページ寸法に組版）
→ 面付け（PDFComposer: レイアウトに従って用紙へ配置。冊子・2アップ・ページ番号・裏面回転）
→ プレビュー（PDFView）/ 印刷（PrintJobFactory: 用紙・向き・両面を設定した NSPrintInfo）/ PDF 書き出し
```

- これらを束ねるのが `DocumentRenderer`（SurimonoRendering）。文書ごとに 1 つ持ち、論理ページの PDF を使い回す（両面設定やページ番号の変更だけなら組版し直さない）。ファイルが変わったら `clearCache()` を呼ぶ。
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
- アプリの設定（外観・既定のレイアウト・余白など）は `AppPreferences` が `UserDefaults` に保存する。ユーザー CSS とユーザープリセットは `~/Library/Application Support/Surimono/` 配下の `Styles/`（*.css）と `Presets/`（*.json）に置く（`UserLibrary`）。

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
- 新しい「開く」経路を足すときは `OpenRouter` を通し、`OpenRouterTests` にケースを足す。

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
- エージェントのサンドボックス（Codex など）では、LaunchServices（UTType の準拠関係）、testmanagerd（ホスト付きテスト）、WebKit の子プロセス、ホーム配下のキャッシュへの書き込みが拒否されることがある。ビルドだけなら `CFFIXED_USER_HOME` などを `build/` 配下に向ける回避策があるが、Makefile には入れない。テストと起動の最終確認は通常の環境で `make test` / `make run` を実行して行う。

## スキル

`.agents/skills/`（Claude Code からは `.claude/skills/` として同じものが見える）:

- `project-surimono-dev` — ビルド・起動・テスト・目視確認の手順
- `project-surimono-add-format` — 対応形式を追加する手順
- `project-surimono-print-layout` — 印刷レイアウト・面付けの追加と検証
- `project-surimono-release` — リリース手順
