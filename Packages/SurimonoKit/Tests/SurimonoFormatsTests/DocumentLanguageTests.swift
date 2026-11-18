import Testing

@testable import SurimonoFormats

struct DocumentLanguageTests {
    @Test(
        "本文の文字と言語を判定する",
        arguments: [
            ("これは架空の図書館について書いた日本語の文章です。明日は新しい本を読みます。", "ja"),
            ("Swift API function render document cache。これは印刷するための日本語の説明です。", "ja"),
            (
                "The imaginary library opens every morning. Visitors can read books and write their own stories in a quiet room.",
                "en"
            ),
            (
                "Die kleine erfundene Bibliothek öffnet jeden Morgen. Die Besucher lesen Bücher und schreiben ihre eigenen Geschichten.",
                "de"
            ),
            (
                "La bibliothèque imaginaire ouvre chaque matin. Les visiteurs peuvent lire des livres et écrire leurs propres histoires.",
                "fr"
            ),
            (
                "La biblioteca imaginaria abre todas las mañanas. Los visitantes pueden leer libros y escribir sus propias historias.",
                "es"
            ),
            ("这是一座虚构的图书馆，每天早上都会开放。读者可以在这里阅读书籍，学习新的知识，并且记录自己的生活经验。", "zh-Hans"),
            ("這是一座虛構的圖書館，每天早上都會開放。讀者可以在這裡閱讀書籍，學習新的知識，並且記錄自己的生活經驗。", "zh-Hant"),
            ("가상의 도서관은 매일 아침 문을 엽니다. 방문객들은 책을 읽고 새로운 이야기를 씁니다.", "ko"),
            (
                "Вымышленная библиотека открывается каждое утро. Посетители читают книги и пишут собственные рассказы.",
                "ru"
            ),
            ("تفتح المكتبة الخيالية أبوابها كل صباح. يقرأ الزوار الكتب ويكتبون قصصهم الخاصة في غرفة هادئة.", "ar"),
            ("הספרייה הדמיונית נפתחת בכל בוקר והמבקרים קוראים ספרים וכותבים סיפורים חדשים.", "he"),
            ("यह एक काल्पनिक पुस्तकालय है। यहाँ लोग हर सुबह किताबें पढ़ते हैं और अपनी नई कहानियाँ लिखते हैं।", "hi"),
            ("ห้องสมุดในจินตนาการเปิดทุกเช้า ผู้คนมาอ่านหนังสือและเขียนเรื่องราวของตนเองในห้องที่เงียบสงบ", "th"),
            (
                "Thư viện tưởng tượng mở cửa mỗi buổi sáng. Mọi người đến đọc sách và viết những câu chuyện của riêng mình.",
                "vi"
            ),
        ])
    func prose(text: String, expected: String) {
        #expect(DocumentLanguage.detect(html: "<p>\(text)</p>").code == expected)
    }

    @Test("かなのない漢字だけの長い一覧は、中国語と決めつけずに既定値に従う")
    func kanjiOnlyList() {
        let list = Array(repeating: "第一章 本文 東京都港区 山田太郎 会議資料 予定表 完了 目的", count: 6).joined(separator: " ")
        #expect(DocumentLanguage.detect(html: list).code == "ja")
        #expect(DocumentLanguage.detect(html: list, fallback: "en").code == "ja")
        #expect(DocumentLanguage.detect(html: list, fallback: "zh-Hant").code == "zh-Hant")
    }

    @Test("英語の用語や引用が大半でも、日本語の文がある文書は日本語のまま")
    func japaneseWithMostlyEnglish() {
        let terms = "<p>Kubernetes の Deployment を設定して、Ingress Controller と LoadBalancer を確認する。</p>"
        #expect(DocumentLanguage.detect(html: terms).code == "ja")
        let quotation =
            "<p>次の文を引用します。</p><p>"
            + String(repeating: "The administrative documentation necessitates comprehensive understanding. ", count: 3)
            + "</p><p>このように書かれています。</p>"
        #expect(DocumentLanguage.detect(html: quotation).code == "ja")
        let english =
            String(repeating: "The reading room opens at nine and the first visitors arrive early. ", count: 6)
            + "The sign says ようこそ."
        #expect(DocumentLanguage.detect(html: "<p>\(english)</p>").code == "en")
    }

    @Test("かなのない漢字は、中国語の機能語が 2 つ以上あるときだけ中国語にする")
    func chineseMarkers() {
        let kanji = String(repeating: "図書館 資料 整理 ", count: 8)
        #expect(DocumentLanguage.detect(html: kanji + "这").code == "ja")
        #expect(DocumentLanguage.detect(html: kanji + "这 们").code.hasPrefix("zh-"))
    }

    @Test("短い漢字は、既定値が日本語か中国語ならそれに、ほかなら日本語にする。文字がなければ既定値のまま")
    func fallback() {
        #expect(DocumentLanguage.detect(html: "会議 資料").code == "ja")
        #expect(DocumentLanguage.detect(html: "会議 資料", fallback: "zh-Hans").code == "zh-Hans")
        #expect(DocumentLanguage.detect(html: "会議 資料", fallback: "en").code == "ja")
        #expect(DocumentLanguage.detect(html: "12345", fallback: "fr").code == "fr")
        #expect(DocumentLanguage.detect(html: "Hello", fallback: "de").code == "de")
    }

    @Test("宣言を優先し地域と言語を正規化する")
    func declared() {
        #expect(DocumentLanguage.detect(html: "日本語です", declared: " zh_TW ").code == "zh-Hant")
        #expect(DocumentLanguage.detect(html: "日本語です", declared: "EN-us").code == "en-us")
        for invalid in ["日本語", "<script>", "en-", "e", "en--US"] {
            #expect(DocumentLanguage.detect(html: "これは日本語です", declared: invalid).code == "ja")
        }
        for code in ["ar", "fa", "ur", "he", "yi", "ps", "sd", "ug", "dv", "AR-eg"] {
            #expect(DocumentLanguage.detect(html: "", declared: code).isRightToLeft)
        }
        #expect(!DocumentLanguage.detect(html: "", declared: "en").isRightToLeft)
    }

    @Test("コードと数式と図を判定から除く")
    func excluded() {
        #expect(
            DocumentLanguage.detect(html: "<p>これは日本語です。</p><pre>" + String(repeating: "a", count: 5_000) + "</pre>")
                .code == "ja")
        let english =
            "<p>The imaginary library opens every morning. Visitors read books and write stories in a quiet room.</p>"
        for wrapper in [
            "pre", "code", "svg", "style", "script", "span class='math'", "div class='math-block'",
            "div class='mermaid-block'",
        ] {
            let tag = wrapper.split(separator: " ")[0]
            #expect(
                DocumentLanguage.detect(
                    html: english + "<\(wrapper)>" + String(repeating: "日本語の説明です", count: 100) + "</\(tag)>"
                ).code == "en")
        }
    }

    @Test("長い入力も制限時間内に判定する", .timeLimit(.minutes(1)))
    func bounded() {
        #expect(DocumentLanguage.detect(html: String(repeating: "あ", count: 200_000)).code == "ja")
        #expect(DocumentLanguage.detect(html: String(repeating: "<p", count: 100_000)).code == "ja")
        #expect(
            DocumentLanguage.detect(
                html: String(
                    String(repeating: "The imaginary library opens every morning and visitors read books. ", count: 400)
                        .prefix(20_000)) + String(repeating: "あ", count: 180_000)
            ).code == "en")
    }

    @Test("MarkdownとOrgから言語の宣言を引き継ぐ")
    func metadata() {
        #expect(MarkdownConverter.convert("---\nlang: 'zh_TW'\n---\n本文").language == "zh_TW")
        #expect(MarkdownConverter.convert("---\nlanguage: en\n---\n本文").language == "en")
        #expect(OrgConverter.convert("#+LANGUAGE: fr\n本文").language == "fr")
        #expect(OrgConverter.convert("#+begin_src text\n#+LANGUAGE: fr\n#+end_src\n本文").language == nil)
    }
}

extension DocumentLanguageTests {
    @Test("入れ子の数式とコメントと属性は本文に数えない")
    func nestedMarkup() {
        let noise = String(repeating: "English words ", count: 100)
        let html =
            "<!--\(noise)--><p title='\(noise) >'>これは日本語です。</p><span class='other math'><span>\(noise)</span><br>\(noise)</span>"
        #expect(DocumentLanguage.detect(html: html).code == "ja")
    }
}
