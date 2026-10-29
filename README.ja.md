# Surimono（摺物）

> 雑に開いて、雑に見て、さっと刷る。

**Surimono** は、Markdown・PDF・画像・Org・テキスト・HTML といった身近な書類や画像を、すぐに見て、そのまま気軽に印刷するための macOS アプリです。印刷を主役に据えていて、印刷用スタイルシートの差し替え、HTML のノイズ除去プリセット、中綴じ冊子印刷（A3 に A4 を 2 ページ並べて両面印刷し、中央で折って綴じる）に対応します。

名前は江戸時代の私家版木版画「摺物」と、「摺る＝刷る」に由来します。

[English README](README.md)

> [!NOTE]
> Surimono は開発初期の段階です。まだリリースはありません。

## なぜ作るのか

Mac で Markdown のメモや Org ファイル、長い HTML の記事を印刷しようとすると、ブラウザやエディタのプラグイン、PDF ツールを経由する遠回りになりがちです。Surimono は「開いて、印刷を押す」の 2 手で済むことを目指します。

## 機能

- Markdown・PDF・画像・Org・テキスト・HTML・CSV のクイックビューア
- 種類が混ざった複数の画像を、1 つの「画像の束」としてまとめて開く
- サムネイルのドラッグや ⌥⌘↑ / ⌥⌘↓ で画像を並び替え
- 画像の束を現在の並び順と印刷レイアウトで PDF に書き出し
- 出てくる用紙の単位で表と裏を並べる印刷モード（刷り台）。冊子は折り線つきで並べ、「折ってみる」で折った冊子をめくって確かめられる
- Markdown・Org・テキスト向けの印刷用スタイルシート切替（標準・明朝・コンパクト・GitHub 風・論文・モダン・大きな文字・書き込み用・白黒・見出しで改ページ。自作 CSS も追加可能）
- HTML のノイズ除去プリセット（ナビゲーション、広告、サイドバー、Cookie バナーなど。追加・編集可能）
- HTML のスマート削除（ベータ）: 広告・おすすめ記事・SNS ボタン・Cookie バナーなどを自動で見つけて消し、消した部分を確かめて 1 つずつ残せる（判定はこの Mac の中だけ）
- 印刷レイアウト: A4 片面、A4 両面、中綴じ冊子（A3 → A4 冊子、A4 → A5 冊子）、A3 2アップ
- 刷り台で選んだプリンターへダイアログなしですぐ印刷（システムの印刷画面も選べる）と、PDF 書き出し（コンビニ印刷などに持ち出す用）
- 紙だけを出す余白のない表示。ウィンドウにマウスを乗せるとメニューが出る。見開き・単ページ・2 ページずつのスクロール、ぼけない拡大縮小
- 変えた設定はファイル名ではなく内容（SHA-256）ごとに覚え、次に開いたときに戻す。画像の束は画像の組ごと
- ZIP の中の画像を 1 つの画像の束として開く（フォルダの奥まで集めて名前順。ディスクには展開しない）
- ウィンドウを常に最前面に固定
- 外観はシステムのライト / ダークに従う

## 対応形式

| 形式 | 拡張子 |
|---|---|
| Markdown | `.md`, `.markdown` |
| PDF | `.pdf` |
| 画像 | `.png`, `.jpg`, `.heic`, `.gif`, `.tiff`, `.webp` など |
| Org | `.org` |
| テキスト | `.txt` などのテキストファイル |
| HTML | `.html`, `.htm` |
| CSV / TSV | `.csv`, `.tsv` |
| 画像の ZIP | `.zip`（1 つの画像の束として開く） |

## 動作環境

- macOS 15 Sequoia 以降

## ソースからのビルド

macOS 15 以降と Xcode 26 以降（Swift 6.2 以降）が必要です。Xcode を使用する開発者ディレクトリに選択してからビルドしてください。CI は Xcode 26.6、ローカル開発は Xcode 27 にも対応します。

```bash
make build                      # Debug ビルド（build/DerivedData）
make run FILE=Samples/sample.md # ビルドして文書を開く
make lint                       # Swift の整形チェック
make format                     # Swift ソースを整形
make test                       # パッケージとホストアプリ付きテスト
make test-kit                   # パッケージのテストのみ
make test-app                   # ホストアプリ付きテストのみ
make package                    # build/release に Release ZIP と SHA-256 を出力
make clean                      # ビルド生成物を削除
```

`Surimono.xcodeproj` を開き、共有スキーム `Surimono` でもビルドできます。ビルド時は `CONFIGURATION`・`DERIVED_DATA`、パッケージ作成時は `VERSION`・`BUILD_NUMBER` を指定できます。署名はアドホックのため、開発者アカウントは不要です。文書変換から印刷プレビュー、印刷、PDF 書き出しまでを SurimonoKit の描画パイプラインで接続しています。

`Samples/` に Markdown・Org・UTF-8／Shift_JIS テキスト・HTML・CSV のサンプルがあります。`booklet-demo.md` は冊子の読み順を確認するための、画像を含まない長い文書です。設定画面で余白・ページ番号・裏面回転・HTML の JavaScript を指定できます。ユーザー CSS は `~/Library/Application Support/Surimono/Styles/`、JSON プリセットは `Presets/` に追加し、設定画面から再読み込みします。外部で保存した文書は自動で再読み込みし、元のファイルには書き込みません。

## コントリビュート

Issue・Pull Request を歓迎します（日本語・英語どちらでも大丈夫です）。[CONTRIBUTING.md](CONTRIBUTING.md) と [行動規範](CODE_OF_CONDUCT.md) をご覧ください。

## ライセンス

[MIT](LICENSE) © 2026 phyten
