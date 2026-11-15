import SurimonoCore

enum PrintIntent: Equatable {
    case quick, systemDialog, manualDuplex
}

enum PrintRoute: Equatable {
    case direct(PrintRequest)
    case systemDialog(PrintRequest)
    case manualDuplex(PrintRequest)

    var request: PrintRequest {
        switch self {
        case .direct(let request), .systemDialog(let request), .manualDuplex(let request): request
        }
    }

    static func resolve(intent: PrintIntent, request: PrintRequest, layout: PrintLayout, issue: PrinterIssue?)
        -> PrintRoute
    {
        var request = request
        if intent == .systemDialog || request.showsPanel || request.printerName == nil
            || (issue != nil && issue != .duplexNotAvailable)
        {
            request.showsPanel = true
            return .systemDialog(request)
        }
        if layout.sentDuplex != .none && (intent == .manualDuplex || issue == .duplexNotAvailable) {
            return .manualDuplex(request)
        }
        return .direct(request)
    }
}
