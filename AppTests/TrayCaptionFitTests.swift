import CoreGraphics
import Testing

@testable import Surimono

@MainActor
struct TrayCaptionFitTests {
    @Test("面の札とページの表示が並んで入る幅では、札をそのままの形で出す")
    func fullTagWhenItFits() {
        // A side of 400 with two slots: the first slot has 200, of which the tag of 30 and its gap take 34.
        let fit = TrayCaptionFit(
            sideWidth: 400, slotCount: 2, faceFull: 30, faceShort: 14, firstLabel: 45, firstIsPage: true)
        #expect(fit.face == .full)
        #expect(fit.tagSpace == 34)
    }

    @Test("長い札でページの表示が入らなければ、札を短い形にしてページの表示を残す")
    func shortTagKeepsThePageLabel() {
        // "Rückseite" (72) beside "Seite 2" (45) in a slot of 110: 110 - 76 - 4 leaves 30.
        let fit = TrayCaptionFit(
            sideWidth: 220, slotCount: 2, faceFull: 72, faceShort: 14, firstLabel: 45, firstIsPage: true)
        #expect(fit.face == .short)
        #expect(fit.tagSpace == 18)
    }

    @Test("短い札でもページの表示が入らない狭さでは、札を外してページの表示を残す")
    func pageLabelWinsOverTheTag() {
        let fit = TrayCaptionFit(
            sideWidth: 60, slotCount: 2, faceFull: 72, faceShort: 14, firstLabel: 45, firstIsPage: true)
        #expect(fit.face == .hidden)
        #expect(fit.tagSpace == 0)
    }

    @Test("白紙の説明は札を短くしても入らなければ末尾を省略し、札は短い形で残す")
    func blankNoteGivesWay() {
        // "Leer (Rückseite)" (90) after the short tag in a slot of 110: 110 - 18 - 4 leaves 88.
        let fit = TrayCaptionFit(
            sideWidth: 220, slotCount: 2, faceFull: 72, faceShort: 14, firstLabel: 90, firstIsPage: false)
        #expect(fit.face == .short)
    }

    @Test("短い札を置くと白紙の説明に場所が残らない狭さでは、札を外して説明に場所を渡す")
    func blankNoteNeedsRoomBesideTheShortTag() {
        // A rotated back at the smallest zoom: a side of 42.4 with one slot, and the short tag "Back 180°" of 46.
        let rotated = TrayCaptionFit(
            sideWidth: 42.4, slotCount: 1, faceFull: 96, faceShort: 46, firstLabel: 90, firstIsPage: false)
        #expect(rotated.face == .hidden)
        #expect(rotated.tagSpace == 0)
        // The short tag of 14 and its gap take 18, the padding 4: a slot of 46 leaves exactly the least a note needs.
        let enough = TrayCaptionFit(
            sideWidth: 46, slotCount: 1, faceFull: 72, faceShort: 14, firstLabel: 90, firstIsPage: false)
        #expect(enough.face == .short)
        let tooLittle = TrayCaptionFit(
            sideWidth: 45, slotCount: 1, faceFull: 72, faceShort: 14, firstLabel: 90, firstIsPage: false)
        #expect(tooLittle.face == .hidden)
    }

    @Test("どの幅でも、札を置いた白紙の説明には決めた最低の幅が残る")
    func noteKeepsItsMinimum() {
        for width in stride(from: 20, through: 600, by: 1) {
            let fit = TrayCaptionFit(
                sideWidth: CGFloat(width), slotCount: 2, faceFull: 72, faceShort: 46, firstLabel: 90,
                firstIsPage: false)
            let slot = CGFloat(width) / 2
            if fit.face != .hidden {
                #expect(slot - fit.tagSpace - TrayCaptionFit.padding >= TrayCaptionFit.noteMinimum, "\(width)")
            }
        }
    }

    @Test("上下に並ぶ枠の説明は中央に置くので、札の分を両側に空けて入るかを決める")
    func centeredCaption() {
        // 200 - 2 × 34 = 132 for a caption of 120, but 200 - 2 × 76 = 48 with the long tag.
        let short = TrayCaptionFit(
            sideWidth: 200, slotCount: 1, faceFull: 72, faceShort: 30, firstLabel: 120, firstIsPage: true,
            centered: true)
        #expect(short.face == .short)
        let full = TrayCaptionFit(
            sideWidth: 400, slotCount: 1, faceFull: 72, faceShort: 30, firstLabel: 120, firstIsPage: true,
            centered: true)
        #expect(full.face == .full)
    }

    @Test("札のない片面の用紙では、ページの表示だけを置く")
    func noTag() {
        let fit = TrayCaptionFit(
            sideWidth: 100, slotCount: 2, faceFull: nil, faceShort: nil, firstLabel: 45, firstIsPage: true)
        #expect(fit.face == .full)
        #expect(fit.tagSpace == 0)
    }

    @Test("どの幅でも、札と最初のページの表示は重ならない")
    func neverOverlaps() {
        for width in stride(from: 40, through: 600, by: 2) {
            let fit = TrayCaptionFit(
                sideWidth: CGFloat(width), slotCount: 2, faceFull: 72, faceShort: 14, firstLabel: 45,
                firstIsPage: true)
            let slot = CGFloat(width) / 2
            if fit.face != .hidden {
                #expect(fit.tagSpace + 45 + TrayCaptionFit.padding <= slot, "\(width)")
            }
        }
    }
}
