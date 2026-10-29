import Foundation
import SurimonoCore
import Testing

struct NaturalOrderTests {
    @Test("画像名の数字を数値として並べる")
    func imageNames() {
        #expect(
            ["IMG_10", "IMG_2", "IMG_1"].sorted(by: NaturalOrder.areInIncreasingOrder)
                == ["IMG_1", "IMG_2", "IMG_10"])
    }

    @Test("1から12までを数値順に並べる")
    func numbers() {
        #expect(
            ["12", "3", "10", "1", "8", "6", "11", "2", "9", "5", "7", "4"]
                .sorted(by: NaturalOrder.areInIncreasingOrder)
                == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"])
    }

    @Test("同じ数値は先頭のゼロが少ない順に並べる")
    func leadingZeros() {
        #expect(["001", "01", "1"].sorted(by: NaturalOrder.areInIncreasingOrder) == ["1", "01", "001"])
    }

    @Test("大小文字の違いは文字の種類より後に比較する")
    func letterCase() {
        #expect(["b", "A", "a"].sorted(by: NaturalOrder.areInIncreasingOrder) == ["a", "A", "b"])
    }

    @Test("文字幅の違いは文字の種類より後に比較する")
    func characterWidth() {
        #expect(["b", "ａ", "a"].sorted(by: NaturalOrder.areInIncreasingOrder) == ["a", "ａ", "b"])
    }

    @Test("全角数字も数値として比較する")
    func fullWidthDigits() {
        #expect(NaturalOrder.compare("２", "10") == .orderedAscending)
    }

    @Test("全角と半角が混ざるときは Finder と同じ順に並べる")
    func mixedWidthsFollowFinder() {
        #expect(["01", "１"].sorted(by: NaturalOrder.areInIncreasingOrder) == ["01", "１"])
        #expect(["Ａ１", "A01"].sorted(by: NaturalOrder.areInIncreasingOrder) == ["A01", "Ａ１"])
    }

    @Test("同じ数値の全角と半角は同順位にならず元の文字幅で順序を決める")
    func equalValueDigitWidths() {
        #expect(NaturalOrder.compare("１", "1") == .orderedDescending)
        #expect(NaturalOrder.compare("1", "１") == .orderedAscending)
    }

    @Test("パスはフォルダ名を先に比較してからファイル名を数値順に並べる")
    func paths() {
        #expect(
            ["2日目/IMG_1.jpg", "1日目/IMG_10.jpg", "1日目/IMG_2.jpg"]
                .sorted(by: NaturalOrder.arePathsInIncreasingOrder)
                == ["1日目/IMG_2.jpg", "1日目/IMG_10.jpg", "2日目/IMG_1.jpg"])
    }

    @Test("共通のパス要素で終わる短いパスを先にする")
    func pathPrefix() {
        #expect(NaturalOrder.comparePaths("folder", "folder/IMG_1.jpg") == .orderedAscending)
        #expect(NaturalOrder.comparePaths("folder/IMG_1.jpg", "folder") == .orderedDescending)
    }

    @Test("同じ文字列の比較は同順位になり昇順とは判定しない")
    func equalNames() {
        #expect(NaturalOrder.compare("IMG_1", "IMG_1") == .orderedSame)
        #expect(!NaturalOrder.areInIncreasingOrder("IMG_1", "IMG_1"))
    }

    @Test("同じパスの比較は同順位になり昇順とは判定しない")
    func equalPaths() {
        #expect(NaturalOrder.comparePaths("folder/IMG_1.jpg", "folder/IMG_1.jpg") == .orderedSame)
        #expect(!NaturalOrder.arePathsInIncreasingOrder("folder/IMG_1.jpg", "folder/IMG_1.jpg"))
    }

    @Test("異なる文字列の比較は同順位にならず逆向きでは順序が反転する")
    func totalOrder() {
        let names = ["", "1", "01", "001", "２", "10", "a", "A", "ａ", "b", "é", "e\u{301}"]
        for (index, lhs) in names.enumerated() {
            for rhs in names.dropFirst(index + 1) {
                let forward = NaturalOrder.compare(lhs, rhs)
                let backward = NaturalOrder.compare(rhs, lhs)
                #expect(forward != .orderedSame)
                #expect(
                    (forward == .orderedAscending && backward == .orderedDescending)
                        || (forward == .orderedDescending && backward == .orderedAscending))
            }
        }
    }

    @Test("異なるパスの比較は同順位にならず逆向きでは順序が反転する")
    func totalPathOrder() {
        let paths = ["", "/", "a", "a/", "a//b", "a/b", "a/2", "a/10", "A/b", "ａ/b"]
        for (index, lhs) in paths.enumerated() {
            for rhs in paths.dropFirst(index + 1) {
                let forward = NaturalOrder.comparePaths(lhs, rhs)
                let backward = NaturalOrder.comparePaths(rhs, lhs)
                #expect(forward != .orderedSame)
                #expect(
                    (forward == .orderedAscending && backward == .orderedDescending)
                        || (forward == .orderedDescending && backward == .orderedAscending))
            }
        }
    }
}
