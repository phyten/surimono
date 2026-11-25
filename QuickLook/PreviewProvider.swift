import Darwin
import QuickLookUI
import SurimonoCore
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(
        for request: QLFilePreviewRequest, completionHandler handler: @escaping (QLPreviewReply?, (any Error)?) -> Void
    ) {
        let url = request.fileURL
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 760, height: 820)) { reply in
            FinderPreview.replyData(
                for: url, bundle: Bundle(for: PreviewProvider.self),
                terminateIfStalled: {
                    // Only the extension exits. An uninterruptible converter would otherwise keep running after the
                    // timeout reply. Quick Look can launch a fresh provider for the next request.
                    Darwin._exit(EXIT_SUCCESS)
                }
            ) { preview in
                reply.attachments = preview.attachments.mapValues {
                    QLPreviewReplyAttachment(data: $0.data, contentType: $0.type)
                }
                reply.stringEncoding = .utf8
                return Data(preview.html.utf8)
            }
        }
        handler(reply, nil)
    }
}
