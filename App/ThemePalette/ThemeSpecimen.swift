import Foundation
import SurimonoCore
import SurimonoRendering

enum ThemeSampleSource: String, CaseIterable {
    case document
    case specimen
}

enum ThemeSpecimen {
    // The specimen keeps default typography; the window supplies its current layout and orientation.
    static var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "", name: "", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    static func source(language: String, format: DocumentFormat? = nil) -> DocumentSource {
        if format == .latex {
            // A Markdown specimen lacks the title, section and equation markup these styles are designed to print.
            let code = UILanguage.candidates(for: language).first(where: UILanguage.supported.contains) ?? "en"
            let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
            func sample(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: nil) }
            let source = #"""
                \documentclass{\#(code == "ja" ? "jsarticle" : "article")}
                \title{\#(sample("A Little Library"))}\author{Surimono}\date{}
                \begin{document}\maketitle
                \section{\#(sample("Today’s reading"))}
                \#(sample("An open book changes the everyday view."))

                \#(sample("Keep a few words on paper, then look for the next book on the shelf."))
                \begin{equation}S_n = \sum_{k=1}^{n} k = \frac{n(n+1)}{2}\end{equation}
                \end{document}
                """#
            return DocumentSource(data: Data(source.utf8), format: .latex)
        }
        return DocumentSource(data: Data(markdown(language: language).utf8), format: .markdown)
    }

    /// Running text around one of each element (headings, a list, a table, code, a quote), long enough to fill most of
    /// the first page in the standard style, so that styles differing in type and spacing differ in the samples too. It
    /// still fits on one page in the roomier styles the tests compose; the largest type runs over, and a sample shows
    /// only the first page.
    static func markdown(language: String) -> String {
        if language.lowercased().split(separator: "-").first == "ja" {
            return """
                # 小さな図書室

                本をひらくと、いつもの景色が少し変わります。**大切な言葉**を紙に残しましょう。町の角の小さな図書室には、古い旅の本や星の図鑑が並んでいます。

                ## 今日の読書

                午後は気になる一冊を手に取り、ゆっくりページをめくります。読み終えたら、心に残った一文をカードに書き写します。

                - 気になる一冊を選ぶ
                - 心に残った言葉をメモする
                - 次に読む本を棚から探す

                | 本 | 棚 | ページ |
                | --- | --- | --- |
                | 旅の記録 | A | 120 |
                | 星の話 | B | 86 |
                | 海の地図 | C | 64 |

                ## 書き写すとき

                カードには日付と書名を添えておくと、あとで読み返すときに迷いません。長い文は全部を写さず、いちばん響いたところだけを選びます。

                ```swift
                let books = 3
                print("Hello, books!")
                ```

                > 読む時間は、新しい景色への入口です。

                ### 次の一冊

                棚の端に、表紙の色があせた小さな詩集が一冊残っています。次の休みにはこの本を開いて、また新しい言葉を探しましょう。
                """
        }
        return """
            # A Little Library

            An open book changes the everyday view. Keep **a few words** on paper. On the corner of the street, a little library keeps old travel books and a guide to the stars.

            ## Today's reading

            In the afternoon, take down a book that caught your eye and turn the pages slowly. When you finish, copy the sentence you liked best onto a small card.

            - Choose a book
            - Note a favorite passage
            - Find the next book on the shelf

            | Book | Shelf | Pages |
            | --- | --- | --- |
            | Travel notes | A | 120 |
            | Star stories | B | 86 |
            | Sea charts | C | 64 |

            ## Copying a passage

            Add the date and the title to each card, so that you know where it came from. Copy only the part that stayed with you, not the whole page.

            ```swift
            let books = 3
            print("Hello, books!")
            ```

            > Reading opens a window to another place.

            ### The next book

            At the end of the shelf there is one book still unread: a small book of poems with a faded cover. Open it on your next day off, and look for new words again.
            """
    }
}
