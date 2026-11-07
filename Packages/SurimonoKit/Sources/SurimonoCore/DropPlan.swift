import Foundation

/// What a window does with files brought to it, whether dropped or chosen with Add Documents…. The words shown during
/// a drag and the action taken both come from this plan, so that a window does what it said it would.
public struct DropPlan: Equatable, Sendable {
    public enum Receiver: Equatable, Sendable {
        /// A file's own window, which can grow into a binder.
        case document(URL)
        case binder([URL])
        case imageBundle([URL])
        /// A window that only passes files on: a document in memory, the images of a ZIP, the comparison stage.
        case closed(own: URL?)
    }

    /// How the files come to stay in this window.
    public enum Joining: Equatable, Sendable {
        case binder
        case images
        /// The window's contents and the files make a new binder, which takes the window's place.
        case newBinder
    }

    public enum Refusal: Equatable, Sendable {
        case isThisDocument
        case alreadyIn
        case unsupported
    }

    public enum Choice: Equatable, Sendable {
        /// Where the files are dropped decides.
        case joinOrOpen(Joining)
        case join(Joining)
        case open
        case refuse(Refusal)
    }

    public let choice: Choice
    /// What would join this window, in name order among themselves.
    public let adding: [URL]
    /// What this window holds already.
    public let alreadyIn: [URL]
    /// What cannot join a window: ZIP archives, folders and unsupported files.
    public let leftOut: [URL]
    /// The files that are not in this window, which is what a new window would open.
    public let others: [URL]
    /// What opening `others` does.
    public let opening: OpenRequest

    public init(urls: [URL], receiver: Receiver) {
        var seen = Set<URL>()
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        let own = Set(receiver.ownURLs.map(\.standardizedFileURL))
        others = files.filter { !own.contains($0) }
        alreadyIn = files.filter(own.contains)
        let joinable = receiver.canHoldFiles ? others.filter { OpenRequest.binderFormat($0) != nil } : []
        adding = OpenRequest.sorted(joinable)
        leftOut = receiver.canHoldFiles ? OpenRequest.sorted(others.filter { OpenRequest.binderFormat($0) == nil }) : []
        opening = Self.opening(others)
        let joining = receiver.joining(adding)
        switch (joining, opening) {
        case (let joining?, _):
            if case .document = receiver {
                choice = .joinOrOpen(joining)
            } else {
                choice = .join(joining)
            }
        case (nil, .empty):
            choice = files.isEmpty ? .refuse(.unsupported) : .refuse(receiver.refusalOfOwnFiles)
        case (nil, .unsupported): choice = .refuse(.unsupported)
        case (nil, _): choice = .open
        }
    }

    private static func opening(_ urls: [URL]) -> OpenRequest {
        let request = OpenRequest(urls: urls)
        // One file goes to the document controller whatever it is, which only answers a folder with an error.
        if case .single(let url) = request, OpenRequest.binderFormat(url) == nil,
            !OpenRequest.isArchive(url)
        {
            return .unsupported
        }
        return request
    }
}

extension DropPlan.Receiver {
    fileprivate var ownURLs: [URL] {
        switch self {
        case .document(let url): [url]
        case .binder(let urls), .imageBundle(let urls): urls
        case .closed(let own): [own].compactMap { $0 }
        }
    }

    fileprivate var canHoldFiles: Bool {
        if case .closed = self { return false }
        return true
    }

    fileprivate func joining(_ adding: [URL]) -> DropPlan.Joining? {
        guard !adding.isEmpty else { return nil }
        switch self {
        case .document: return .newBinder
        case .binder: return .binder
        case .imageBundle:
            return adding.allSatisfy { OpenRequest.binderFormat($0) == .image } ? .images : .newBinder
        case .closed: return nil
        }
    }

    fileprivate var refusalOfOwnFiles: DropPlan.Refusal {
        switch self {
        case .document, .closed: .isThisDocument
        case .binder, .imageBundle: .alreadyIn
        }
    }
}
