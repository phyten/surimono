import SurimonoCore
import Testing

struct SamplePlaceTests {
    private let places = [
        SamplePlace(kind: .heading, index: 0, level: 1, title: "はじめに"),
        SamplePlace(kind: .heading, index: 1, level: 2, title: "道具"),
        SamplePlace(kind: .code, index: 0, title: "道具"),
    ]

    @Test("文書が変わらなければ、同じ箇所のまま見つかる")
    func samePlace() {
        #expect(places[1].found(in: places) == places[1])
        #expect(places[2].found(in: places) == places[2])
    }

    @Test("見出しの前に見出しが増えても、同じ言葉の箇所へ移る")
    func movedPlace() {
        let moved = SamplePlace(kind: .heading, index: 5, level: 2, title: "道具")
        #expect(moved.found(in: places) == places[1])
    }

    @Test("同じ言葉でも種類の違う箇所へは移らない")
    func kindMatters() {
        let code = SamplePlace(kind: .code, index: 3, title: "はじめに")
        #expect(code.found(in: places) == nil)
    }

    @Test("同じ言葉の箇所がなくなると見つからない")
    func gonePlace() {
        let gone = SamplePlace(kind: .heading, index: 0, level: 1, title: "おわりに")
        #expect(gone.found(in: places) == nil)
    }

    @Test("箇所の識別子は種類と位置で決まる")
    func identity() {
        #expect(places[0].id != places[1].id)
        #expect(places[0].id != SamplePlace(kind: .code, index: 0, title: "はじめに").id)
    }
}
