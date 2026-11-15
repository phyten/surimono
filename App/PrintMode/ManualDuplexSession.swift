import Foundation
import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering

@MainActor
@Observable
final class ManualDuplexSession: Identifiable {
    /// `closingSheet` sits between the prepared backs and their submission: the reload sheet has been asked to go,
    /// and the backs wait until it has really left the window.
    enum Phase { case preparing, sendingFronts, awaitingReload, preparingBacks, closingSheet, sendingBacks }

    let id = UUID()
    let printerName: String
    let binding: DuplexMode
    let frontPageOrder: PrintPageOrder
    let copies: Int
    let jobTitle: String
    let language: String
    let imposition: ImpositionPlan
    let layout: PrintLayout
    @ObservationIgnored var saveCorrection: ((ManualDuplexCorrection) -> Void)?
    @ObservationIgnored var submitOverride:
        ((ManualDuplexSubmission, @escaping (ManualDuplexSubmissionResult) -> Void) -> Void)?
    private(set) var submissionID = UUID()
    private(set) var phase = Phase.preparing
    var correction: ManualDuplexCorrection
    var error: String?
    private(set) var plan: ManualDuplexPlan?
    private(set) var neutral: PDFDocument?
    private(set) var fronts: PDFDocument?
    private(set) var backs: PDFDocument?

    var sheetCount: Int { plan?.sheetCount ?? 0 }
    /// The one place that decides whether the reload sheet is up. It goes away before the backs are sent, and the
    /// submission waits until it has detached: the print operation must run on the bare window like any print, since
    /// a print sheet queued behind ours would never start and its completion would never come.
    var showsReload: Bool { phase == .awaitingReload || phase == .preparingBacks }

    init(
        printerName: String, layout: PrintLayout, imposition: ImpositionPlan, copies: Int,
        pageOrder: PrintPageOrder, jobTitle: String, language: String, correction: ManualDuplexCorrection
    ) {
        self.printerName = printerName
        binding = layout.sentDuplex
        self.layout = layout
        self.imposition = imposition
        self.copies = copies
        frontPageOrder = pageOrder
        self.jobTitle = jobTitle
        self.language = language
        self.correction = correction
    }

    func prepare(from document: PDFDocument) async throws {
        guard let data = document.dataRepresentation(), let frozen = PDFDocument(data: data),
            frozen.pageCount == imposition.sides.count
        else { throw ManualDuplexRenderer.PreparationError.invalidDocument }
        let plan = try makePlan()
        let renderer = ManualDuplexRenderer()
        let fronts = try await renderer.document(from: frozen, sides: plan.fronts)
        let backs = try await renderer.document(from: frozen, sides: plan.backs)
        guard fronts.pageCount == plan.sheetCount, backs.pageCount == plan.sheetCount else {
            throw ManualDuplexRenderer.PreparationError.invalidDocument
        }
        self.plan = plan
        neutral = frozen
        self.fronts = fronts
        self.backs = backs
    }

    func makePlan() throws -> ManualDuplexPlan {
        try ManualDuplexPlan.make(
            imposition: imposition, copies: copies, frontPageOrder: frontPageOrder, correction: correction)
    }

    func transition(from expected: Phase, to next: Phase) -> Bool {
        guard phase == expected else { return false }
        phase = next
        return true
    }

    func prepareBacks(correction: ManualDuplexCorrection) async throws {
        guard let neutral else { throw ManualDuplexRenderer.PreparationError.invalidDocument }
        let plan = try ManualDuplexPlan.make(
            imposition: imposition, copies: copies, frontPageOrder: frontPageOrder, correction: correction)
        let document = try await ManualDuplexRenderer().document(from: neutral, sides: plan.backs)
        guard document.pageCount == plan.sheetCount else { throw ManualDuplexRenderer.PreparationError.invalidDocument }
        self.plan = plan
        backs = document
    }

    func beginSubmission() -> UUID {
        submissionID = UUID()
        return submissionID
    }

    func submission(for pass: ManualDuplexPass) throws -> ManualDuplexSubmission {
        guard let document = pass == .fronts ? fronts : backs else {
            throw ManualDuplexRenderer.PreparationError.invalidDocument
        }
        return ManualDuplexSubmission(
            sessionID: id, pass: pass, document: document,
            layout: try ManualDuplexRenderer().transportLayout(for: layout),
            request: PrintRequest(printerName: printerName, showsPanel: false, copies: 1),
            pageOrder: pass == .fronts ? frontPageOrder : .firstSheetFirst,
            jobTitle: PrintModeText.format(pass == .fronts ? "%@ (Fronts)" : "%@ (Backs)", language: language, jobTitle)
        )
    }
}

enum ManualDuplexPass { case fronts, backs }

struct ManualDuplexSubmission {
    let sessionID: UUID
    let pass: ManualDuplexPass
    let document: PDFDocument
    let layout: PrintLayout
    let request: PrintRequest
    let pageOrder: PrintPageOrder
    let jobTitle: String
}

enum ManualDuplexSubmissionResult {
    case handedOff(printerName: String)
    case notStarted
    case cancelledOrFailed
}
