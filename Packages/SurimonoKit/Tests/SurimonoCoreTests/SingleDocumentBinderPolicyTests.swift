import SurimonoCore
import Testing

struct SingleDocumentBinderPolicyTests {
    @Test("合本が一文書になったときは既定で確認し選択肢は三つだけ")
    func defaults() {
        #expect(SingleDocumentBinderPolicy.defaultValue == .ask)
        #expect(SingleDocumentBinderPolicy.allCases == [.ask, .leave, .stay])
    }

    @Test("次回から確認しない場合だけ今回の回答を方針にする", arguments: [false, true], [false, true])
    func suppression(leaving: Bool, suppressing: Bool) {
        let actual = SingleDocumentBinderPolicy.answer(leaving: leaving, suppressing: suppressing)
        if !suppressing {
            #expect(actual == .ask)
        } else if leaving {
            #expect(actual == .leave)
        } else {
            #expect(actual == .stay)
        }
    }
}
