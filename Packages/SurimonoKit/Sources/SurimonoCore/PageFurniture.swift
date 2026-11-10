import Foundation

/// The header and footer added to each page when it is printed: three places above and three below the text, written
/// with the variables of `Variable`.
public struct PageFurniture: Codable, Hashable, Sendable {
    public enum Slot: String, CaseIterable, Sendable {
        case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
    }

    public enum Preset: String, CaseIterable, Sendable {
        case none, number, name, nameAndDate, custom
    }

    public enum Variable: String, CaseIterable, Sendable {
        case fileName = "{ファイル名}"
        case title = "{題名}"
        case date = "{日付}"
        case page = "{ページ}"
        case pageCount = "{総ページ}"
    }

    public var topLeft = ""
    public var topCenter = ""
    public var topRight = ""
    public var bottomLeft = ""
    public var bottomCenter = ""
    public var bottomRight = ""
    /// Written with `YYYY`, `MM`, `DD`, `M`, `D` and `曜`; see `dateText(_:language:)`.
    public var dateFormat = Self.defaultDateFormat
    public var skipsFirstPage = false
    /// On facing pages, the even pages put the left text on the right and the right text on the left.
    public var swapsOnSpreads = false

    public static let defaultDateFormat = "YYYY年M月D日"

    public init() {}

    public static let pageNumber = preset(.number)
    public static let name = preset(.name)
    public static let nameAndDate = preset(.nameAndDate)

    public static func preset(_ preset: Preset) -> PageFurniture {
        var furniture = PageFurniture()
        furniture.apply(preset)
        return furniture
    }

    /// Replaces the six places with those of a preset; `custom` keeps them for writing by hand. The date format and
    /// the switches stay as they were.
    public mutating func apply(_ preset: Preset) {
        let count = "\(Variable.page.rawValue) / \(Variable.pageCount.rawValue)"
        let places: [String]
        switch preset {
        case .none: places = ["", "", "", "", "", ""]
        case .number: places = ["", "", "", "", Variable.page.rawValue, ""]
        case .name: places = [Variable.fileName.rawValue, "", "", "", count, ""]
        case .nameAndDate: places = [Variable.fileName.rawValue, "", Variable.date.rawValue, "", count, ""]
        case .custom: return
        }
        for (slot, text) in zip(Slot.allCases, places) { self[slot] = text }
    }

    /// The preset the six places match, or `custom`.
    public var preset: Preset {
        let places = Slot.allCases.map { self[$0] }
        return [Preset.none, .number, .name, .nameAndDate].first { preset in
            Self.preset(preset).isSamePlaces(as: places)
        } ?? .custom
    }

    private func isSamePlaces(as places: [String]) -> Bool { Slot.allCases.map { self[$0] } == places }

    public var isEmpty: Bool { Slot.allCases.allSatisfy { self[$0].isEmpty } }

    public subscript(slot: Slot) -> String {
        get {
            switch slot {
            case .topLeft: topLeft
            case .topCenter: topCenter
            case .topRight: topRight
            case .bottomLeft: bottomLeft
            case .bottomCenter: bottomCenter
            case .bottomRight: bottomRight
            }
        }
        set {
            switch slot {
            case .topLeft: topLeft = newValue
            case .topCenter: topCenter = newValue
            case .topRight: topRight = newValue
            case .bottomLeft: bottomLeft = newValue
            case .bottomCenter: bottomCenter = newValue
            case .bottomRight: bottomRight = newValue
            }
        }
    }

    /// What the variables stand for in one document.
    public struct Context: Equatable, Sendable {
        public var fileName: String
        public var title: String
        /// Today, already written in the furniture's date format.
        public var date: String
        /// Logical pages that were added as blanks and stay empty.
        public var blankPages: Set<Int>

        public init(fileName: String = "", title: String = "", date: String = "", blankPages: Set<Int> = []) {
            self.fileName = fileName
            self.title = title
            self.date = date
            self.blankPages = blankPages
        }
    }

    /// The text of the six places on one page, left to right.
    public struct Lines: Equatable, Sendable {
        public var top: [String]
        public var bottom: [String]

        public init(top: [String], bottom: [String]) {
            self.top = top
            self.bottom = bottom
        }
    }

    /// The text for the logical page at `index`, or nil for a page that carries none.
    /// How wide the middle of a row may be. It leaves each side the room its own text needs, up to a fifth of the row;
    /// the middle is centered, so the wider side decides.
    public static func centerLimit(left: CGFloat, right: CGFloat, available: CGFloat, gap: CGFloat) -> CGFloat {
        let reserved = min(max(left, right), available / 5)
        return reserved > 0 ? available - 2 * (reserved + gap) : available
    }

    public func lines(forPage index: Int, pageCount: Int, context: Context, hasFacingPages: Bool) -> Lines? {
        guard !isEmpty, !context.blankPages.contains(index), !(skipsFirstPage && index == 0) else { return nil }
        func filled(_ text: String) -> String {
            guard text.contains("{") else { return text }
            return [
                (Variable.fileName, context.fileName), (Variable.title, context.title), (Variable.date, context.date),
                (Variable.page, String(index + 1)), (Variable.pageCount, String(pageCount)),
            ].reduce(text) { $0.replacingOccurrences(of: $1.0.rawValue, with: $1.1) }
        }
        let swaps = swapsOnSpreads && hasFacingPages && index % 2 == 1
        func row(_ left: String, _ center: String, _ right: String) -> [String] {
            (swaps ? [right, center, left] : [left, center, right]).map(filled)
        }
        return Lines(top: row(topLeft, topCenter, topRight), bottom: row(bottomLeft, bottomCenter, bottomRight))
    }

    /// `date` in the date format. `YYYY` is the year, `MM` and `DD` the month and day in two digits, `M` and `D` the
    /// same without the zero, and `曜` the day of the week; everything else stays as written. The letters stand
    /// for the date only on their own: next to another letter of the alphabet they are part of a word, so the `D`
    /// of "Date" and the `M` of "Mar" stay.
    ///
    /// The year is counted as the documents of this app write it, in the Gregorian calendar, whichever calendar
    /// the Mac is set to: a Mac on the Japanese calendar printed the year 8 for 2026.
    public func dateText(
        _ date: Date, language: String, calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        var calendar = calendar
        calendar.locale = Locale(identifier: language)
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekdays = calendar.shortStandaloneWeekdaySymbols
        let weekday = parts.weekday.flatMap { weekdays.indices.contains($0 - 1) ? weekdays[$0 - 1] : nil } ?? ""
        func padded(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let tokens: [String: String] = [
            "YYYY": String(parts.year ?? 0), "MM": padded(parts.month), "DD": padded(parts.day),
            "M": String(parts.month ?? 0), "D": String(parts.day ?? 0),
        ]
        // The format in runs of one character, so `MMM` is not a month followed by an `M`.
        var runs: [Substring] = []
        var rest = Substring(dateFormat)
        while let first = rest.first {
            let run = rest.prefix { $0 == first }
            runs.append(run)
            rest = rest.dropFirst(run.count)
        }
        func isLatinLetter(_ run: Substring) -> Bool { run.first.map { $0.isASCII && $0.isLetter } ?? false }
        var result = ""
        var index = 0
        while index < runs.count {
            guard isLatinLetter(runs[index]) else {
                if runs[index].first == "曜" {
                    result += String(repeating: weekday, count: runs[index].count)
                } else {
                    result += String(runs[index])
                }
                index += 1
                continue
            }
            // Letters that touch make one word, which is a date only when every part of it is (`YYYYMMDD`).
            let word = runs[index...].prefix(while: isLatinLetter)
            let values = word.map { tokens[String($0)] }
            result += values.contains(nil) ? word.joined() : values.compactMap { $0 }.joined()
            index += word.count
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight, dateFormat, skipsFirstPage,
            swapsOnSpreads
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? values.decodeIfPresent(String.self, forKey: key)) ?? "" }
        topLeft = text(.topLeft)
        topCenter = text(.topCenter)
        topRight = text(.topRight)
        bottomLeft = text(.bottomLeft)
        bottomCenter = text(.bottomCenter)
        bottomRight = text(.bottomRight)
        dateFormat = (try? values.decodeIfPresent(String.self, forKey: .dateFormat)) ?? Self.defaultDateFormat
        skipsFirstPage = (try? values.decodeIfPresent(Bool.self, forKey: .skipsFirstPage)) ?? false
        swapsOnSpreads = (try? values.decodeIfPresent(Bool.self, forKey: .swapsOnSpreads)) ?? false
    }
}
