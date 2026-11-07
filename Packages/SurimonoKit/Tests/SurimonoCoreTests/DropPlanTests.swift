import Foundation
import SurimonoCore
import Testing

struct DropPlanTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/" + name) }
    private var document: DropPlan.Receiver { .document(url("own.md")) }
    private var binder: DropPlan.Receiver { .binder([url("own.md"), url("other.pdf")]) }
    private var bundle: DropPlan.Receiver { .imageBundle([url("1.jpg"), url("2.jpg")]) }

    @Test("単独の文書に別の文書を落とすと合本にするか新しい窓で開くかを選べる")
    func documentOffersBoth() {
        let plan = DropPlan(urls: [url("a.pdf")], receiver: document)
        #expect(plan.choice == .joinOrOpen(.newBinder))
        #expect(plan.adding == [url("a.pdf")])
        #expect(plan.opening == .single(url("a.pdf")))
    }

    @Test("単独の文書に複数を落とすと足す物だけ自然順に並び、開くと今の振り分けになる")
    func documentSortsWhatIsAdded() {
        let plan = DropPlan(urls: [url("10.md"), url("2.md")], receiver: document)
        #expect(plan.adding == [url("2.md"), url("10.md")])
        #expect(plan.opening == .binder([url("2.md"), url("10.md")], excluded: []))
    }

    @Test("窓の文書そのものだけを落としても何もしない")
    func ownDocument() {
        #expect(DropPlan(urls: [url("own.md")], receiver: document).choice == .refuse(.isThisDocument))
    }

    @Test("窓の文書とほかの文書を落とすと窓の文書を除いて判断する")
    func ownDocumentAmongOthers() {
        let plan = DropPlan(urls: [url("own.md"), url("a.pdf")], receiver: document)
        #expect(plan.choice == .joinOrOpen(.newBinder))
        #expect(plan.adding == [url("a.pdf")])
        #expect(plan.alreadyIn == [url("own.md")])
        #expect(plan.opening == .single(url("a.pdf")))
    }

    @Test("単独の文書に ZIP 1 つを落とすと新しい窓で開くだけになる")
    func archiveOpensOnly() {
        let plan = DropPlan(urls: [url("a.zip")], receiver: document)
        #expect(plan.choice == .open)
        #expect(plan.adding.isEmpty)
        #expect(plan.opening == .single(url("a.zip")))
    }

    @Test("フォルダーや ZIP とフォルダーだけでは受け付けない")
    func foldersAreRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(DropPlan(urls: [folder], receiver: document).choice == .refuse(.unsupported))
        #expect(DropPlan(urls: [folder, url("a.zip")], receiver: document).choice == .refuse(.unsupported))
    }

    @Test("読めない形式 1 つも受け付けない")
    func unknownIsRefused() {
        #expect(DropPlan(urls: [url("a.unknown")], receiver: document).choice == .refuse(.unsupported))
    }

    @Test("足せない物が混ざっていても足せる物があれば足し、足せない物を別に持つ")
    func mixed() {
        let plan = DropPlan(urls: [url("a.md"), url("b.zip")], receiver: binder)
        #expect(plan.choice == .join(.binder))
        #expect(plan.adding == [url("a.md")])
        #expect(plan.leftOut == [url("b.zip")])
    }

    @Test("合本には窓全体で足し、すでに入っている物は足さない")
    func binderJoins() {
        let plan = DropPlan(urls: [url("other.pdf"), url("a.md")], receiver: binder)
        #expect(plan.choice == .join(.binder))
        #expect(plan.adding == [url("a.md")])
        #expect(plan.alreadyIn == [url("other.pdf")])
    }

    @Test("合本に入っている物だけなら足さず、その行を知らせる")
    func binderRefusesWhatItHolds() {
        let plan = DropPlan(urls: [url("own.md"), url("other.pdf")], receiver: binder)
        #expect(plan.choice == .refuse(.alreadyIn))
        #expect(plan.alreadyIn == [url("own.md"), url("other.pdf")])
    }

    @Test("同じ名前でも別の場所のファイルは別物として足す")
    func sameNameElsewhere() {
        let elsewhere = URL(fileURLWithPath: "/elsewhere/own.md")
        #expect(DropPlan(urls: [elsewhere], receiver: binder).adding == [elsewhere])
    }

    @Test("合本に ZIP だけを落とすと足せないので新しい窓で開く")
    func binderOpensArchive() {
        #expect(DropPlan(urls: [url("a.zip")], receiver: binder).choice == .open)
    }

    @Test("画像の束に画像を足す")
    func bundleJoinsImages() {
        let plan = DropPlan(urls: [url("3.jpg"), url("1.jpg")], receiver: bundle)
        #expect(plan.choice == .join(.images))
        #expect(plan.adding == [url("3.jpg")])
        #expect(plan.alreadyIn == [url("1.jpg")])
    }

    @Test("画像の束に文書が混ざると合本に変えて足す")
    func bundleTurnsIntoBinder() {
        let plan = DropPlan(urls: [url("3.jpg"), url("a.md")], receiver: bundle)
        #expect(plan.choice == .join(.newBinder))
        #expect(plan.adding == [url("3.jpg"), url("a.md")])
    }

    @Test("閉じた窓は足さず、何でも新しい窓で開く")
    func closedOnlyOpens() {
        let plan = DropPlan(urls: [url("a.md"), url("b.pdf")], receiver: .closed(own: nil))
        #expect(plan.choice == .open)
        #expect(plan.adding.isEmpty)
        #expect(plan.opening == .binder([url("a.md"), url("b.pdf")], excluded: []))
    }

    @Test("閉じた窓に自分の文書を落としても何もしない")
    func closedOwnDocument() {
        #expect(DropPlan(urls: [url("a.zip")], receiver: .closed(own: url("a.zip"))).choice == .refuse(.isThisDocument))
    }

    @Test("ファイルでない URL は受け付けない")
    func webAddresses() {
        let web = URL(string: "https://example.com/a.pdf")!
        #expect(DropPlan(urls: [web], receiver: document).choice == .refuse(.unsupported))
    }
}
