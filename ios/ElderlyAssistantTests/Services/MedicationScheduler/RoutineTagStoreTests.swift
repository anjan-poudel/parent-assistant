import XCTest
@testable import ElderlyAssistant

final class RoutineTagStoreTests: XCTestCase {

    private func makeStore() -> (RoutineTagStore, GeminiInMemoryStorage) {
        let storage = GeminiInMemoryStorage()
        return (RoutineTagStore(storage: storage), storage)
    }

    func testUntaggedEntryDefaultsToMedication() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.category(for: UUID()), .medication,
                       "pre-generalization entries (untagged) must read as medication — that's what keeps existing data's meaning unchanged")
    }

    func testSetAndReadCategory() {
        let (store, _) = makeStore()
        let id = UUID()
        store.setCategory(.exercise, for: id)
        XCTAssertEqual(store.category(for: id), .exercise)
    }

    func testSetCategoryReplacesExisting() {
        let (store, _) = makeStore()
        let id = UUID()
        store.setCategory(.exercise, for: id)
        store.setCategory(.meal, for: id)
        XCTAssertEqual(store.category(for: id), .meal)
    }

    func testRemoveCategoryReturnsToDefault() {
        let (store, _) = makeStore()
        let id = UUID()
        store.setCategory(.walk, for: id)
        store.removeCategory(for: id)
        XCTAssertEqual(store.category(for: id), .medication)
    }

    func testPruneDropsOrphanedTags() {
        let (store, _) = makeStore()
        let keep = UUID()
        let drop = UUID()
        store.setCategory(.gym, for: keep)
        store.setCategory(.bedtime, for: drop)
        store.prune(keepingEntryIds: [keep])
        XCTAssertEqual(store.category(for: keep), .gym)
        XCTAssertEqual(store.category(for: drop), .medication)
    }

    func testPersistsAcrossInstances() {
        let (store, storage) = makeStore()
        let id = UUID()
        store.setCategory(.reading, for: id)
        let reloaded = RoutineTagStore(storage: storage)
        XCTAssertEqual(reloaded.category(for: id), .reading)
    }

    func testAllCategoriesHaveLabelKeyAndIcon() {
        for cat in RoutineCategory.allCases {
            XCTAssertFalse(cat.labelKey.isEmpty)
            XCTAssertFalse(cat.systemImage.isEmpty)
        }
    }
}
