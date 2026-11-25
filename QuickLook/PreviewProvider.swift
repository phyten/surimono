import Darwin
import ImageIO
import QuickLookUI
import SurimonoCore
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    // Before per-source restrictions, ImageIO accepts its process-wide list only on the first call.
    // Initialize it once in this extension process, before any provider starts opening images.
    private static let decoderStatus: OSStatus = {
        if #unavailable(macOS 27) {
            return CGImageSourceSetAllowableTypes(FinderPreview.rasterTypeIdentifiers as CFArray)
        }
        return noErr
    }()

    override init() {
        _ = Self.decoderStatus
        super.init()
    }

    func providePreview(
        for request: QLFilePreviewRequest, completionHandler handler: @escaping (QLPreviewReply?, (any Error)?) -> Void
    ) {
        let url = request.fileURL
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 760, height: 820)) { reply in
            FinderPreview.replyData(
                for: url, bundle: Bundle(for: PreviewProvider.self),
                allowsImages: PreviewProvider.decoderStatus == noErr,
                terminateIfStalled: {
                    // Only the extension exits. An uninterruptible converter would otherwise keep running after the
                    // timeout reply. If exit wins the race, Quick Look may miss that reply; this is accepted.
                    // Quick Look can launch a fresh provider for the next request.
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
