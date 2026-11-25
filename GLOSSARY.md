# 用語集 / Glossary

画面に出す言葉の対訳表。同じものに 2 つの語を使わないために、ここで 1 つに決める。

- 文言を足す・直すときは、この表の語を使う。活用や複数形は変えてよい（ドイツ語の Sammelbände、スペイン語の compilaciones など）。
- 新しい概念（新しい画面・機能・形式に固有の名前）を足すときは、8 言語の語を決めて、先にこの表へ 1 行足す。
- 語を変えるときは、この表と `App/Localizable.xcstrings` の該当する訳を同じ変更で直す。
- 「確かめるキー」は `App/Localizable.xcstrings` のキー。その訳に各言語の語が入っていることを `AppTests/GlossaryTests.swift` が確かめるので、表と訳がずれるとテストが落ちる。
- 使わなくなった語（Sammlung、Recopilación、フォルダー など）は `AppTests/LanguageTests.swift` の `consistentTerms` が見張る。語を 1 つに揃えたら、外した語をそこへ足す。

言語ごとの決まり（2026-11-22 に、その言語に通じたレビューで決めた）:

- 韓国語の「ウインドウ」は 창。メニューバーの「ウインドウ」メニューの名前と「ウインドウを閉じる」「ウインドウを順に切り替える」だけは、macOS が同じメニューに足す項目に合わせて 윈도우 にする。
- ドイツ語の「用紙」は Blatt／Blätter。Druckbogen と Bogen は使わない（組版ソフトでは見開きの意味に取られる）。
- 中国語の「用紙」は 纸张／紙張。用纸／用紙 は使わない。数えるときは助数詞の 张／張 だけにする（下一张）。

| 概念 | 確かめるキー | en | ja | de | es | fr | ko | zh-Hans | zh-Hant |
|---|---|---|---|---|---|---|---|---|---|
| 最近使ったファイルがないときの表示 | `No Recent Files` | No Recent Files | 最近使ったファイルはありません | Keine zuletzt verwendeten Dateien | No hay archivos recientes | Aucun fichier récent | 최근 파일 없음 | 没有最近使用的文件 | 沒有最近使用的檔案 |
| 複数の文書をまとめたもの | `Binder` | Binder | 合本 | Sammelband | Compilación | Recueil | 합본 | 合订本 | 合訂本 |
| 複数の画像をまとめたもの | `Opens as an image bundle in another window` | image bundle | 画像の束 | Bilderstapel | lote de imágenes | lot d’images | 이미지 묶음 | 图像集 | 影像集 |
| 用紙を並べて刷る画面 | `Open the print screen` | print screen | 印刷画面 | Druckbildschirm | pantalla de impresión | écran d’impression | 인쇄 화면 | 打印界面 | 列印畫面 |
| 刷ること | `Print` | Print | 印刷 | Drucken | Imprimir | Imprimer | 인쇄 | 打印 | 列印 |
| 刷る機械 | `Printer` | Printer | プリンター | Drucker | Impresora | Imprimante | 프린터 | 打印机 | 印表機 |
| 紙面の見た目 | `Style` | Style | スタイル | Stil | Estilo | Style | 스타일 | 样式 | 樣式 |
| 保存した設定の組 | `Setting Sets` | Setting Sets | 設定セット | Einstellungssätze | Conjuntos de ajustes | Jeux de réglages | 설정 세트 | 设置集 | 設定集 |
| 折ってとじる刷り方 | `Booklet Binding` | Booklet | 冊子 | Broschüre | folleto | livret | 소책자 | 小册子 | 小冊子 |
| とじる辺 | `Short-edge binding` | binding | とじ | Bindung | Encuadernación | Reliure | 제본 | 装订 | 裝訂 |
| 開いている窓 | `Fit to Window` | Window | ウインドウ | Fenster | ventana | fenêtre | 창 | 窗口 | 視窗 |
| 刷る紙の種類 | `Paper: %@` | Paper | 用紙 | Papier | Papel | Papier | 용지 | 纸张 | 紙張 |
| 刷り出す 1 枚 | `Next Sheet` | Sheet | 用紙 | Blatt | Hoja | Feuille | 용지 | 张 | 張 |
| 左右に並べた 2 ページ | `Spread` | Spread | 見開き | Doppelseite | Doble página | Double page | 두 페이지 | 双页 | 跨頁 |
| スライドの文書 | `Show as Slides` | Slides | スライド | Folien | diapositivas | diapositives | 슬라이드 | 幻灯片 | 投影片 |
| 開いているもの | `Document` | Document | 文書 | Dokument | Documento | Document | 문서 | 文档 | 文件 |
| フォルダ | `Choose Folder…` | Folder | フォルダ | Ordner | carpeta | dossier | 폴더 | 文件夹 | 檔案夾 |
| 見出しの一覧 | `Contents` | Contents | 目次 | Inhalt | Índice | Sommaire | 목차 | 目录 | 目錄 |
| ページの一覧 | `Pages Tab` | Pages | ページ | Seiten | Páginas | Pages | 페이지 | 页 | 頁 |
| 覚えた場所 | `Bookmarks` | Bookmarks | しおり | Lesezeichen | Marcadores | Signets | 책갈피 | 书签 | 書籤 |
| 窓の上下の操作の帯 | `Toolbar` | Toolbar | ツールバー | Symbolleiste | Barra de herramientas | Barre d’outils | 도구 막대 | 工具栏 | 工具列 |
| ツールバーの部品の表示 | `Parts` | Parts | 部品の表示 | Teile | Piezas | Éléments | 부품 | 部件 | 部件 |
| 別の形式で保存すること | `Export` | Export | 書き出す | Exportieren | Exportar | Exporter | 내보내기 | 导出 | 輸出 |
| アプリを新しくすること | `Updates` | Updates | アップデート | Updates | Actualizaciones | Mises à jour | 업데이트 | 更新 | 更新 |
| 取り除く要素の決まり | `Preset` | Preset | プリセット | Voreinstellung | Preajuste | Préréglage | 프리셋 | 预设 | 預設 |
| 書き込み用のページ | `Notes` | Notes | ノート | Notizen | Notas | Notes | 노트 | 笔记 | 筆記 |
| 選んで残したスタイル | `Favorites` | Favorites | お気に入り | Favoriten | Favoritos | Favoris | 즐겨찾기 | 个人收藏 | 喜好項目 |
| スタイルの区分への移動 | `Jump to Category` | Jump to Category | カテゴリーへ移動 | Zur Kategorie springen | Ir a la categoría | Aller à la catégorie | 카테고리로 이동 | 跳转到类别 | 跳至類別 |
| 紙面の数式 | `Formula Exceeds the Text Width` | Formula | 数式 | Formel | fórmula | formule | 수식 | 公式 | 公式 |
| 文章の確認タブ | `Writing` | Writing | 文章 | Text | Texto | Texte | 글 | 文章 | 文章 |
| 文章を点検する操作 | `Check Writing` | Check Writing | 文章の確認 | Text prüfen | Revisar texto | Vérifier le texte | 글 확인 | 检查文章 | 檢查文章 |
| 同じ語が続いた箇所 | `Repeated Word` | Repeated Word | 続いた語 | Doppeltes Wort | Palabra duplicada | Mot doublé | 연달아 나온 같은 단어 | 连续重复的词 | 連續重複的詞 |
| 近くで繰り返した語 | `Close Repetition` | Close Repetition | 近い繰り返し | Wiederholungen in kurzem Abstand | Repetición cercana | Répétition rapprochée | 가까이 쓰인 같은 단어 | 邻近重复 | 鄰近重複 |
| 長さを確認する文 | `Long Sentence` | Long Sentence | 長い文 | Langer Satz | Oración larga | Phrase longue | 긴 문장 | 长句 | 長句 |
| 文書の読み方を選ぶ設定 | `Reading Settings` | Reading Settings | 読み方の設定 | Leseeinstellungen | Ajustes de lectura | Réglages de lecture | 읽기 설정 | 阅读设置 | 閱讀設定 |
| 見出しの全階層 | `All Levels` | All Levels | すべての階層 | Alle Ebenen | Todos los niveles | Tous les niveaux | 모든 수준 | 所有层级 | 所有層級 |
| 見出しの階層の上限 | `Up to Level %lld` | Up to Level %lld | %lld 階層まで | Bis Ebene %lld | Hasta el nivel %lld | Jusqu’au niveau %lld | 수준 %lld까지 | 最多 %lld 层 | 最多 %lld 層 |
| 下付き・上付きの条件 | `Only in { }` | Only in { } | { } で囲んだときのみ | Nur in { } | Solo entre { } | Seulement entre { } | { }로 감쌀 때만 | 仅限 { } 内 | 僅限 { } 內 |
| 文書内の変更をすべて戻す | `Revert All` | Revert All | すべて戻す | Alles zurücksetzen | Revertir todo | Tout rétablir | 모두 되돌리기 | 全部还原 | 全部還原 |
| Org で見出しとして扱う階層 | `Levels Shown as Headings` | Levels Shown as Headings | 見出しにする深さ | Ebenen als Überschriften | Niveles como títulos | Niveaux de titres | 제목으로 표시할 깊이 | 显示为标题的层级 | 顯示為標題的層級 |
| Org の見出し末尾のタグ | `Heading Tags` | Heading Tags | 見出しのタグ | Überschriften-Tags | Etiquetas de títulos | Tags des titres | 제목 태그 | 标题标签 | 標題標籤 |
| Org の予定・締め切り・完了の日時 | `Planning Lines` | Planning Lines | 予定と締め切り | Planungszeilen | Líneas de planificación | Lignes de planification | 일정 및 마감 | 计划与截止日期 | 排程與截止日期 |
| Org の作業時間を計った行 | `Clock Lines` | Clock Lines | 作業時間の記録 | Zeiterfassung | Registros de tiempo | Relevés de temps | 작업 시간 기록 | 工时记录 | 工時紀錄 |
| Org の見出しのタスク状態を表す語 | `TODO Keywords` | TODO Keywords | TODO キーワード | TODO-Schlüsselwörter | Palabras clave TODO | Mots-clés TODO | TODO 키워드 | TODO 关键字 | TODO 關鍵字 |
| Org の見出しやリストに書く進捗 | `Completion Percentages and Counts` | Completion Percentages and Counts | 完了率と件数 | Fortschritt in % und Anzahl | Progreso (% y número) | Progression (% et nombre) | 완료율 및 건수 | 完成率与计数 | 完成率與計數 |
| Org の名前付きドロワー | `Drawers` | Drawers | ドロワー | Drawer | Cajones | Tiroirs | 드로어 | 抽屉 | 抽屜 |
| Org のプロパティを収めるドロワー | `Property Drawers` | Property Drawers | プロパティドロワー | Eigenschaften-Drawer | Cajones de propiedades | Tiroirs de propriétés | 속성 드로어 | 属性抽屉 | 屬性抽屜 |
| Org で日時だけの段落にある日時 | `Standalone Timestamps` | Standalone Timestamps | 単独の日時 | Einzelne Zeitstempel | Marcas de tiempo aisladas | Horodatages isolés | 단독 타임스탬프 | 独立时间戳 | 獨立時間戳記 |
| Org のコロンで始める等幅の行 | `Fixed-Width Sections` | Fixed-Width Sections | 等幅の行 | Zeilen in Festbreitenschrift | Líneas de ancho fijo | Lignes à chasse fixe | 고정폭 줄 | 等宽行 | 等寬行 |
| Org で ARCHIVE タグを付けた部分木 | `Archived Trees` | Archived Trees | アーカイブした項目 | Archivierte Teilbäume | Subárboles archivados | Branches archivées | 보관된 하위 트리 | 已归档的子树 | 已封存的子樹 |
