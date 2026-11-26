# SwaTex 0.6.0 の数式組版と描画量

Surimono のアプリと Finder のプレビューは、同じ [MathRenderer](Sources/SurimonoFormats/MathRenderer.swift) を通る。組版の直前に [構文木](Sources/SurimonoFormats/MathLayoutLimits.swift)、表示リストを作る直前に [実際のボックス](Sources/SurimonoFormats/MathDisplayLimits.swift) を検査する。数式番号を取り除いた SVG を別に作る経路と、インラインの空きを測り直す経路にも、該当する検査を適用する。上限を越えた式は原文で読める。

## 監査表

対象は [固定した SwaTex のソース](https://github.com/PhraseHQ/SwaTex/tree/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout) の全 20 ファイルと、その表示リストを消費する SVG 出力。右端はマクロ定義を含まない 4,096 バイトの式について、検査を通る場合の保守的な上界。複数の行で同じ予算を消費する。「65,536 単位」は要素・矩形・パス命令などの計数であり、CPU 命令数ではない。

| SwaTex の位置 | 入力に依存する処理 | 上界を決めるもの |
|---|---|---|
| [Engine:47](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/Engine.swift#L47)・同 96、156、219、[HBox:6](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/HBox.swift#L6)、[VBox:7](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/VBox.swift#L7)、[Spacing:52](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/Spacing.swift#L52) | 原子クラスの両方向走査、行分割、各行の箱・糊・行間の配列、水平和と垂直和 | 構文木と付随要素が計 65,536、深さ 96。1 原子の前に追加する自動糊は最大 1 個。行数は改行数＋1。再帰には上流のスタック余裕検査もある。 |
| [EngineTextStyles:149](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineTextStyles.swift#L149)・同 186、240、263、525、604、[EngineSymbols:62](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineSymbols.swift#L62)、[EngineOps:109](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineOps.swift#L109)・同 268 | verbatim の文字、演算子名、フォント付き子要素と字間、クラス・基底・字形の探索 | 文字列を UTF-8 バイト数でも課金。フォントの一時領域は子数の 2 倍まで。先頭・末尾をたどる探索は木の深さで制限。通常の太字はフォント選択。 |
| [EngineTextStyles:23](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineTextStyles.swift#L23)・同 90、131、340、372、385、411、438、[HtmlMathML:20](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/Functions/HtmlMathML.swift#L20)、[Href:6](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/Functions/Href.swift#L6) | CSS の任意倍率やウェイト、リンクの下線を字形に合わせて複数の線に分ける処理 | CSS・リンク・外部画像のノードを拒否するため 0 回。公開パーサに trust スイッチはない。class、id、data は上流マクロが第 1 引数を捨て、第 2 引数だけが残る。[MacroExpander:810](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/MacroExpander.swift#L810) |
| [EngineScripts:8](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineScripts.swift#L8)・同 98、259、335、[EngineOps:64](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineOps.swift#L64)・同 182、[Surd:3](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/Surd.swift#L3)、[LayoutOptions:21](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/LayoutOptions.swift#L21) | 分数、根号、上下付き、上下限の基底と付属物。積分記号には固定の楕円を重ねる | 子の数はノードごとに固定。根号の字形は有限の表から選ぶ。明示寸法は個別に 4,096 em、分数線は最大 8 倍の寄与を寸法予算に計上する。上付き・下付きと明示サイズの重ね合わせも上下の倍率制限を通す。 |
| [EngineArrays:25](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineArrays.swift#L25)・同 67、113、139、164、202、251、[EngineCDProof:471](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineCDProof.swift#L471)・同 494、530、542、596 | 空セル・行境界の補充、行・列・区切り・タグ配列、CD の矢印とラベルの再組版 | 矩形にしたセルは全配列で計 8,192。列記述・罫線も計数。CD は通常セル 1 回、矢印とラベルは最大 2 回分を計上。名前付きサイズは 11 通り。 |
| [EngineDelims:16](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineDelims.swift#L16)・同 126、145、179、208、215、276、425、505、[StackedDelim:166](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/StackedDelim.swift#L166)・同 192、221 | middle の探索と高さの再計算、整数 SVG 座標、積み上げる括弧 | 同じ単一行の直接の middle だけを伸縮対象にし、2 回目に兄弟の変換を再実行しない。上下端を求める際の寸法予算は下記。固定サイズの索引は 1～4。縦棒の反復数は高さの切り上げに使う浮動小数点値で、反復分の配列を作らない。組み立て式の波括弧は固定の 9 部品以下。 |
| [EngineTextStyles:203](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineTextStyles.swift#L203)・同 308、324、[Engine:389](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/Engine.swift#L389)、[EngineMisc:7](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineMisc.swift#L7)・同 99、176、238、443、511、[EngineAccent:24](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineAccent.swift#L24)・同 46、57 | 二重描画、取消線、枠・背景、円囲み、アクセント、不可視の箱、合成記号 | pmb の内側では描画単位を 2 倍にする。枠は背景 1 枚＋辺 4 本、取消線は 1～2 本。phantom は中身を 1 回組んで消すため、中身にも課金。合計は実ボックスでも 65,536 単位以内。 |
| [EngineCDProof:690](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineCDProof.swift#L690)・同 719、770、822、846、903、[ToDisplay:545](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/ToDisplay.swift#L545) | 証明木の前提を再帰的に組み、子の配置と罫線を祖先へ複写し、ラベルを含む外接範囲を取り直す | 証明の深さは 32。段数×枝数を予算に算入。ラベルや分岐がある場合は再配置の寸法も段ごとに保守的に見積もる。証明の破線も線の長さに応じて課金。 |
| [KaTeXSvg:83](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/KaTeXSvg.swift#L83)・同 119、237、435、449、589、886、905、[KaTeXSvgData:8](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/KaTeXSvgData.swift#L8)、[EngineMisc:266](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineMisc.swift#L266)・同 344、[EngineCDProof:219](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/EngineCDProof.swift#L219) | 伸縮記号のパス解析、曲線の折れ線化、切り抜き、パス配列の結合 | 固定データの 55 パスを集計。1 パス最大 358 点（曲線は 16 分割）、部品は最大 3 個、切り抜き後は辺ごとに最大 2 命令。追加の軸を含め 1 構築 4,096 命令以内、1 式 256 構築以内。生成した命令は描画前に再度 65,536 単位の枠で数える。上流のキャッシュ容量は解析済み 512 件、伸縮結果 128 件。 |
| [ToDisplay:139](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/ToDisplay.swift#L139)・同 180、284、368、392、412、420、436、552、[LayoutBox:228](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/LayoutBox.swift#L228) | 箱の展開、縦破線を矩形に分ける浮動小数点ループ、水平・証明罫の破線、行列のセルとタグ | AST で線数×長さを予約し、実際の箱の長さ・線幅・倍率で再計算。線数×（1＋長さ÷半周期の切り上げ）が残り 65,536 単位に収まる場合だけ描画。SVG の水平破線も課金する。 |
| [ToDisplay:16](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Layout/ToDisplay.swift#L16)・同 466、517、573、639、[SVGRenderer:77](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/SVG/SVGRenderer.swift#L77)・同 124、151、179、343、400 | パスの拡大、実際の外接矩形を求める走査、座標移動、SVG 文字列への変換 | ボックス・線・パス命令の総数に対する固定回数の走査。色の整数化は有限判定後の 0～255。十進指数のゼロ埋めは Float の指数範囲内。Surimono はテキスト字形を出力し、外部の輪郭プロバイダーを渡さない。 |

## 座標と破線の境界

- 各ノードに固定の字形・空き用に 8 em を割り当てる。固定フォント表の 2,131 エントリーでは、絶対値で求めた高さ＋深さの最大は 3.00003 em、幅＋イタリック補正の最大は 2.33334 em。これに入力で指定した寸法、行の支柱と行間、親での拡大を加える。子が縮小されても、縮小前の局所寸法を割り引かない。式全体の寸法の見積もりは 500,000 em まで。
- 区切りの高さを求める式は中心軸から遠い端までの距離の 2 倍以下に、軸・字形の丸め分を加えた範囲に収まる。見積もりには left/right の子の寄与を 4 倍で入れる。整数化に渡る値の余裕を含めた上界は (2 × 500,000 ＋ 16) × 1,000 ＝ 1,000,016,000。固定サイズの縦棒の補正は個別の 4 種類に限る。いずれも符号付き 32 ビットに収まり、macOS の Int は 64 ビット。
- 倍率積は 1/65,536～4,096。寸法 0 は幅のない罫線などに使える。ループの刻みには正規の正数を要求する。描画前に認める破線の周期は少なくとも 2⁻¹⁸ em。実ボックスの縦移動量の絶対値の和を 2²⁶ em に制限する。基線・高さ・位置ずれを重ねて絶対座標をその 8 倍に見積もっても、Double の隣接値の間隔は 2⁻²³ em 以下で、周期の半分より小さい。
- 各検査は上流 0.6.0 の計算式と固定データを前提にする。SwaTex の更新時には、構文ノードの追加だけでなく既存ノードの再描画・部品数・単位換算の変更も再点検する。

## 構文解析前の利用者マクロ

### 通常表示

パーサーに渡す文字列は従来の「定義＋原式」。LaTeX 文書では、この「定義」はリーダーが従来 SwaTex 向けに正規化した前文を指す。定義の索引で、使われた名前がグループ内の代入や未対応の別名なら、その式だけを原文で示す。証明に通った場合も、参照先だけに切り詰めた前文や、展開済みの数式をパーサー入力に使わない。Markdown の式先頭に連続するトップレベルの宣言も前文として検査する。式の途中の代入は認めない。[入力の選択](Sources/SurimonoFormats/AppMathInput.swift)・[文書の定義](Sources/SurimonoFormats/PreviewMathDefinitions.swift)

[計数器](Sources/SurimonoFormats/NativeMathBound.swift) は、合計 65,536 バイトまでの入力を固定版の Lexer で字句解析する。置換文字列や置換先のトークン配列を作らず、次の順で見積もる。

1. 各宣言について本文トークンとその UTF-8 長、グループの内側を含む引数番号ごとの使用回数を読み取る。式から到達する呼び出し先をメモ化し、出現ごとに本文・転送・展開回数の費用を加える。循環、深さ 32 超、未監査の命令、実行時に定義やトークンの意味を変える操作は拒否する。単純な `\let` は代入元の意味を展開しない。別名を呼ぶ式は拒否し、未使用の別名は後続の式を妨げない。
2. 引数に渡り得る長さには式全体の上界を使う。引数は重ならないので、一つの呼び出しの複写倍率は引数別の使用回数の最大値。線形な転送をたどって次に現れ得る複写が一つなら、その倍率を掛けて本文の先へ進む。同時に複数の複写候補がある場合は、一方がもう一方を引数として取り込む可能性がある。全入力と到達する本文が、リテラル・引数番号・グループ・必須引数をすべて明示的なグループで与えた利用者呼び出しだけからなる場合に限り、兄弟へはみ出さないことを検査して各経路の最大倍率を使う。この場合もサイズには引数の切片を使わない。区切り付き引数、末尾の引数待ち命令、先読みを含み、この独立性を示せない複数複写は拒否する。
3. 乗算・加算は 65,537 で飽和させる。本文と呼び出し先の費用に複写倍率を適用し、出力・展開中の置換量を 8,192 バイト、前文・原式および引数転送を含む累計を 65,536 バイト、宣言・許可した組み込みを含む展開を 999 回までとする。空の置換にも 1 回を課す。`\def` など、固定版で展開回数を消費しない代入自体は入力バイトに含める。文書の定義を使う SwaTex の配列挿入や `fetch()` はこの検査のあとでしか呼ばれない。[代入と置換](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/MacroExpander.swift#L273)

利用者定義と組み合わせる組み込みには、固定版で確認した記号、線形な引数読み取り、展開費用を定数で抑えられる補助命令だけを認める。`\TextOrMath` は二つの引数の片方だけを返す。固定本文 265 個の中で同一引数を繰り返すのは `\tmspace`。`\bra@ket` は縦棒が出るたびに区切り引数を挿入し、`\bra@set` は最初の区切りを置換する。これらと公開入口 `\Braket`・`\Set`・`\set` は利用者定義を含む入力で拒否する。生成した TeX を読み直す `\ce`・`\pu` にも上界を与えていない。`\expandafter`、条件分岐、catcode 変更、間接的な名前解決、本文内の再定義、組み込みが暗黙に使う名前の上書きも同様。マクロなしの通常表示では従来の組み込み用の検査を使う。[固定本文](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/BuiltinMacros.swift)・[関数型マクロ](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/MacroExpander.swift#L625)

生の `\newcommand` 系に既定引数や星が付くと、0.6.0 は `[` を本文または `*` を定義先として読む。`boundedRawSignature` が許すのは、単独の宣言と、後続トークンが限定された場合だけ。ここは **SwaTex の更新ごとに** Lexer と `handleNewcommand` の実装に突き合わせる。関数表、組み込み本文、暗黙の呼び出し先・環境内の代入、展開回数の加算箇所も同時に再点検する。[固定版の読み取り](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/MacroExpander.swift#L534)

### LaTeX の前処理

xparse、カウンター、利用者環境は数式リーダーが先に扱う。数式内の `\csname` は名前の中身を読む前にその式の `ReaderMathBudget.refused` を立てる。名前を組み立てるために本文用リーダーを起動しない。数式の置換・検査はその予算に記録し、文書全体の `stopsExpanding` を立てない。通常の本文は引き続き 1 置換 100,000 UTF-8 バイト、挿入は文書の残り予算（初期値 2,000,000）まで。[数式の処理](Sources/SurimonoFormats/LaTeXMathMacros.swift)・[名前解決](Sources/SurimonoFormats/LaTeXMacros.swift)

### Finder で展開前のトークンを保護する命令

Finder は 4,096 バイト以内の式と選ばれた定義を自身で展開する。SwaTex に渡す利用者定義は空。引数をそのまま取る、文字列・寸法を読む、または次のトークンを先読みする位置に利用者マクロが来たら、その式を原文表示にする。展開本文から出た命令にも同じ判定を行う。固定個数で読み終わりを確認できる引数に限り、その後の展開を再開する。生の引数や任意引数、未分類の命令、読み取り命令を返し得る `\TextOrMath` の先まで判断できない場合は、その式の残りでも利用者マクロを展開しない。`^`・`_` の引数も検査する。[Finder の展開器](Sources/SurimonoFormats/PreviewMathExpansion.swift)

<details>
<summary>固定版の関数登録 318 件のうち、必須または任意の引数を宣言する 179 命令</summary>

```text
\" \' \. \= \@binrel \@char \Bbb \Big \Bigg \Biggl \Biggm \Biggr \Bigl \Bigm \Bigr \H \Overrightarrow
\\abovefrac \\atopfrac \\bracefrac \\brackfrac \^ \` \above \acute \angl \bar \bcancel \begin \big \bigg
\biggl \biggm \biggr \bigl \bigm \bigr \binom \bm \bold \boldsymbol \breve \c \cancel \cfrac \check
\color \colorbox \dbinom \ddot \dfrac \dot \emph \end \fbox \fcolorbox \frac \frak \genfrac \grave \hat
\hbox \href \hskip \hspace \html@mathml \htmlStyle \kern \left \mathbb \mathbf \mathbin \mathcal
\mathchoice \mathclap \mathclose \mathfrak \mathinner \mathit \mathllap \mathnormal \mathop \mathopen
\mathord \mathpunct \mathrel \mathring \mathrlap \mathrm \mathscr \mathsf \mathsfit \mathtt \middle
\mkern \mskip \operatorname@ \operatornamewithlimits \overbrace \overbracket \overgroup \overleftarrow
\overleftharpoon \overleftrightarrow \overline \overlinesegment \overrightarrow \overrightharpoon
\overset \phantom \phase \pmb \r \raisebox \right \rule \smash \sout \sqrt \stackrel \tbinom \text
\textbf \textcircled \textcolor \textit \textmd \textnormal \textrm \textsc \textsf \textsl \texttt
\textup \tfrac \tilde \u \underbrace \underbracket \undergroup \underleftarrow \underleftrightarrow
\underline \underlinesegment \underrightarrow \underset \url \utilde \v \vcenter \vec \vphantom
\widecheck \widehat \widetilde \xLeftarrow \xLeftrightarrow \xRightarrow \xcancel \xhookleftarrow
\xhookrightarrow \xleftarrow \xleftequilibrium \xleftharpoondown \xleftharpoonup \xleftrightarrow
\xleftrightharpoons \xlongequal \xmapsto \xrightarrow \xrightequilibrium \xrightharpoondown
\xrightharpoonup \xrightleftarrows \xrightleftharpoons \xtofrom \xtwoheadleftarrow \xtwoheadrightarrow
\~
```

</details>

<details>
<summary>定義本文の中で引数を取る組み込みマクロ 27 個と、別に登録されるハンドラー 23 個</summary>

本文に引数番号があるもの

```text
\@hspace \@hspacer \Bra \Ket \blue \boxed \bra \braket \clap \ddddot \dddot \gray \green \hphantom \ket
\llap \mod \orange \pink \pmod \pod \purple \red \rlap \substack \tmspace \underbar
```

`addFunctionMacros` にある本文表以外の名前。`\operatorname` は `\@ifstar` を経由する。

```text
\@firstoftwo \@ifnextchar \@ifstar \@secondoftwo \DeclareMathOperator \TextOrMath \bra@ket \bra@set \ce
\char \dotsc \errmessage \expandafter \htmlClass \htmlData \htmlId \message \newcommand \noexpand
\operatorname \providecommand \pu \renewcommand
```

</details>

登録引数数がゼロの命令にも先読みがある。`\\`・`\newline` は任意の `[size]`、`\hspace`・`\operatorname`・`\tag` は星、`\dotsc` は次の句読点・右区切りを見る。`\char` は数字列または逆引用符の直後の生トークン、`\verb` は字句解析中に区切り文字までを読む。定義系プリミティブ `\def`・`\gdef`・`\edef`・`\xdef`・`\let`・`\futurelet`、接頭辞 `\global`・`\long`、行列・配列環境の位置や行間指定も登録引数数だけでは尽くせない。このため Finder は未知の命令を安全な記号として通さない。[関数引数の読み方](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/Parser.swift#L409)・[行末の先読み](https://github.com/PhraseHQ/SwaTex/blob/153738a2bcdcb62450ead9ab292989e3de0a449f/Sources/SwaTex/Parser/Functions/Cr.swift#L24)

書体宣言（`\rm`・`\sf`・`\tt`・`\bf`・`\it`・`\cal`）、スタイル宣言（`\displaystyle`・`\textstyle`・`\scriptstyle`・`\scriptscriptstyle`）、寸法宣言（`\tiny` から `\Huge`）、`$`・`\(` も、登録引数数はゼロだが区切りまで式を読み進める。生文字列の引数を持つ例は `\color`・`\textcolor`・`\htmlStyle`、URL は `\href`・`\url`、寸法は `\kern`・`\hskip`・`\rule`。直接の先読みをする固定本文の別名も同じ保守的な扱いになる。

## 互換性の再検証

`make math-corpus` は変更前 `1435ed1b` から採取した数式 SVG と原文表示 HTML を、文書内の出現順・全バイトの SHA-256 で照合する。次表のマクロ使用数は、生成された SVG のうち実際に利用者マクロを呼んだ式数。前文を持つ文書では、マクロを呼ばない式も同じ前文で組む。[比較テスト](Tests/SurimonoFormatsTests/AppMathCorpusTests.swift)・[文書別の基準](Tests/SurimonoFormatsTests/Fixtures/app-math.tsv)

| 通常表示の対象 | 文書 | SVG | 利用者マクロを呼ぶ SVG | うち自前展開 | うち静的検査後に SwaTex | 従来から原文表示 | 新たな原文表示 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Quick Look 比較と同じ一覧 | 333 | 183 | 3 | 0 | 3 | 1 | 0 |
| 全サンプル・fixture・スナップショット原稿 | 350 | 190 | 3 | 0 | 3 | 2 | 0 |

論文の生の定義を使う差分テストは 232 式。230 式が静的検査を通り、元の定義＋原式を SwaTex に渡す。そのうち 229 式が組まれ、インライン・別行の 458 SVG が旧経路とバイト一致する。残る 3 式は、既定を省いた `\expect{X}`、生の `\newcommand*` で定義した `\density{x}`、置換本文を波括弧で囲まない `\def` の `\unitdx`。最初の 1 式は上界の検査後に SwaTex が構文エラーを返し、後者 2 式は検査で拒否する。3 式とも旧パーサーで同じ入力の構文エラーを独立に確認する。別に、LaTeX リーダーで正規化される星・既定引数の 10 式も比較する。[差分テスト](Tests/SurimonoFormatsTests/AppMathDifferentialTests.swift)

[計数テスト](Tests/SurimonoFormatsTests/AppMathInputTests.swift) は通常式の実展開と上界、拒否直前の回数・バイト、名前解決後の式の独立性を調べる。[子プロセステスト](Tests/SurimonoCoreTests/MathWorkProcessTests.swift) は引数の入れ子複写と引数なしの倍増列を Markdown と LaTeX の両方で開く。該当式の原文、後続の `a+b` と利用者マクロの SVG、末尾の本文を検査する。上限は実時間 15 秒、CPU 8 秒、最大 RSS 512 MiB。

元の前文と原式の合計が 64 KiB を超える場合は、使わない定義があってもその入力を渡せない。未監査の組み込みと利用者マクロを組み合わせた場合も原文表示になり得る。上界の単位は、扱うトークンの UTF-8 長と展開回数。Swift のアロケーターの使用バイト数、配列挿入に伴う要素移動、SwaTex 全体の構文解析・描画時間、WebKit や Finder を含むプロセス全体の RSS・実時間までは証明しない。
