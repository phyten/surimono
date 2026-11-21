import Testing

@testable import SurimonoFormats

struct BeamerOverlayTests {
    @Test("範囲とモードを配布用と発表用で別々に選ぶ")
    func specifications() throws {
        for (source, handout, expected) in [
            ("2-", false, [2, 3, 4]), ("-3", false, [1, 2, 3]), ("1,3", false, [1, 3]),
            ("1-2,4-", false, [1, 2, 4]), ("handout:0", true, []), ("handout:0", false, [1, 2, 3, 4]),
            ("beamer|handout:2", false, [1, 2, 3, 4]), ("beamer|handout:2", true, [2]),
            ("handout", false, []), ("2", true, [1, 2, 3, 4]), ("presentation", true, [1, 2, 3, 4]),
        ] {
            var pause = 1
            let spec = try #require(BeamerOverlaySpecification.decode(source, handout: handout, pause: &pause))
            #expect((1...4).filter { spec.contains($0) } == expected)
        }
    }

    @Test("相対指定は一指定に一度だけ進み直前の段階を参照できる")
    func relativeSteps() throws {
        var pause = 1
        for (source, first, next) in [("+-+", 1, 2), (".-", 1, 2), ("+(-1)-", 1, 3), (".(+2)-", 4, 3)] {
            let spec = try #require(BeamerOverlaySpecification.decode(source, handout: false, pause: &pause))
            #expect(spec.intervals.first?.first == first)
            #expect(pause == next)
        }
    }

    @Test("追加だけなら最後の段階にまとめ、入れ替えでは途中の紙を残す")
    func pages() {
        let add = BeamerOverlay.evaluate(#"A\pause B\uncover<3->{C}"#, handout: false)
        #expect(add.pages == ["A BC"])
        let swap = BeamerOverlay.evaluate(#"\only<1>{赤}\only<2>{青}\uncover<2->{灯}\alt<2>{東}{西}"#, handout: false)
        #expect(swap.pages == [#"赤\surimonocovered{灯}西"#, "青灯東"])
        let temporal = BeamerOverlay.evaluate(#"\temporal<2>{前}{今}{後}\only<3>{灯}"#, handout: false)
        #expect(temporal.pages == ["前", "今", "後灯"])
    }

    @Test("休止と入れ子の相対項目、動く強調を左右の段階で共有する")
    func nestedPauses() {
        let relative = BeamerOverlay.evaluate(
            #"\begin{itemize}[<+->]\item A\item B\end{itemize}\only<.>{C}"#, handout: false)
        #expect(relative.pages.count == 2)
        #expect(relative.pages.first?.contains(#"\item\surimonocovereditem{} B"#) == true)
        #expect(relative.pages.last?.hasSuffix("C") == true)
        let paused = BeamerOverlay.evaluate(#"A\pause B\only<2>{\alert<2>{C}}\pause[4]D"#, handout: false)
        #expect(paused.pages.count == 4)
        #expect(paused.pages[1] == #"A B\alert{C}\surimonocovered{D}"#)
        #expect(paused.pages.last == "A BD")
    }

    @Test("配布用では非表示指定とモードを守り正の段階を一枚に載せる")
    func handout() {
        let frame = #"\only<1>{A}\only<2>{B}\only<handout:0>{C}\mode<handout>{D}\only<beamer|handout:2>{E}"#
        #expect(BeamerOverlay.evaluate(frame, handout: true).pages == ["ABDE"])
        #expect(BeamerOverlay.evaluate(frame, handout: false).pages == ["ACE", "BCE"])
    }

    @Test("段階を解釈できなければ全内容を一度だけ残す")
    func fallback() {
        for frame in [
            #"\only<1>{A}\alt<unknown>{B}{C}"#, #"\only<1>{A}\alt<2x>{B}{C}"#,
            #"\only<1>{A}\alt<999999999999999999999999999999>{B}{C}"#,
        ] {
            let result = BeamerOverlay.evaluate(frame, handout: false)
            #expect(result.hasUnreadableSpecification)
            #expect(result.pages == ["AB C"])
        }
    }

    @Test("大きすぎる休止番号は後続の相対指定を壊さず全内容を残す")
    func largePause() {
        let frame = "A\\pause[\(Int.max)]B\\pause C\\only<+>{D}"
        let result = BeamerOverlay.evaluate(frame, handout: false)
        #expect(result.hasUnreadableSpecification)
        #expect(result.pages == ["AB CD"])
    }

    @Test("フレームの指定は紙そのものを選び、配布用から除外されたフレームは空頁を作らない")
    func selectedFrames() {
        let frame = #"\alt<1>{初}{次}"#
        #expect(BeamerOverlay.evaluate(frame, handout: true, frameSpecification: "handout:0").pages.isEmpty)
        #expect(BeamerOverlay.evaluate(frame, handout: false, frameSpecification: "2").pages == ["次"])
        #expect(BeamerOverlay.evaluate(frame, handout: false, frameSpecification: "handout").pages.isEmpty)
    }

    @Test("モード宣言で飛ばした休止は数えず、上書き環境は同じ位置に二つの状態を置く")
    func modeAndOverprint() {
        let mode = #"""
            A
            \mode<article>
            \pause[9]X
            \mode<all>
            B
            """#
        #expect(BeamerOverlay.evaluate(mode, handout: false).pages.map { $0.filter { !$0.isWhitespace } } == ["AB"])
        let overprint = #"\begin{overprint}\onslide<1>東\onslide<2>西\end{overprint}"#
        let pages = BeamerOverlay.evaluate(overprint, handout: false).pages
        #expect(pages.count == 2)
        #expect(pages[0].contains(#"\begin{surimonooverprintpart}東"#))
        #expect(pages[0].contains(#"\begin{surimonooverprintcovered}西"#))
        #expect(pages[1].contains(#"\begin{surimonooverprintpart}西"#))
    }

    @Test("逐語環境・インラインコード・コメント内の段階指定は数えない")
    func verbatim() {
        let frame = #"""
            \begin{verbatim}
            \only<5>{例}
            \end{verbatim}
            \verb|\pause| % \uncover<3>{x}
            """#
        let result = BeamerOverlay.evaluate(frame, handout: false)
        #expect(result.pages == [frame])
        #expect(!result.hasUnreadableSpecification)
    }
}
