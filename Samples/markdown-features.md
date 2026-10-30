# コードと囲みの印刷見本

架空の「星見図書室」の作業メモです。色だけでなく、太字・斜体・左罫線の見え方も確認できます。

## コードを読む

### Swift

```swift title=Book.swift
struct Book {
    let title: String
    var available = true
}
// 印刷時にもコメントを読みやすく
let book = Book(title: "星の散歩道")
print(book.title)
```

### JavaScript

```js
const books = ["月の庭", "星の散歩道"];
function label(title) {
  return `蔵書: ${title}`;
}
console.log(books.map(label));
```

### Python

```python
@cache
def total(pages):
    """ページ数を合計する。"""
    return sum(pages)
print(total((120, 96, 144)))
```

### シェル

```bash
#!/bin/bash
for book in "$HOME/books"/*.md; do
  echo "印刷候補: $book"
done
# ファイルは変更しない
```

### JSON

```json
{"room": "星見図書室", "open": true, "shelves": 12}
```

### YAML

```yaml
---
room: 星見図書室
hours: &hours "10:00–17:00"
weekend: *hours
open: yes # 架空の開室情報
```

### HTML

```html
<!-- 案内カード -->
<article class="card">
  <h2>星 &amp; 月</h2>
  <p>架空の読書会です。</p>
</article>
```

### 差分

```diff
diff --git a/card.md b/card.md
--- a/card.md
+++ b/card.md
@@ -1,2 +1,2 @@
-開室は午後です。
+開室は午前十時です。
  架空の予定です。
```

## コロンで囲む

:::note
既定の表題が付くメモです。**強調**も使えます。
:::

:::tip 印刷前のヒント
- 用紙の向きを確認します。
- ページ数を確認します。
:::

:::important 記録に残すこと
| 項目 | 内容 |
|---|---|
| 用紙 | A4 |
| 部数 | 1 |
:::

:::warning 気をつけること
この予定は見本です。
:::

:::danger 注意の見本
左の罫線と太字でも重要度を区別できます。
:::

:::quote 引用の見本
小さな図書室に、遠い世界への扉があります。
:::

:::custom 独自の種類
未知の種類には灰色の囲みが付きます。
:::

:::message
Zenn 形式のメッセージには表題を付けません。
:::

:::message alert
Zenn 形式の警告にも表題を付けません。
:::

::::details 長い出力（印刷では常に表示）
:::tip 入れ子のヒント
内部の Markdown とコードも解析します。

```swift
let count = 3
```
:::
::::

## 引用で囲む

> [!NOTE]
> GitHub 形式のアラートです。

> [!tip] **太字**の表題
> Obsidian 形式の表題はインライン書式を保持します。

> [!faq]- 折りたたみ記号付き
> 印刷では本文を常に表示します。
>
>> [!success]+ 入れ子の囲み
>> 内側にも別の種類を指定できます。

> [!details]+ 補足
> 詳細も開いたまま表示します。

> [!unknown]
> 未知の種類も本文を失いません。

## コード中の記法はそのまま

````markdown
:::note
これはコードの一部です。
:::
> [!NOTE]
> これもコードです。
````

## 拡張記法

[TOC]

### 脚注

星見図書室は月に一度、棚の並びを入れ替えます[^shelf]。返却の箱は入口の右にあります[^box]。

[^shelf]: 入れ替えの日は、入口に案内を貼ります。
    二行目からは字下げで続けます。
[^box]: 夜間も使えます。

### ハイライト・上付き・下付き

==ここは大事== です。2^10^ は 1024、水は H~2~O、~~取り消し線~~ は二本の波線で書きます。

### ルビ

{図書室|としょしつ}の{司書|し|しょ}に、{本|ほん}の{場所|ばしょ}を聞きました。

### 絵文字

:books: と :sparkles: と :+1: は絵文字になります。

### 定義リスト

貸し出し
: 一度に五冊まで、二週間借りられます。

予約
: 貸し出し中の本は、窓口で予約できます。
: 届いたら連絡します。

### 数式

本文の中の式 $E = mc^2$ や \( \alpha + \beta \) が書けます。値段の $5 や $10 はそのままです。

$$
x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
$$

```math
\sum_{k=1}^{n} k = \frac{n(n+1)}{2} \qquad \int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
```

化学式も書けます: $\ce{2H2 + O2 -> 2H2O}$

### 見出しの ID {#custom-anchor}

[脚注の節へ](#脚注) のように、見出しの ID で文書の中にリンクできます。
