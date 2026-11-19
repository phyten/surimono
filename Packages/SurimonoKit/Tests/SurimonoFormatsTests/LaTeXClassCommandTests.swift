import SurimonoFormats
import Testing

struct LaTeXClassCommandTests {
    @Test("クラスが持つ命令を条件分岐で認識し、他のクラスでは原稿の代替定義を使う")
    func classCommands() {
        for (cls, names) in [
            ("scrreprt", ["setkomafont", "addtokomafont"]), ("memoir", ["chapterstyle"]),
            ("exam", ["fillin", "firstpageheader", "numpoints", "gradetable", "solution"]),
            ("letter", ["signature", "opening", "closing", "encl"]),
            ("moderncv", ["makecvtitle", "cventry", "cvitemwithcomment", "phone", "photo"]),
        ] {
            for name in names {
                let probe = "\\ifdefined\\\(name) Class branch.\\else Fallback branch.\\fi"
                func body(_ cls: String, _ code: String) -> String {
                    LaTeXConverter.convert("\\documentclass{\(cls)}\\begin{document}\(code)\\end{document}").body
                }
                #expect(body(cls, probe).contains("Class branch."))
                let fallback = body("article", probe + "\\providecommand{\\\(name)}{Installed fallback.}\\\(name)")
                #expect(fallback.contains("Fallback branch.") && fallback.contains("Installed fallback."))
            }
        }
    }

    @Test("設問や選択肢の命令はリストに入る時に代替定義を隠し、リストを出た後で戻す")
    func localExamCommands() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass{exam}
            \providecommand{\question}{Outside questions.}
            \begin{document}
            \ifdefined\choice Wrong branch.\fi
            \begin{questions}\question[1] Prompt.
            \begin{choices}\ifdefined\choice \choice Choice text.\fi\end{choices}
            \end{questions}\question
            \end{document}
            """#
        ).body
        #expect(html.contains("(1 point) Prompt.") && html.contains("A.</span> Choice text."))
        #expect(html.components(separatedBy: "Outside questions.").count == 2)
        #expect(!html.contains("Wrong branch."))
    }

    @Test("テンプレートの代替命令で本来の採点表・章書式・書簡や履歴書の要素を上書きしない")
    func providedFallbacks() {
        for (cls, command, body, expected) in [
            ("scrartcl", "setkomafont", #"\setkomafont{section}{\itshape}\section{Fold}"#, "data-latex-koma-heading"),
            ("memoir", "chapterstyle", #"\chapterstyle{hangnum}\chapter{Fold}"#, #"data-latex-memoir-style="hangnum""#),
            (
                "exam", "gradetable", #"\begin{questions}\question[3] Fold\end{questions}\gradetable"#,
                "latex-exam-table"
            ),
            ("letter", "opening", #"\begin{letter}{Desk}\opening{Hello}\end{letter}"#, "latex-letter-opening"),
            ("moderncv", "cventry", #"\cventry{2025}{Folds}{Desk}{}{}{Test}"#, "latex-cv-item"),
        ] {
            let result = LaTeXConverter.convert(
                "\\documentclass{\(cls)}\\providecommand{\\\(command)}{Replaced class command.}"
                    + "\\begin{document}\(body)\\end{document}")
            #expect(result.body.contains(expected))
            #expect(!result.body.contains("Replaced class command."))
        }
    }
}
