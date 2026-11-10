import Foundation
import SurimonoCore
import SurimonoRendering

enum ThemeSampleSource: String, CaseIterable {
    case document
    case specimen
}

enum ThemeSpecimen {
    // A fixed sheet keeps the specimen useful even when the user's sheet is small or its text is enlarged.
    static var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "", name: "", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    static func source(language: String) -> DocumentSource {
        DocumentSource(data: Data(markdown(language: language).utf8), format: .markdown)
    }

    static func markdown(language: String) -> String {
        if language.lowercased().split(separator: "-").first == "ja" {
            return """
                # 小さな図書室

                本をひらくと、いつもの景色が少し変わります。**大切な言葉**を紙に残しましょう。

                ## 今日の読書

                - 気になる一冊を選ぶ
                - 心に残った言葉をメモする

                | 本 | 棚 |
                | --- | --- |
                | 旅の記録 | A |
                | 星の話 | B |

                ```swift
                let books = 3
                print("Hello, books!")
                ```

                > 読む時間は、新しい景色への入口です。

                また次の一冊へ。
                """
        }
        return """
            # A Little Library

            An open book changes the everyday view. Keep **a few words** on paper.

            ## Today's reading

            - Choose a book
            - Note a favorite passage

            | Book | Shelf |
            | --- | --- |
            | Travel notes | A |
            | Star stories | B |

            ```swift
            let books = 3
            print("Hello, books!")
            ```

            > Reading opens a window to another place.

            On to the next book.
            """
    }
}
