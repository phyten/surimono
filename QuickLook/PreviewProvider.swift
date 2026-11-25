import QuickLookUI
import SurimonoCore
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(
        for request: QLFilePreviewRequest, completionHandler handler: @escaping (QLPreviewReply?, (any Error)?) -> Void
    ) {
        let url = request.fileURL
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 760, height: 820)) { reply in
            let preview = FinderPreview.make(for: url, bundle: Bundle(for: PreviewProvider.self))
            reply.attachments = preview.attachments.mapValues {
                QLPreviewReplyAttachment(data: $0.data, contentType: $0.type)
            }
            reply.stringEncoding = .utf8
            return Data(preview.html.utf8)
        }
        handler(reply, nil)
    }
}
