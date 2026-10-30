---
name: project-surimono-print-layout
description: Explains and changes Surimono's print layouts and imposition (paper sizes, duplex binding, 2-up and saddle-stitch booklet page order, PDF composition, printer quirks) and how to verify them. Use when adding or fixing a print layout, debugging page order or orientation in printed output, or editing PaperSize, PrintLayout, Imposition, PDFComposer, or print job settings.
---

# project-surimono-print-layout

印刷レイアウト（面付け）を追加・修正し、紙で正しく出ることまで確かめる手順。

## 構成

- `PaperSize`（SurimonoCore）: 用紙寸法（pt）。A3 / A4 / A5 / B4 / B5（JIS）/ Letter / Tabloid など。冊子と 2アップは用紙の半分を論理ページにする（A3 → A4、A4 → A5）。
- `PrintLayout`（SurimonoCore）: 種類（通常 / 2アップ / 冊子 / 3枚＋メモ）、用紙、両面（なし / 長辺綴じ / 短辺綴じ）、オプション（ページ番号、裏面 180° 回転）。
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

## 用紙の向きと配布用（仕様）

- 用紙の向き（自動 / 縦 / 横）は文書ごと。自動はページの縦横の多い方（同数なら先頭）、Web 系の文書は縦。通常は用紙と論理ページを横にし、2アップは横長の中身なら縦の用紙に上下 2 枚（slot 0 が上）。冊子は向きを固定する。スロットの矩形は `PrintLayout.slotRect(at:)` に集約し、面付けと刷り台のプレビューで共有する。
- 縦横の混ざった PDF・画像: 通常・片面・用紙の向きが自動のときだけ、ページごとに用紙の向きを合わせる（幅 > 高さは横、正方形を含むそれ以外は縦。PDF の CropBox・Rotate と画像の EXIF を反映）。両面と 2アップは多い方、冊子と 3枚＋メモは固定、縦 / 横の指定は全用紙、Web 系は変えない。`RenderResult.sheetOrientations` が各面の向きを持つ。印刷の設定は面付けした用紙から決め、1 種類ならその向き、混在なら縦の用紙に `autoRotate: true` と `.pageScaleDownToFit`（拡大はしない）。PDF の書き出しは混在の寸法のまま。
- 3枚＋メモ（`a4Handout3`）: A4 縦・片面。内容や向きの指定によらず縦。印刷可能幅から列間 8 mm を引き、左 64%・右 36%。左に上から 3 枠（枠の間も 8 mm）、右は全高のメモ欄（上から 8 mm 間隔の細い灰色の罫線）。論理ページは枠の寸法で、枠の中では外周の余白を引き直さない。PDF・画像は枠に収める。
  - 余白 15 mm: 左の枠 110.08 × 83.6667 mm、メモ欄 61.92 × 267 mm
  - n = 7 → [1, 2, 3] / [4, 5, 6] / [7, 白紙, 白紙]。最後の用紙もメモ欄を残し、ページ番号は中身のある枠だけ

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
