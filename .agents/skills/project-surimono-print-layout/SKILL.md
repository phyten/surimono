---
name: project-surimono-print-layout
description: Explains and changes Surimono's print layouts and imposition (paper sizes, duplex binding, 2-up and saddle-stitch booklet page order, PDF composition, printer quirks) and how to verify them. Use when adding or fixing a print layout, debugging page order or orientation in printed output, or editing PaperSize, PrintLayout, Imposition, PDFComposer, or print job settings.
---

# project-surimono-print-layout

印刷レイアウト（面付け）を追加・修正し、紙で正しく出ることまで確かめる手順。

## 構成

- `PaperSize`（SurimonoCore）: 用紙寸法（pt）。A3 / A4 / A5 / B4 / B5（JIS）/ Letter / Tabloid など。冊子と 2アップは用紙の半分を論理ページにする（A3 → A4、A4 → A5）。
- `PrintLayout`（SurimonoCore）: 種類（通常 / 2アップ / 冊子）、用紙、両面（なし / 長辺綴じ / 短辺綴じ）、オプション（ページ番号、裏面 180° 回転）。
- `Imposition`（SurimonoCore）: ページの並びだけを計算する純粋関数。仕様はここでテストに固定する。
- `PDFComposer`（SurimonoRendering）: 並びに従って論理ページの PDF を用紙の PDF に配置する。
- `PrintJobFactory`（SurimonoRendering）: 用紙・向き・余白 0・両面（なし / 長辺 = NoTumble / 短辺 = Tumble）を設定した `NSPrintInfo` と、縮小のみ許可した `NSPrintOperation` を組み立てる。
- `DocumentRenderer`（SurimonoRendering）: 変換 → 組版 → 面付けを束ね、`RenderResult` の `sheetDocument`（用紙）と `logicalDocument`（論理ページ）を返す。

## 中綴じの式（仕様）

```text
N = ceil(n / 4) * 4、用紙枚数 = N / 4
用紙 s（0 が一番外側）: 表 = [左 N-2s | 右 2s+1]、裏 = [左 2s+2 | 右 N-2s-1]
n を超えるページは白紙。両面は短辺綴じ
例: n = 8 → 用紙1 表[8|1] 裏[2|7]、用紙2 表[6|3] 裏[4|5]
```

## 追加・変更の手順

1. 仕様を文章にする: どの用紙に、何ページを、どの順と向きで置くか。両面の綴じ方向。
2. `Imposition` のテストを先に書く（小さい n、4 の倍数でない n、1 ページ、白紙の位置）。
3. `Imposition` → `PrintLayout` のプリセット → `PDFComposer` → `PrintJobFactory`、の順に実装する。
4. UI のレイアウト選択肢と要約表示（例「12 ページ → A3 3 枚（両面・短辺綴じ）」）を更新する。
5. 下の「検証」をすべて行う。

## 検証

- `make test-kit`: 並び・寸法・ページ数のテスト。
- 面付け済み PDF を目で見る: アプリの「PDF に書き出す」で保存し、`sips -s format png <PDF> --out /tmp/sheet1.png` で 1 枚目を画像化して確認する。
- 実機: 用紙 A3（A5 冊子なら A4）・横・両面（短辺綴じ）で印刷 → 印刷順のまま重ねて二つ折り → ページ順と天地を確かめる。裏面が逆さなら「裏面を 180° 回転」で直るかも確かめる。
- ローカル資料 `.docs/design/booklet-check/index.html` の図と照合できる（存在する場合）。

## つまずきやすい点

- macOS の両面設定（`PMDuplexMode`）はプリンタやドライバで解釈が揺れる。システムの印刷画面（⌥⌘P）を出す場合はユーザーが最終確認できるが、刷り台の「印刷」（ダイアログなし）では設定値がそのまま使われる。
- プリンタには印刷できない縁がある。用紙の端まで描く前提にせず、余白を持たせる。
