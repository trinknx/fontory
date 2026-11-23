import Foundation
import Testing
@testable import FontoryCore

@Suite struct FamilyListSorterTests {
    private func group(_ name: String, _ ids: [Int64]) -> FamilyGroup {
        FamilyGroup(id: name.lowercased(), name: name, faceIDs: ids, representativeID: ids[0])
    }

    @Test func sortsFacesThenFamiliesByFirstFaceAscending() {
        let groups = [group("A", [1, 2]), group("B", [3, 4])]
        let keys: [Int64: FamilySortKey] = [1: .text("Zeta"), 2: .text("Beta"), 3: .text("Alpha"), 4: .text("Gamma")]
        let out = FamilyListSorter.sorted(groups, keys: keys, ascending: true)
        #expect(out.map(\.name) == ["B", "A"])
        #expect(out.map(\.faceIDs) == [[3, 4], [2, 1]])
    }

    @Test func descendingReversesOrder() {
        let groups = [group("A", [1, 2]), group("B", [3, 4])]
        let keys: [Int64: FamilySortKey] = [1: .number(10), 2: .number(5), 3: .number(1), 4: .number(7)]
        let out = FamilyListSorter.sorted(groups, keys: keys, ascending: false)
        #expect(out.map(\.name) == ["A", "B"])
        #expect(out.map(\.faceIDs) == [[1, 2], [4, 3]])
    }

    @Test func numericKeysCompareAsNumbers() {
        let groups = [group("A", [1, 2, 3])]
        let keys: [Int64: FamilySortKey] = [1: .number(100), 2: .number(9), 3: .number(20)]
        #expect(FamilyListSorter.sorted(groups, keys: keys, ascending: true)[0].faceIDs == [2, 3, 1])
    }

    @Test func textKeysUseNaturalOrder() {
        let groups = [group("A", [1, 2, 3])]
        let keys: [Int64: FamilySortKey] = [1: .text("Version 10"), 2: .text("version 2"), 3: .text("Version 1")]
        #expect(FamilyListSorter.sorted(groups, keys: keys, ascending: true)[0].faceIDs == [3, 2, 1])
    }

    @Test func tiesKeepTheirOrderInBothDirections() {
        let groups = [group("A", [1, 2]), group("B", [3, 4]), group("C", [5, 6])]
        let keys: [Int64: FamilySortKey] = [1: .text("x"), 2: .text("x"), 3: .text("x"), 4: .text("x"), 5: .text("x"), 6: .text("x")]
        for ascending in [true, false] {
            let out = FamilyListSorter.sorted(groups, keys: keys, ascending: ascending)
            #expect(out.map(\.name) == ["A", "B", "C"])
            #expect(out.map(\.faceIDs) == [[1, 2], [3, 4], [5, 6]])
        }
    }

    @Test func missingAndEmptyKeysSortLastInBothDirections() {
        let groups = [group("A", [1, 2, 3, 4])]
        let keys: [Int64: FamilySortKey] = [1: .none, 2: .text("b"), 3: .text(""), 4: .text("a")]
        #expect(FamilyListSorter.sorted(groups, keys: keys, ascending: true)[0].faceIDs == [4, 2, 1, 3])
        #expect(FamilyListSorter.sorted(groups, keys: keys, ascending: false)[0].faceIDs == [2, 4, 1, 3])
    }
}
