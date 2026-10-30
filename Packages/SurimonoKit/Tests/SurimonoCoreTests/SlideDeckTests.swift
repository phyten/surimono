import CoreGraphics
import Foundation
import SurimonoCore
import Testing

struct SlideDeckTests {
    /// Slides stacked in one place, of which only `shown` is in view, as a deck that shows one slide at a time.
    private func oneAtATime(
        count: Int, width: Double, height: Double, shown: Int = 0, fixed: Bool = true, scale: Double = 1
    ) -> SlideFacts.Group {
        SlideFacts.Group(
            members: (0..<count).map { index in
                SlideFacts.Member(
                    width: width, height: height, fixed: fixed, visible: index == shown ? 1 : 0,
                    boxWidth: width * scale, boxHeight: height * scale)
            })
    }

    private func facts(_ groups: SlideFacts.Group...) -> SlideFacts {
        SlideFacts(viewportWidth: 1280, viewportHeight: 720, groups: groups)
    }

    @Test("1280×720 の固定の区画が 6 枚あり 1 枚ずつ見せる文書はスライドで、見えている 3 枚目が今のスライド")
    func sixWideSlides() {
        let deck = SlideDeck.detect(facts(oneAtATime(count: 6, width: 1280, height: 720, shown: 2)))
        #expect(deck == SlideDeck(size: CGSize(width: 1280, height: 720), count: 6, currentIndex: 2))
    }

    @Test("4:3 の 1024×768 の区画が 4 枚あればスライド")
    func fourByThree() {
        let deck = SlideDeck.detect(facts(oneAtATime(count: 4, width: 1024, height: 768)))
        #expect(deck?.size == CGSize(width: 1024, height: 768))
        #expect(deck?.count == 4)
    }

    @Test("縦に並べて全部見せる固定の区画もスライドで、いちばん見えている物が今のスライド")
    func stackedSlides() {
        let members = (0..<3).map { index in
            SlideFacts.Member(
                width: 960, height: 540, visible: index == 1 ? 0.8 : index == 0 ? 0.2 : 0, y: Double(index) * 560)
        }
        #expect(SlideDeck.detect(facts(SlideFacts.Group(members: members)))?.currentIndex == 1)
    }

    @Test("区画が自分で transform: scale で窓に合わせていれば、そう知らせる")
    func scalesItself() {
        let deck = SlideDeck.detect(facts(oneAtATime(count: 6, width: 1280, height: 720, scale: 0.75)))
        #expect(deck?.scalesItself == true)
        #expect(deck?.size == CGSize(width: 1280, height: 720))
    }

    @Test("窓の幅で流れる記事の区画は、たくさんあってもスライドではない")
    func fluidArticle() {
        let sections = SlideFacts.Group(
            members: (0..<8).map { index in
                SlideFacts.Member(width: 1280, height: 720, fixed: false, visible: index < 2 ? 0.5 : 0)
            })
        #expect(SlideDeck.detect(facts(sections)) == nil)
    }

    @Test("16:9 の大きな画像が 1 枚だけの文書はスライドではない")
    func singleHero() {
        #expect(SlideDeck.detect(facts(oneAtATime(count: 1, width: 1280, height: 720))) == nil)
        #expect(SlideDeck.detect(facts()) == nil)
    }

    @Test("大きさのそろわない区画はスライドではない")
    func mixedSizes() {
        let group = SlideFacts.Group(members: [
            SlideFacts.Member(width: 1280, height: 720, visible: 1), SlideFacts.Member(width: 1280, height: 900),
            SlideFacts.Member(width: 1280, height: 720),
        ])
        #expect(SlideDeck.detect(facts(group)) == nil)
    }

    @Test("画面の形でない区画と、小さなサムネイルはスライドではない")
    func notScreenShaped() {
        #expect(SlideDeck.detect(facts(oneAtATime(count: 6, width: 800, height: 800))) == nil)
        #expect(SlideDeck.detect(facts(oneAtATime(count: 6, width: 320, height: 180))) == nil)
    }

    @Test("横に並んで同時に見える 16:9 の区画は一覧であってスライドではない")
    func gallery() {
        let group = SlideFacts.Group(members: [
            SlideFacts.Member(width: 480, height: 270, visible: 1, x: 0),
            SlideFacts.Member(width: 480, height: 270, visible: 1, x: 500),
        ])
        #expect(SlideDeck.detect(facts(group)) == nil)
    }

    @Test("一覧の 2 枚目が画面の外にはみ出していても、一覧はスライドではない")
    func galleryPartlyOffScreen() {
        let group = SlideFacts.Group(members: [
            SlideFacts.Member(width: 480, height: 270, visible: 1, x: 800),
            SlideFacts.Member(width: 480, height: 270, visible: 0.1, x: 1300),
        ])
        #expect(SlideDeck.detect(facts(group)) == nil)
    }

    @Test("画面より下にある一覧も、見えていなくてもスライドではない")
    func galleryBelowTheFold() {
        let members = (0..<3).map { (index: Int) -> SlideFacts.Member in
            SlideFacts.Member(width: 480, height: 270, visible: 0, x: Double(index) * 500, y: 2000)
        }
        let group = SlideFacts.Group(members: members)
        #expect(SlideDeck.detect(facts(group)) == nil)
    }

    @Test("横に並べて枠で 1 枚だけを見せる送り方はスライドで、枠の外の物は数えない")
    func carousel() {
        let members = (0..<4).map { (index: Int) -> SlideFacts.Member in
            let share: Double = index == 1 ? 1 : 0
            return SlideFacts.Member(
                width: 1280, height: 720, visible: share, x: Double(index - 1) * 1280, unclipped: share)
        }
        let group = SlideFacts.Group(members: members)
        #expect(SlideDeck.detect(facts(group))?.currentIndex == 1)
    }

    @Test("スクリプトの結果の JSON から判定し、読めない JSON はスライドではない")
    func fromJSON() {
        let json = """
            {"viewportWidth":1280,"viewportHeight":720,"groups":[{"members":[
            {"width":1280,"height":720,"fixed":true,"visible":0,"x":0,"y":0,"boxWidth":0,"boxHeight":0},
            {"width":1280,"height":720,"fixed":true,"visible":1,"x":0,"y":0,"boxWidth":1280,"boxHeight":720}]}]}
            """
        #expect(SlideDeck.detect(fromJSON: json)?.currentIndex == 1)
        #expect(SlideDeck.detect(fromJSON: "nope") == nil)
    }
}
