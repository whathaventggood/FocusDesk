import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import FocusDeskCore
#else
@testable import FocusDesk
#endif

private final class QuoteTestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private(set) var writeCount = 0

    init() { super.init(suiteName: "FocusDesk.QuoteTests.InMemory")! }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
        writeCount += 1
    }
}

final class MotivationalQuoteTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_886_400)

    private func cachedDate(_ defaults: UserDefaults) -> Date? {
        (defaults.object(forKey: QuoteRotation.cacheKey) as? [String: Any])?["selectedAt"] as? Date
    }

    func testCatalogHasUniqueStableIDsAndNonemptyTextExplanationAndSource() {
        XCTAssertEqual(MotivationalQuote.all.count, 20)
        XCTAssertEqual(Set(MotivationalQuote.all.map(\.id)).count, MotivationalQuote.all.count)
        XCTAssertEqual(Set(MotivationalQuote.all.map(\.text)).count, MotivationalQuote.all.count)
        XCTAssertTrue(MotivationalQuote.all.allSatisfy {
            !$0.id.isEmpty && [$0.text, $0.explanation, $0.source].allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        })
    }

    func testFirstSelectionIsCachedAndStaysUntilOneHour() {
        let defaults = QuoteTestDefaults()
        var selectionCount = 0
        let rotation = QuoteRotation(defaults: defaults) { count in
            selectionCount += 1
            return count - 1
        }
        let first = rotation.quote(at: start)
        XCTAssertEqual(first, MotivationalQuote.all.last)
        XCTAssertEqual(cachedDate(defaults), start)
        XCTAssertEqual(rotation.quote(at: start.addingTimeInterval(1)), first)
        XCTAssertEqual(rotation.quote(at: start.addingTimeInterval(QuoteRotation.refreshInterval - 0.001)), first)
        XCTAssertEqual(selectionCount, 1)
        XCTAssertEqual(defaults.writeCount, 1)
    }

    func testExactlyOneHourSelectsAnotherQuote() {
        XCTAssertEqual(QuoteRotation.refreshInterval, 3_600)
        let defaults = QuoteTestDefaults()
        let rotation = QuoteRotation(defaults: defaults, chooseIndex: { _ in 0 })
        let first = rotation.quote(at: start)
        let boundary = start.addingTimeInterval(QuoteRotation.refreshInterval)
        let second = rotation.quote(at: boundary)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second, MotivationalQuote.all[1])
        XCTAssertEqual(cachedDate(defaults), boundary)
        XCTAssertEqual(rotation.quote(at: boundary.addingTimeInterval(1)), second)
        XCTAssertEqual(defaults.writeCount, 2)
    }

    func testNewRotationInstanceReusesCachedSelectionAndOriginalDeadline() {
        let defaults = QuoteTestDefaults()
        let original = QuoteRotation(defaults: defaults, chooseIndex: { _ in 4 }).quote(at: start)
        var selectionCount = 0
        let restarted = QuoteRotation(defaults: defaults) { _ in
            selectionCount += 1
            return 0
        }
        XCTAssertEqual(restarted.quote(at: start.addingTimeInterval(30 * 60)), original)
        XCTAssertEqual(selectionCount, 0)
        XCTAssertEqual(cachedDate(defaults), start)
        XCTAssertNotEqual(restarted.quote(at: start.addingTimeInterval(QuoteRotation.refreshInterval)), original)
        XCTAssertEqual(selectionCount, 1)
    }

    func testLongSleepRefreshesOnceAndStartsFreshHourInterval() {
        let defaults = QuoteTestDefaults()
        var selectionCount = 0
        let rotation = QuoteRotation(defaults: defaults) { _ in
            selectionCount += 1
            return 0
        }
        let first = rotation.quote(at: start)
        let wake = start.addingTimeInterval(7 * QuoteRotation.refreshInterval + 123)
        let second = rotation.quote(at: wake)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(selectionCount, 2)
        XCTAssertEqual(cachedDate(defaults), wake)
        XCTAssertEqual(rotation.quote(at: wake.addingTimeInterval(QuoteRotation.refreshInterval - 1)), second)
        XCTAssertEqual(selectionCount, 2)
    }

    func testClockMovingBackwardKeepsQuoteAndRebasesDeadline() {
        let defaults = QuoteTestDefaults()
        var selectionCount = 0
        let rotation = QuoteRotation(defaults: defaults) { _ in
            selectionCount += 1
            return 0
        }
        let first = rotation.quote(at: start)
        let corrected = start.addingTimeInterval(-3 * 24 * 60 * 60)
        XCTAssertEqual(rotation.quote(at: corrected), first)
        XCTAssertEqual(cachedDate(defaults), corrected)
        XCTAssertEqual(selectionCount, 1)
        XCTAssertEqual(rotation.quote(at: corrected.addingTimeInterval(QuoteRotation.refreshInterval - 1)), first)
        XCTAssertNotEqual(rotation.quote(at: corrected.addingTimeInterval(QuoteRotation.refreshInterval)), first)
        XCTAssertEqual(selectionCount, 2)
    }

    func testMalformedOrRemovedQuoteCacheIsRepaired() {
        let brokenCaches: [Any] = [
            "not a cache",
            ["selectedAt": start],
            ["id": "removed-quote", "selectedAt": start],
            ["id": 42, "selectedAt": start]
        ]
        for cache in brokenCaches {
            let defaults = QuoteTestDefaults()
            defaults.set(cache, forKey: QuoteRotation.cacheKey)
            let quote = QuoteRotation(defaults: defaults, chooseIndex: { _ in 0 }).quote(at: start)
            XCTAssertEqual(quote, MotivationalQuote.all[0])
            XCTAssertEqual(cachedDate(defaults), start)
        }
    }

    func testMissingInvalidAndNonfiniteCachedDatesSelectDifferentQuote() {
        let first = MotivationalQuote.all[0]
        let brokenCaches: [[String: Any]] = [
            ["id": first.id],
            ["id": first.id, "selectedAt": "yesterday"],
            ["id": first.id, "selectedAt": Date(timeIntervalSince1970: .infinity)],
            ["id": first.id, "selectedAt": Date(timeIntervalSince1970: .nan)]
        ]
        for cache in brokenCaches {
            let defaults = QuoteTestDefaults()
            defaults.set(cache, forKey: QuoteRotation.cacheKey)
            let quote = QuoteRotation(defaults: defaults, chooseIndex: { _ in 0 }).quote(at: start)
            XCTAssertEqual(quote, MotivationalQuote.all[1])
            XCTAssertEqual(cachedDate(defaults), start)
        }
    }

    func testRotationUsesRandomDrawsInsteadOfCatalogOrder() {
        let defaults = QuoteTestDefaults()
        var draws = [15, 2, 11].makeIterator()
        let rotation = QuoteRotation(defaults: defaults) { _ in draws.next()! }
        XCTAssertEqual(rotation.quote(at: start), MotivationalQuote.all[15])
        XCTAssertEqual(rotation.quote(at: start.addingTimeInterval(3_600)), MotivationalQuote.all[2])
        XCTAssertEqual(rotation.quote(at: start.addingTimeInterval(7_200)), MotivationalQuote.all[12])
    }

    func testExistingSixHourCacheUsesShorterDeadlineImmediately() {
        let defaults = QuoteTestDefaults()
        let previous = MotivationalQuote.all[7]
        defaults.set(["id": previous.id, "selectedAt": start], forKey: QuoteRotation.cacheKey)
        let now = start.addingTimeInterval(2 * 3_600)
        let quote = QuoteRotation(defaults: defaults, chooseIndex: { _ in 3 }).quote(at: now)
        XCTAssertNotEqual(quote, previous)
        XCTAssertEqual(cachedDate(defaults), now)
    }

    func testRepeatedRotationsExcludePreviousQuoteFromCandidates() {
        let defaults = QuoteTestDefaults()
        var candidateCounts: [Int] = []
        let rotation = QuoteRotation(defaults: defaults) { count in
            candidateCounts.append(count)
            return count - 1
        }
        var previous = rotation.quote(at: start)
        for step in 1...10 {
            let next = rotation.quote(at: start.addingTimeInterval(Double(step) * QuoteRotation.refreshInterval))
            XCTAssertNotEqual(next.id, previous.id)
            previous = next
        }
        XCTAssertEqual(candidateCounts.first, MotivationalQuote.all.count)
        XCTAssertTrue(candidateCounts.dropFirst().allSatisfy { $0 == MotivationalQuote.all.count - 1 })
    }
}
