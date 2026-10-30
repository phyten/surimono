import SurimonoCore
import Testing

struct ThemeComparisonTests {
    /// SplitMix64 with a fixed seed, so a shuffle is the same on every run.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("いまのスタイルを先頭に、勧めるスタイルから重ならずに 4 つまで並べる")
    func startsWithTheCurrentTheme() {
        let comparison = ThemeComparison(
            current: "mincho", suggestions: ["standard", "mincho", "modern", "github", "x"])
        #expect(comparison.candidates == ["mincho", "standard", "modern", "github"])
        #expect(comparison.current == "mincho")
    }

    @Test("4 つ並んでいるところへ足すと、いま以外でいちばん前からあるものと入れ替わる")
    func addingToAFullSetDropsTheOldest() {
        var comparison = ThemeComparison(current: "standard", suggestions: ["mincho", "modern", "github"])
        comparison.toggle("confetti")
        #expect(comparison.candidates == ["standard", "modern", "github", "confetti"])
        comparison.toggle("grid")
        #expect(comparison.candidates == ["standard", "github", "confetti", "grid"])
    }

    @Test("並んでいるものをもう一度選ぶと外れるが、いまのスタイルは外れない")
    func togglingTakesOutAllButTheCurrent() {
        var comparison = ThemeComparison(current: "standard", suggestions: ["mincho"])
        comparison.toggle("mincho")
        comparison.toggle("standard")
        comparison.remove("standard")
        #expect(comparison.candidates == ["standard"])
        comparison.toggle("mincho")
        #expect(comparison.candidates == ["standard", "mincho"])
    }

    @Test("これにすると、その候補が場所を変えずにいまのスタイルになり、前のものは外せるようになる")
    func choosingKeepsTheOrder() {
        var comparison = ThemeComparison(current: "standard", suggestions: ["mincho", "modern"])
        comparison.choose("modern")
        comparison.choose("not-a-candidate")
        #expect(comparison.current == "modern")
        #expect(comparison.candidates == ["standard", "mincho", "modern"])
        comparison.remove("standard")
        #expect(comparison.candidates == ["mincho", "modern"])
    }

    @Test("おまかせは、いまのスタイルを残して、残りを候補の中から重ならずに選び直す")
    func shuffleKeepsTheCurrentTheme() {
        var comparison = ThemeComparison(current: "standard", suggestions: ["mincho", "modern", "github"])
        var generator = Seeded(state: 42)
        comparison.shuffle(from: ["standard", "neon", "grid", "zoo", "kids"], using: &generator)
        #expect(comparison.candidates.first == "standard")
        #expect(comparison.candidates.count == 4)
        #expect(Set(comparison.candidates).count == 4)
        #expect(comparison.candidates.dropFirst().allSatisfy { ["neon", "grid", "zoo", "kids"].contains($0) })
        var small = ThemeComparison(current: "standard", suggestions: [])
        small.shuffle(from: ["standard", "neon"], using: &generator)
        #expect(small.candidates == ["standard", "neon"])
    }
}
