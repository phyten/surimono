import Testing

@testable import SurimonoFormats

struct LaTeXRecognitionTests {
    private func recognition(_ preamble: String) -> LaTeXRecognition? {
        LaTeXConverter.convert(preamble + #"\begin{document}Text.\end{document}"#).latexClass?.recognition
    }

    @Test("登録された各クラスの表示名とクラス宣言を変換結果に残す")
    func classes() {
        let aliases = [
            "amsart": "AMS", "amsbook": "AMS", "amsproc": "AMS", "acmart": "ACM", "llncs": "LNCS",
            "revtex4-2": "REVTeX", "elsarticle": "Elsevier", "ipsj": "IPSJ", "ieice": "IEICE", "ieicej": "IEICE",
            "scrartcl": "KOMA-Script", "scrbook": "KOMA-Script", "scrreprt": "KOMA-Script",
        ]
        let societies = ["ipsj": "情報処理学会", "ieice": "電子情報通信学会", "ieicej": "電子情報通信学会"]
        for id in LaTeXClassRegistry.registeredNames {
            let declaration = #"\documentclass[11pt, a4paper]{\#(id)}"#
            #expect(
                recognition(declaration + #"\usepackage{unrelated}"#)
                    == .recognised(
                        name: .init(aliases[id] ?? id, japanese: societies[id]), detail: nil, source: declaration))
        }
    }

    @Test("学会パッケージの系統・年・モードと実際の読み込み行を表示する")
    func packages() {
        let entries: [(String, String, [(String, LaTeXRecognition.Mode)])] = [
            ("neurips_2026", "NeurIPS 2026", [("", .submission), ("final", .final), ("preprint", .preprint)]),
            ("iclr2027_conference", "ICLR 2027", [("", .submission), ("", .final)]),
            ("icml2026", "ICML 2026", [("", .submission), ("accepted", .final), ("preprint", .preprint)]),
            ("cvpr", "CVPR 2027", [("", .final), ("review", .submission), ("rebuttal", .rebuttal)]),
            ("acl", "ACL 2026", [("", .final), ("review", .submission), ("preprint", .preprint)]),
            (
                "aaai2027", "AAAI 2027",
                [("", .final), ("submission", .submission), ("draft", .draft), ("preprint", .preprint)]
            ),
        ]
        for (package, name, modes) in entries {
            for (option, mode) in modes {
                let line = #"\usepackage"# + (option.isEmpty ? "" : "[\(option)]") + "{\(package)}"
                let finalCopy = package == "iclr2027_conference" && mode == .final ? #"\iclrfinalcopy"# : ""
                #expect(
                    recognition(#"\documentclass{article}"# + line + finalCopy)
                        == .recognised(
                            name: .init(name), detail: mode, source: line))
            }
        }
    }

    @Test("引き渡したオプションは判定に使い、引用には原稿の指定だけを残す")
    func passedOptions() {
        let line = #"\RequirePackage  [nonatbib]{foo,neurips_2026}"#
        #expect(
            recognition(#"\documentclass{article}\PassOptionsToPackage{final}{neurips_2026}"# + line)
                == .recognised(name: .init("NeurIPS 2026"), detail: .final, source: line))
    }

    @Test("未知のクラスは代替とし、指定のない原稿には認識名を付けない")
    func fallback() {
        #expect(recognition(#"\documentclass{myjournal}"#) == .substituted(requestedClass: "myjournal"))
        #expect(recognition("") == nil)
    }
}
