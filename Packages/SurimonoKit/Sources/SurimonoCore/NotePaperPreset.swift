public struct NotePaperPreset: Identifiable, Equatable, Sendable {
    public enum Group: String, Sendable { case practical, cute }

    public let id: String
    public let englishName: String
    public let japaneseName: String
    public let group: Group
    public let style: NotePaperStyle

    public init(id: String, englishName: String, japaneseName: String, group: Group, style: NotePaperStyle) {
        self.id = id
        self.englishName = englishName
        self.japaneseName = japaneseName
        self.group = group
        self.style = style
    }

    /// The preset a document's note pages start from.
    public static var standard: NotePaperPreset { all[0] }

    public static func preset(id: String) -> NotePaperPreset? { all.first { $0.id == id } }

    public static let all: [NotePaperPreset] = [
        NotePaperPreset(
            id: "daigaku", englishName: "College Ruled", japaneseName: "大学ノート", group: .practical,
            style: NotePaperStyle(
                kind: .ruled, weightInMillimeters: 0.2, spacingInMillimeters: 7,
                marginInMillimeters: 12, colorHex: "#7FA3C7",
                header: .init(date: true, title: false, pageNumber: true), decoration: .none)),
        NotePaperPreset(
            id: "hougan", englishName: "5mm Grid", japaneseName: "5mm 方眼", group: .practical,
            style: NotePaperStyle(
                kind: .grid, weightInMillimeters: 0.15, spacingInMillimeters: 5,
                marginInMillimeters: 10, colorHex: "#7FA3C7",
                header: .init(date: false, title: false, pageNumber: true), decoration: .none)),
        NotePaperPreset(
            id: "dot", englishName: "Dots", japaneseName: "ドット", group: .practical,
            style: NotePaperStyle(
                kind: .dot, weightInMillimeters: 0.4, spacingInMillimeters: 5,
                marginInMillimeters: 10, colorHex: "#9A9A96",
                header: .init(date: false, title: false, pageNumber: true), decoration: .none)),
        NotePaperPreset(
            id: "cornell", englishName: "Cornell", japaneseName: "コーネル", group: .practical,
            style: NotePaperStyle(
                kind: .cornell, weightInMillimeters: 0.25, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#2B4C6F",
                header: .init(date: true, title: true, pageNumber: true), decoration: .none)),
        NotePaperPreset(
            id: "genko", englishName: "Manuscript Paper", japaneseName: "原稿用紙", group: .practical,
            style: NotePaperStyle(
                kind: .genko, weightInMillimeters: 0.25, spacingInMillimeters: 7.5,
                marginInMillimeters: 12, colorHex: "#B86A5A",
                header: .init(date: false, title: false, pageNumber: false), decoration: .none)),
        NotePaperPreset(
            id: "gijiroku", englishName: "Meeting Minutes", japaneseName: "議事録", group: .practical,
            style: NotePaperStyle(
                kind: .table, weightInMillimeters: 0.25, spacingInMillimeters: 9,
                marginInMillimeters: 12, colorHex: "#3A3A3D",
                header: .init(date: false, title: false, pageNumber: true), decoration: .minutes)),
        NotePaperPreset(
            id: "gakufu", englishName: "Music Staff", japaneseName: "五線譜", group: .practical,
            style: NotePaperStyle(
                kind: .staff, weightInMillimeters: 0.2, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#3A3A3D",
                header: .init(date: false, title: false, pageNumber: true), decoration: .none)),
        NotePaperPreset(
            id: "hyou", englishName: "Dated Table", japaneseName: "日付の表", group: .practical,
            style: NotePaperStyle(
                kind: .table, weightInMillimeters: 0.2, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#2B4C6F",
                header: .init(date: false, title: false, pageNumber: true), decoration: .none)),
        NotePaperPreset(
            id: "gingham", englishName: "Gingham", japaneseName: "ギンガム", group: .cute,
            style: NotePaperStyle(
                kind: .ruled, weightInMillimeters: 0.2, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#E59AAE",
                header: .init(date: false, title: false, pageNumber: false), decoration: .gingham)),
        NotePaperPreset(
            id: "mizutama", englishName: "Polka Dots", japaneseName: "水玉", group: .cute,
            style: NotePaperStyle(
                kind: .ruled, weightInMillimeters: 0.25, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#7FA3C7",
                header: .init(date: false, title: false, pageNumber: false), decoration: .mizutama)),
        NotePaperPreset(
            id: "stripe", englishName: "Stripes", japaneseName: "ストライプ", group: .cute,
            style: NotePaperStyle(
                kind: .ruled, weightInMillimeters: 0.2, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#A99BD1",
                header: .init(date: false, title: false, pageNumber: true), decoration: .stripe)),
        NotePaperPreset(
            id: "ichigo", englishName: "Strawberries", japaneseName: "いちご", group: .cute,
            style: NotePaperStyle(
                kind: .dashed, weightInMillimeters: 0.25, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#E59AAE",
                header: .init(date: false, title: false, pageNumber: false), decoration: .ichigo)),
        NotePaperPreset(
            id: "hoshizora", englishName: "Starry Sky", japaneseName: "星空", group: .cute,
            style: NotePaperStyle(
                kind: .dotted, weightInMillimeters: 0.45, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#A99BD1",
                header: .init(date: false, title: false, pageNumber: false), decoration: .hoshizora)),
        NotePaperPreset(
            id: "kumo", englishName: "Clouds", japaneseName: "雲", group: .cute,
            style: NotePaperStyle(
                kind: .wavy, weightInMillimeters: 0.25, spacingInMillimeters: 9,
                marginInMillimeters: 12, colorHex: "#7FA3C7",
                header: .init(date: false, title: false, pageNumber: false), decoration: .kumo)),
        NotePaperPreset(
            id: "ribbon", englishName: "Ribbon", japaneseName: "リボン", group: .cute,
            style: NotePaperStyle(
                kind: .ruled, weightInMillimeters: 0.2, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#E59AAE",
                header: .init(date: false, title: false, pageNumber: false), decoration: .ribbon)),
        NotePaperPreset(
            id: "nikukyu", englishName: "Paw Prints", japaneseName: "肉球", group: .cute,
            style: NotePaperStyle(
                kind: .dashed, weightInMillimeters: 0.25, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#B08A5E",
                header: .init(date: false, title: false, pageNumber: false), decoration: .nikukyu)),
        NotePaperPreset(
            id: "hana", englishName: "Floral Border", japaneseName: "花の縁", group: .cute,
            style: NotePaperStyle(
                kind: .ruled, weightInMillimeters: 0.2, spacingInMillimeters: 8,
                marginInMillimeters: 12, colorHex: "#7FA65B",
                header: .init(date: false, title: false, pageNumber: false), decoration: .hana)),
    ]
}
