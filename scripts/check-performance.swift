import Foundation
import CoreGraphics

private struct CheckFailure: Error { let message: String }

@main
private enum StatisticsPerformanceCheck {
    private static var checks = 0
    private static var sink = 0.0

    private static func require(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw CheckFailure(message: message) }
    }

    private static func milliseconds(_ count: Int, _ body: () throws -> Double) rethrows -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<count { sink += try body() }
        return (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(count)
    }

    // Independent reference: clip each original session to every requested day.
    private static func reference(_ document: ActivityTimerDocument, at date: Date, days: Int,
                                  calendar: Calendar) -> [ActivityDailyDuration] {
        let today = calendar.startOfDay(for: date)
        return (0..<days).reversed().flatMap { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let end = min(calendar.date(byAdding: .day, value: 1, to: day)!, date)
            var totals: [UUID: Double] = [:]
            for session in document.sessions {
                totals[session.activityID, default: 0] += session.duration(at: date, in: DateInterval(start: day, end: end))
            }
            return document.activities.map { ActivityDailyDuration(day: day, activityID: $0.id, duration: totals[$0.id, default: 0]) }
        }
    }

    private static func compare(_ document: ActivityTimerDocument, snapshot: ActivityStatisticsSnapshot,
                                at date: Date, calendar: Calendar) throws {
        for days in [1, 7, 30, 31] {
            let expected = reference(document, at: date, days: days, calendar: calendar)
            let actual = snapshot.dailyDurations(days: days)
            try require(actual.count == expected.count, "Daily point counts differ")
            for (left, right) in zip(actual, expected) {
                try require(left.id == right.id && abs(left.duration - right.duration) < 0.000001, "Daily attribution differs")
            }
        }
        for days in [0, 1, 7, 30] {
            let today = calendar.startOfDay(for: date)
            let interval = days == 0 ? nil : DateInterval(start: calendar.date(byAdding: .day, value: 1 - days, to: today)!, end: date)
            for order in ActivityDurationSortOrder.allCases {
                let actual = snapshot.summaries(days: days, order: order)
                let expected = document.durationSummaries(at: date, in: interval, order: order)
                try require(actual.map(\.id) == expected.map(\.id), "Sort order differs")
                for (left, right) in zip(actual, expected) {
                    try require(abs(left.duration - right.duration) < 0.000001, "Range total differs")
                }
            }
        }
        try require(snapshot.completedSessions == document.sessions.filter { $0.endedAt != nil }.sorted { $0.startedAt > $1.startedAt },
                    "Cached record order differs")
    }

    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var document = ActivityTimerDocument()
        for index in 0..<100 { try document.addActivity(name: "学习项目 \(index + 1)") }
        var seed: UInt64 = 0xF0C05DE5
        func random(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        let stress = CommandLine.arguments.contains("--stress")
        for index in 0..<(stress ? 100_000 : 10_000) {
            let start = now.addingTimeInterval(-Double(86400 + index * 1639))
            let first = Double(60 + random(1800)), second = Double(60 + random(1800))
            let end = start.addingTimeInterval(first + 900 + second)
            document.sessions.append(ActivityTimerSession(activityID: document.activities[random(100)].id, mode: .stopwatch,
                                                         startedAt: start,
                                                         segments: [.init(start: start, end: start.addingTimeInterval(first)),
                                                                    .init(start: start.addingTimeInterval(first + 900), end: end)],
                                                         endedAt: end, correctedDuration: index % 4 == 0 ? Double(random(Int(first + second))) : nil))
        }
        try document.validate()
        let cache = ActivityStatisticsCache()
        var report: [String: Any] = ["projects": 100, "completed_records": document.sessions.count]
        report["reference_daily_ms"] = milliseconds(3) { reference(document, at: now, days: 30, calendar: calendar).reduce(0) { $0 + $1.duration } }
        report["indexed_daily_ms"] = milliseconds(5) { document.dailyDurations(at: now, days: 30, calendar: calendar).reduce(0) { $0 + $1.duration } }
        report["cold_snapshot_ms"] = milliseconds(1) { cache.value(document: document, revision: 0, at: now, calendar: calendar).allTimeTotals.values.reduce(0, +) }
        try compare(document, snapshot: cache.value(document: document, revision: 0, at: now, calendar: calendar), at: now, calendar: calendar)
        let builds = cache.buildCount
        report["idle_cached_snapshot_ms"] = milliseconds(200) {
            cache.value(document: document, revision: 0, at: now.addingTimeInterval(sink.truncatingRemainder(dividingBy: 300)), calendar: calendar).allTimeTotals.values.reduce(0, +)
        }
        try require(cache.buildCount == builds, "Idle clock ticks must reuse saved-record statistics")
        try document.renameActivity(id: document.activities[0].id, name: "只更新项目名称")
        report["metadata_update_ms"] = milliseconds(1) {
            cache.value(document: document, revision: 10, at: now, calendar: calendar).allTimeTotals.values.reduce(0, +)
        }
        try require(cache.buildCount == builds && cache.metadataUpdateCount == 1,
                    "Renaming must reuse saved-record totals and record ordering")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focusdesk-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ActivityTimerStore(storageURL: directory.appendingPathComponent("timers.json"))
        try storage.save(document)
        report["store_cold_load_ms"] = try milliseconds(1) { Double(try storage.update { _ in }.sessions.count) }
        // File providers can attach metadata just after a newly created file is first read.
        _ = try milliseconds(5) { Double(try storage.update { _ in }.sessions.count) }
        report["unchanged_store_refresh_ms"] = try milliseconds(50) { Double(try storage.update { _ in }.sessions.count) }

        let id = document.activities[0].id
        try document.start(activityID: id, mode: .stopwatch, duration: nil, at: now.addingTimeInterval(-90000))
        document.togglePause(at: now.addingTimeInterval(-80000))
        document.togglePause(at: now.addingTimeInterval(-3600))
        for offset: Double in [0, 1, 120, 86400, -172800, -172700] {
            let date = now.addingTimeInterval(offset)
            try compare(document, snapshot: cache.value(document: document, revision: 1, at: date, calendar: calendar), at: date, calendar: calendar)
        }
        _ = cache.value(document: document, revision: 1, at: now, calendar: calendar)
        let liveBuilds = cache.buildCount
        var tick = 0
        report["live_cached_snapshot_ms"] = milliseconds(200) {
            tick += 1
            return cache.value(document: document, revision: 1, at: now.addingTimeInterval(Double(tick)), calendar: calendar).allTimeTotals.values.reduce(0, +)
        }
        try require(cache.buildCount == liveBuilds, "Running ticks must add only the live stretch")
        document.finish(at: now)
        try document.correctDuration(sessionID: document.sessions.last!.id, duration: 5400)
        try document.renameActivity(id: id, name: "重命名后保留统计")
        try document.deleteActivity(id: document.activities[1].id)
        try document.addActivity(name: "后续新增学习内容")
        try compare(document, snapshot: cache.value(document: document, revision: 2, at: now, calendar: calendar), at: now, calendar: calendar)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        try compare(document, snapshot: cache.value(document: document, revision: 2, at: now, calendar: calendar), at: now, calendar: calendar)
        for text in ["2026-03-08T08:00:00Z", "2026-11-01T07:00:00Z"] {
            let day = ISO8601DateFormatter().date(from: text)!
            let end = calendar.date(byAdding: .day, value: 1, to: day)!
            var dst = ActivityTimerDocument()
            try dst.addActivity(name: "夏令时边界")
            try dst.addRecord(activityID: dst.activities[0].id, startedAt: day.addingTimeInterval(-3600),
                              duration: end.timeIntervalSince(day) + 7200, at: end.addingTimeInterval(7200))
            let date = end.addingTimeInterval(7200)
            try compare(dst, snapshot: ActivityStatisticsCache().value(document: dst, revision: 0, at: date, calendar: calendar), at: date, calendar: calendar)
        }
        let plot = CGRect(x: 0, y: 0, width: 744, height: 400)
        let regions: [ActivityChartRegion] = (0..<31).flatMap { column in
            (0..<100).map { row in
                let activity = document.activities[row]
                let point = ActivityDailyDuration(day: now.addingTimeInterval(Double(-column * 86400)), activityID: activity.id, duration: 4)
                return ActivityChartRegion(segment: ActivityDailyChartSegment(point: point, lowerBound: Double(row * 4)),
                                           activity: activity, frame: CGRect(x: column * 24 + 4, y: row * 4, width: 16, height: 4))
            }
        }
        let hits = ActivityChartHitIndex(regions: regions, plot: plot)
        let queries = (0..<5000).map { _ in CGPoint(x: random(7500) / 10, y: random(4060) / 10) }
        for point in queries {
            try require(hits.hitTest(point)?.id == ActivityChartRegion.hitTest(point, regions: regions, plot: plot)?.id,
                        "Indexed hover must match the reference in dense charts")
        }
        report["hover_regions"] = regions.count
        report["hover_queries"] = queries.count
        report["reference_hover_batch_ms"] = milliseconds(2) {
            Double(queries.reduce(0) { $0 + (ActivityChartRegion.hitTest($1, regions: regions, plot: plot) == nil ? 0 : 1) })
        }
        report["indexed_hover_batch_ms"] = milliseconds(10) {
            Double(queries.reduce(0) { $0 + (hits.hitTest($1) == nil ? 0 : 1) })
        }
        report["checks"] = checks
        let output = URL(fileURLWithPath: "build/ux-validation", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let filename = CommandLine.arguments.contains("--baseline") ? "performance-baseline.json" : stress ? "performance-stress.json" : "performance.json"
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent(filename))
        print(String(decoding: json, as: UTF8.self))
        print("PASS: \(checks) statistics/reference/cache checks; checksum \(sink)")
    }
}
