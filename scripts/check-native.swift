import AppKit
import Foundation
import SwiftUI
import Combine

private final class SmokeDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "FocusDesk.NativeSmoke")! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

private final class HeldActivityLock {
    private var descriptor: Int32
    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            descriptor = -1
            throw SmokeFailure(description: "Unable to acquire the isolated test lock")
        }
    }
    func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}

private final class StudyChartConfiguration: ObservableObject {
    @Published var excluded: Set<UUID> = []
    @Published var days = 7
}

private struct StudyChartPreview: View {
    @ObservedObject var store: PlanStore
    @ObservedObject var configuration: StudyChartConfiguration

    var body: some View {
        let today = Calendar.current.startOfDay(for: store.now)
        let first = Calendar.current.date(byAdding: .day, value: 1 - configuration.days, to: today)!
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        ActivityDailyChart(points: store.activityTimers.dailyDurations(at: store.now, days: configuration.days)
            .filter { !configuration.excluded.contains($0.activityID) },
                           activities: store.activityTimers.activities, dateRange: first...end, days: configuration.days)
            .padding(24)
            .modifier(ThemeSurface(store: store))
    }
}

@main
private enum NativeSmoke {
    @MainActor private static var checkCount = 0

    @MainActor
    static func main() {
        setbuf(stdout, nil)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/native-smoke", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }

        // Only this opt-in harness uses these overrides. No system login item is changed.
        setenv("FOCUSDESK_SMOKE_TEST", "1", 1)
        setenv("FOCUSDESK_DATA_DIRECTORY", output.appendingPathComponent("app-data-\(UUID().uuidString)").path, 1)
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        // Start from the native run loop, allowing nested event pumping to deliver
        // main-queue hover deadlines while this synchronous harness is checking them.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            Task { @MainActor in
                do {
                    let arguments = CommandLine.arguments
                    if arguments.contains("--experience-only") {
                        try await verifyExperienceFlows(in: output)
                    } else if arguments.contains("--background-only") || !(arguments.contains("--chart-only") || arguments.contains("--usability-only") || arguments.contains("--interactive-study")) {
                        try await verifyBackgroundActivityIO(in: output)
                        try await verifyExperienceFlows(in: output)
                    }
                    // A run-loop timer leaves the main dispatch queue available
                    // to Combine deliveries during the legacy nested event pumps.
                    Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            runWindowChecks(controller: controller, application: application, output: output)
                        }
                    }
                } catch {
                    print("FAIL: \(error)")
                    controller.store.stop()
                    exit(1)
                }
            }
        }
        withExtendedLifetime(controller) { application.run() }
    }

    @MainActor
    private static func runWindowChecks(controller: AppController, application: NSApplication, output: URL) {
        do {
            print("Checking native launch callback; windows: \(application.windows.map(\.title))")
            let arguments = CommandLine.arguments
            if arguments.contains("--interactive-study") {
                try showInteractiveStudyPreview(controller: controller, output: output)
                return
            }
            if arguments.contains("--background-only") || arguments.contains("--experience-only") {
                // The asynchronous checks have completed above.
            } else if arguments.contains("--usability-only") {
                try verifyStudyUsability(in: output)
            } else if arguments.contains("--chart-only") {
                try verifyStudyChartHover(in: output)
                try verifyStudyPreviews(in: output)
                try verifyStudyUsability(in: output)
            } else {
                try verifyPersistence(in: output)
                try verifyQuoteRefresh(in: output)
                try verifyActivityTimers(in: output)
                try verifySleepAndStudyRecords(in: output)
                try verifyStudyChartHover(in: output)
                try verifyStudyPreviews(in: output)
                try verifyStudyUsability(in: output)
                try verifyWindows(controller: controller, output: output)
            }
            print("PASS: \(checkCount) native window, hover, persistence, and recovery checks")
            print("Preview PNGs: \(output.path)")
            application.terminate(nil)
        } catch {
            print("FAIL: \(error)")
            controller.store.stop()
            exit(1)
        }
    }

    @MainActor
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SmokeFailure(description: message) }
        checkCount += 1
    }

    @MainActor
    private static func verifyBackgroundActivityIO(in output: URL) async throws {
        var now = ISO8601DateFormatter().date(from: "2026-11-08T04:10:00Z")!
        let directory = output.appendingPathComponent("background-\(UUID().uuidString)")
        let writer = ActivityTimerStore(storageURL: directory.appendingPathComponent("timers.json"))
        var document = ActivityTimerDocument()
        try document.addActivity(name: "后台计时")
        let id = document.activities[0].id
        for index in 0..<1000 {
            try document.addRecord(activityID: id, startedAt: now.addingTimeInterval(Double(-86400 - index * 1000)), duration: 60, at: now)
        }
        try writer.save(document)
        let store = PlanStore(storageDirectory: directory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false, useBackgroundActivityIO: true)
        defer { store.stop() }
        try require(!store.activityDataReady, "Cold activity loading must begin asynchronously")
        func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SmokeFailure(description: "Timed out: \(description)") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        try await waitUntil("initial background load") { store.activityDataReady && !store.activityReadInProgress }
        try require(store.activityTimers.sessions.count == 1000, "Background load must restore every record")

        var rootChanges = 0, clockChanges = 0
        let rootSubscription = store.objectWillChange.sink { rootChanges += 1 }
        let clockSubscription = store.clock.$now.dropFirst().sink { _ in clockChanges += 1 }
        for _ in 0..<40 { now = now.addingTimeInterval(1); store.refresh(); try await Task.sleep(nanoseconds: 2_000_000) }
        try await waitUntil("idle poll") { !store.activityReadInProgress }
        try require(clockChanges == 40, "Clock subscribers must receive all ticks")
        try require(rootChanges == 0, "Idle ticks must not invalidate settings, history and static forms")
        rootSubscription.cancel(); clockSubscription.cancel()

        _ = try writer.update { try $0.renameActivity(id: id, name: "后台计时 · 外部更新") }
        store.refresh()
        try await waitUntil("external document poll") { !store.activityReadInProgress }
        try require(store.activityTimers.activities[0].name == "后台计时 · 外部更新",
                    "Background polling must publish another window's committed changes")

        let held = try HeldActivityLock(url: writer.storageURL.appendingPathExtension("lock"))
        let clickedAt = now
        let start = Task { @MainActor in await store.performActivityAction(.start(id, .stopwatch, nil)) }
        try await waitUntil("pending start") { store.activitySaveInProgress }
        var beats = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in beats += 1 }
        now = now.addingTimeInterval(60)
        store.refresh()
        try await Task.sleep(nanoseconds: 80_000_000)
        heartbeat.invalidate()
        try require(beats > 0 && store.activitySaveInProgress, "A held file lock must leave the main event loop responsive")
        held.release()
        let startError = await start.value
        try require(startError == nil, "Queued Start should save after the lock is released")
        try require(store.activityTimers.activeSession?.startedAt == clickedAt, "Storage waiting must not change the click timestamp")
        now = now.addingTimeInterval(30)
        let pauseLock = try HeldActivityLock(url: writer.storageURL.appendingPathExtension("lock"))
        let pause = Task { @MainActor in await store.performActivityAction(.togglePause) }
        try await waitUntil("pending pause") { store.activitySaveInProgress }
        now = now.addingTimeInterval(20)
        store.refresh()
        try require(store.activityTimers.activeSession?.elapsed(at: store.activityDisplayNow) == 90,
                    "The visible clock must freeze at the pause click while saving")
        try require(store.activityStatistics().allTimeTotals[id] == 60_090,
                    "Live statistics must use the same pending pause boundary")
        pauseLock.release()
        let pauseError = await pause.value
        try require(pauseError == nil && store.activityTimers.activeSession?.elapsed(at: now) == 90,
                    "Pause must use the requested boundary rather than worker completion time")
        let finishError = await store.performActivityAction(.finish)
        try require(finishError == nil && store.activityTimers.sessions.last?.savedDuration == 90, "Background finish must preserve exact elapsed time")
        try await waitUntil("refresh drain") { !store.activityReadInProgress }

        let beforeFailure = try Data(contentsOf: writer.storageURL)
        let busy = try HeldActivityLock(url: writer.storageURL.appendingPathExtension("lock"))
        let failure = await store.performActivityAction(.add("不应在超时后写入"))
        try require(failure != nil && !store.activitySaveInProgress, "A lock deadline must release the pending UI state")
        try require(try Data(contentsOf: writer.storageURL) == beforeFailure, "A timed-out mutation must not alter the document")
        busy.release()
        let retry = await store.performActivityAction(.add("重试成功"))
        try require(retry == nil && store.activityTimerError == nil, "A lock timeout must not permanently block subsequent writes")

        let restartError = await store.performActivityAction(.start(id, .stopwatch, nil))
        try require(restartError == nil, "Sleep fixture should start")
        now = now.addingTimeInterval(60)
        try await waitUntil("before sleep") { !store.activityReadInProgress }
        let sleepLock = try HeldActivityLock(url: writer.storageURL.appendingPathExtension("lock"))
        store.pauseActivityTimerForSleep()
        try require(store.activityTimers.activeSession?.isPaused == true, "Sleep must pause visible time immediately")
        let boundaryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("timers.sleep-") }
        try require(!boundaryFiles.isEmpty, "The sleep boundary must survive a blocked full-document write")
        now = now.addingTimeInterval(17 * 3600)
        sleepLock.release()
        try await waitUntil("sleep merge") { !store.activityReadInProgress }
        store.refresh()
        try await waitUntil("wake merge") { !store.activityReadInProgress }
        try require(store.activityTimers.activeSession?.elapsed(at: now) == 60 && store.activityTimers.activeSession?.isPaused == true,
                    "Sleep retry must exclude overnight time")
        let reloaded = ActivityTimerStore(storageURL: writer.storageURL).load()
        try require(reloaded.activeSession?.elapsed(at: now) == 60 && reloaded.activeSession?.isPaused == true,
                    "The merged sleep boundary must survive restart")

        let quitLock = try HeldActivityLock(url: writer.storageURL.appendingPathExtension("lock"))
        let saveBeforeQuit = Task { @MainActor in await store.performActivityAction(.finish) }
        try await waitUntil("save before quit") { store.activitySaveInProgress }
        let quitting = Task { @MainActor in await store.prepareForTermination() }
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(store.needsActivityFlush, "Quit must wait for an acknowledged write")
        quitLock.release()
        let saveResult = await saveBeforeQuit.value
        let quitResult = await quitting.value
        try require(saveResult == nil && quitResult, "Quit should complete after the write is persisted")
        try require(ActivityTimerStore(storageURL: writer.storageURL).load().activeSession == nil, "Quit must not drop the final record")

        // A Start already queued when sleep arrives must be persisted as paused.
        let queuedLock = try HeldActivityLock(url: writer.storageURL.appendingPathExtension("lock"))
        let queuedStart = Task { @MainActor in await store.performActivityAction(.start(id, .stopwatch, nil)) }
        try await waitUntil("start before sleep") { store.activitySaveInProgress }
        now = now.addingTimeInterval(45)
        store.pauseActivityTimerForSleep()
        now = now.addingTimeInterval(3600)
        queuedLock.release()
        let queuedError = await queuedStart.value
        try require(queuedError == nil, "Start queued before sleep must still save")
        try await waitUntil("queued start polling drain") { !store.activityReadInProgress }
        store.refresh()
        try await waitUntil("queued start sleep merge") { !store.activityReadInProgress }
        try require(store.activityTimers.activeSession?.elapsed(at: now) == 45 && store.activityTimers.activeSession?.isPaused == true,
                    "A queued Start must exclude sleep even before its session appears in the UI")

        // A pending, known sleep pause belongs before a later explicit Resume.
        try await waitUntil("before pending sleep resume") { !store.activityReadInProgress }
        let resumeLock = try HeldActivityLock(url: writer.storageURL.appendingPathExtension("lock"))
        store.pauseActivityTimerForSleep()
        let resumedAt = now
        let resume = Task { @MainActor in await store.performActivityAction(.togglePause) }
        try await waitUntil("resume after sleep") { store.activitySaveInProgress }
        resumeLock.release()
        let resumeError = await resume.value
        try require(resumeError == nil && store.activityTimers.activeSession?.runningSince == resumedAt,
                    "An acknowledged sleep boundary must not undo the user's subsequent Resume")
        _ = await store.performActivityAction(.finish)

        // The initial disk snapshot must not overwrite a sleep pause arriving during load.
        var coldDocument = ActivityTimerDocument()
        try coldDocument.addActivity(name: "启动时睡眠")
        try coldDocument.start(activityID: coldDocument.activities[0].id, mode: .stopwatch, duration: nil, at: now.addingTimeInterval(-30))
        let coldDirectory = output.appendingPathComponent("cold-sleep-\(UUID().uuidString)")
        let coldWriter = ActivityTimerStore(storageURL: coldDirectory.appendingPathComponent("timers.json"))
        try coldWriter.save(coldDocument)
        let coldLock = try HeldActivityLock(url: coldWriter.storageURL.appendingPathExtension("lock"))
        let coldStore = PlanStore(storageDirectory: coldDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                                  nowProvider: { now }, startClock: false, useBackgroundActivityIO: true)
        defer { coldStore.stop() }
        coldStore.pauseActivityTimerForSleep()
        now = now.addingTimeInterval(3600)
        coldLock.release()
        try await waitUntil("sleep during initial load") { coldStore.activityDataReady && !coldStore.activityReadInProgress }
        try require(coldStore.activityTimers.activeSession?.isPaused == true && coldStore.activityTimers.activeSession?.elapsed(at: now) == 30,
                    "Sleep during a cold read must stay paused when that snapshot arrives")

        var countdownDocument = ActivityTimerDocument()
        try countdownDocument.addActivity(name: "启动时已到时")
        let countdownID = countdownDocument.activities[0].id
        try countdownDocument.start(activityID: countdownID, mode: .countdown, duration: 120, at: now.addingTimeInterval(-900))
        let countdownDirectory = output.appendingPathComponent("background-countdown-\(UUID().uuidString)")
        try ActivityTimerStore(storageURL: countdownDirectory.appendingPathComponent("timers.json")).save(countdownDocument)
        let countdownStore = PlanStore(storageDirectory: countdownDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                                       nowProvider: { now }, startClock: false, useBackgroundActivityIO: true)
        defer { countdownStore.stop() }
        try await waitUntil("expired countdown load") { countdownStore.activityDataReady && !countdownStore.activityReadInProgress }
        try require(countdownStore.timerNotice != nil && countdownStore.activityTimers.total(for: [countdownID], at: now) == 120,
                    "Background startup must restore an expired countdown at its exact deadline")
        try require(countdownStore.countdownCompletionEventID == nil,
                    "An expired timer loaded at startup must not replay its completion effect")
        let extendError = await countdownStore.performActivityAction(.extend)
        try require(extendError == nil, "A loaded reminder must still support an explicit extension")
        now = now.addingTimeInterval(300)
        countdownStore.refresh()
        try await waitUntil("background countdown completion") { !countdownStore.activityReadInProgress }
        let completion = countdownStore.countdownCompletionEventID
        try require(completion != nil && countdownStore.activityTimers.total(for: [countdownID], at: now) == 420,
                    "An extension completed in this app session must emit one completion event")
        countdownStore.refresh()
        try await waitUntil("repeat completion poll") { !countdownStore.activityReadInProgress }
        try require(countdownStore.countdownCompletionEventID == completion, "Repeated background polls must retain a single completion event")
        print("PASS: background cold load, local clock publishing, lock responsiveness/deadline, click timestamps, sleep journal/restart and quit flushing")
    }

    @MainActor
    private static func verifyExperienceFlows(in output: URL) async throws {
        var now = ISO8601DateFormatter().date(from: "2026-11-09T04:10:00Z")!
        let directory = output.appendingPathComponent("experience-\(UUID().uuidString)")
        let writer = ActivityTimerStore(storageURL: directory.appendingPathComponent("timers.json"))
        var document = ActivityTimerDocument()
        for name in ["SQL", "HTTP 与计算机网络", "Python 语言与异步编程 · 任务调度和网络请求练习"] {
            try document.addActivity(name: name)
        }
        let sql = document.activities[0], network = document.activities[1], python = document.activities[2]
        try document.addRecord(activityID: sql.id, startedAt: now.addingTimeInterval(-86400), duration: 3600, at: now)
        try document.addRecord(activityID: network.id, startedAt: now.addingTimeInterval(-3600), duration: 900, at: now)
        try writer.save(document)
        let preferences = SmokeDefaults()
        let malformed = try JSONDecoder().decode(ActivityExperiencePreferences.self, from: Data("{\"range\":-999,\"section\":99,\"timerPreferences\":{\"test\":{\"modeValue\":\"unknown\",\"duration\":1e99}}}".utf8))
        try require(malformed.range == 7 && malformed.section == .timer && malformed.timerPreferences["test"]?.duration == 1500,
                    "Invalid restored preferences must fall back before building ranges or converting durations to integers")
        let store = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false, useBackgroundActivityIO: true)
        defer { store.stop() }
        func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SmokeFailure(description: "Timed out: \(description)") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        func perform(_ action: ActivityTimerAction, _ description: String) async throws {
            let error = await store.performActivityAction(action)
            try require(error == nil, "\(description): \(error ?? "")")
        }
        try await waitUntil("experience initial load") { store.activityDataReady && !store.activityReadInProgress }
        try require(store.activityTimers.activeSession == nil, "Restoring recent projects must never start a timer")
        store.rememberActivityRange(30)
        store.rememberActivitySort(.ascending)
        store.rememberActivitySection(.statistics)
        store.rememberActivitySelection([sql.id, network.id])
        try require(store.activityExperience.selectedActivityIDs == [sql.id, network.id], "The explicit project filter must be remembered")

        let startAt = now
        try await perform(.start(sql.id, .countdown, 120), "Remembered countdown should start")
        now = now.addingTimeInterval(30)
        let switchAt = now
        try await perform(.switchActivity(network.id, .stopwatch, nil), "An explicit switch should commit")
        try require(store.activityTimers.sessions.filter { $0.endedAt == nil }.count == 1, "Switching must retain exactly one active timer")
        try require(store.activityTimers.sessions.first { $0.activityID == sql.id && $0.startedAt == startAt }?.endedAt == switchAt,
                    "The previous timer must end at the requested switch time")
        try require(store.activityTimers.activeSession?.activityID == network.id && store.activityTimers.activeSession?.startedAt == switchAt,
                    "The new timer must begin at that same switch time")
        try require(store.timerPreference(for: sql.id).mode == .countdown && store.timerPreference(for: sql.id).duration == 120,
                    "Per-project parameters must preserve the countdown duration")
        try require(Array(store.recentActivities.map(\.id).prefix(2)) == [network.id, sql.id], "Successful start and switch must update recent order")

        let beforeBlockedArchive = store.activityTimers
        let archiveRunningError = await store.performActivityAction(.archive(network.id, true))
        try require(archiveRunningError != nil && store.activityTimers == beforeBlockedArchive,
                    "Archiving an active timer must not implicitly finish it")
        let sqlTotal = store.activityTimers.total(for: [sql.id], at: now)
        try await perform(.archive(sql.id, true), "A completed project should archive")
        try require(!store.recentActivities.contains { $0.id == sql.id }, "Archived projects must leave recent-start candidates")
        try require(store.activityTimers.total(for: [sql.id], at: now) == sqlTotal, "Archiving must retain the complete historical total")
        let archiveUndo = await store.undoActivityChange()
        try require(archiveUndo == nil && store.activityTimers.activities.first { $0.id == sql.id }?.isArchived == false,
                    "Operation undo must restore an archived project")
        let archiveRedo = await store.redoActivityChange()
        try require(archiveRedo == nil && store.activityTimers.activities.first { $0.id == sql.id }?.isArchived == true,
                    "Operation redo must reapply only the archive field")
        try await perform(.archive(sql.id, false), "An archived project should restore")
        try require(store.activityTimers.activities.first { $0.id == sql.id }?.chartLabel == sql.chartLabel,
                    "Restoring a project must preserve its original visible number")

        try await perform(.archive(python.id, true), "Unused project fixture should archive")
        let beforeBadSwitch = store.activityTimers
        let badSwitchError = await store.performActivityAction(.switchActivity(python.id, .stopwatch, nil))
        try require(badSwitchError != nil && store.activityTimers == beforeBadSwitch,
                    "A switch to an archived target must preserve the entire running state")
        now = now.addingTimeInterval(30)
        try await perform(.finish, "The switched timer should finish")
        let editedID = store.activityTimers.sessions.last!.id
        let rawSegments = store.activityTimers.sessions.last!.segments
        try await perform(.editRecord(editedID, 20, "连接池与请求复用"), "Duration and note should save together")
        let persistedEdit = ActivityTimerStore(storageURL: writer.storageURL).load().sessions.first { $0.id == editedID }
        try require(persistedEdit?.savedDuration == 20 && persistedEdit?.note == "连接池与请求复用",
                    "One committed record edit must persist both fields")
        try require(persistedEdit?.segments == rawSegments, "Editing a record must retain original timer segments")
        let diskBeforeInvalid = try Data(contentsOf: writer.storageURL)
        let invalidEditError = await store.performActivityAction(.editRecord(editedID, 99999, "不应保存的备注"))
        let diskAfterInvalid = try Data(contentsOf: writer.storageURL)
        try require(invalidEditError != nil && diskAfterInvalid == diskBeforeInvalid,
                    "Invalid record edits must never save the note independently")
        let recordUndo = await store.undoActivityChange()
        try require(recordUndo == nil && store.activityTimers.sessions.first { $0.id == editedID }?.note == nil
                    && store.activityTimers.sessions.first { $0.id == editedID }?.correctedDuration == nil,
                    "Undo must restore duration and note as one operation")
        let recordRedo = await store.redoActivityChange()
        try require(recordRedo == nil && store.activityTimers.sessions.first { $0.id == editedID }?.savedDuration == 20,
                    "Redo must restore the combined record edit")
        try await perform(.addNotedRecord(sql.id, now.addingTimeInterval(-7200), 60, "窗口函数练习"), "A noted record should be added")
        let addedID = store.activityTimers.sessions.last!.id
        let undoAfterNewRecord = await store.undoActivityChange()
        try require(undoAfterNewRecord == nil && store.activityTimers.sessions.contains { $0.id == addedID && $0.note == "窗口函数练习" },
                    "Undoing an older field edit must preserve records added afterward")

        try await perform(.rename(sql.id, "SQL · 本地修改"), "Rename should create an undo item")
        _ = try writer.update { try $0.renameActivity(id: sql.id, name: "SQL · 外部较新修改") }
        let conflictingUndo = await store.undoActivityChange()
        try require(conflictingUndo != nil && ActivityTimerStore(storageURL: writer.storageURL).load().activities.first { $0.id == sql.id }?.name == "SQL · 外部较新修改",
                    "Conflicting undo must preserve the newer external field")
        store.refresh()
        try await waitUntil("external rename after undo conflict") { !store.activityReadInProgress }

        try await perform(.delete(network.id), "Deleting a stopped project should save")
        try require(!store.activityExperience.recentActivityIDs.contains(network.id)
                    && store.activityExperience.timerPreferences[network.id.uuidString] == nil
                    && store.activityExperience.selectedActivityIDs?.contains(network.id) == false,
                    "Deleted projects must be removed from recent items, parameter memory and saved filters")
        try await perform(.archive(python.id, false), "Preview project should restore")
        let reloaded = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
                                 nowProvider: { now }, startClock: false, useBackgroundActivityIO: true)
        defer { reloaded.stop() }
        try await waitUntil("experience preference reload") { reloaded.activityDataReady && !reloaded.activityReadInProgress }
        try require(reloaded.activityTimers.activeSession == nil, "Relaunching must not auto-start a recent timer")
        try require(reloaded.activityExperience.range == 30 && reloaded.activityExperience.sortOrder == .ascending
                    && reloaded.activityExperience.section == .statistics,
                    "Range, sort and workspace section must survive a restart")
        try require(reloaded.activityExperience.selectedActivityIDs == [sql.id], "Restart must preserve only still-valid selected projects")
        try require(reloaded.timerPreference(for: sql.id).mode == .countdown && reloaded.timerPreference(for: sql.id).duration == 120,
                    "A restored project must keep its original per-project timer settings")
        try require(reloaded.activityTimers.sessions.first { $0.id == addedID }?.note == "窗口函数练习",
                    "Optional study content must survive restart")

        // Switch persistence and sleep can cross while the UI still displays A.
        try await perform(.start(sql.id, .stopwatch, nil), "Sleep-switch fixture should start")
        try await waitUntil("sleep-switch poll drain") { !store.activityReadInProgress }
        let raceLock = try HeldActivityLock(url: writer.storageURL.appendingPathExtension("lock"))
        now = now.addingTimeInterval(30)
        let switched = Task { @MainActor in await store.performActivityAction(.switchActivity(python.id, .stopwatch, nil)) }
        try await waitUntil("switch waiting on lock") { store.activitySaveInProgress }
        now = now.addingTimeInterval(20)
        store.pauseActivityTimerForSleep()
        now = now.addingTimeInterval(17 * 3600)
        raceLock.release()
        let switchError = await switched.value
        try require(switchError == nil, "Switch queued before sleep must commit atomically")
        store.refresh()
        try await waitUntil("sleep-switch merge") { !store.activityReadInProgress }
        try require(store.activityTimers.activeSession?.activityID == python.id && store.activityTimers.activeSession?.isPaused == true
                    && store.activityTimers.activeSession?.elapsed(at: now) == 20,
                    "The switched successor must exclude overnight sleep")
        let diskRace = ActivityTimerStore(storageURL: writer.storageURL).load()
        try require(diskRace.activeSession?.isPaused == true && diskRace.activeSession?.elapsed(at: now) == 20,
                    "The switched sleep boundary must survive restart")
        try await perform(.finish, "Sleep-switch fixture should finish")

        try verifyChartDateSelection()
        let preview = ActivityWorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 1000), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        preview.activityStore = reloaded
        preview.isReleasedWhenClosed = false
        preview.contentView = NSHostingView(rootView: ActivityTimersView(store: reloaded, initialSection: 1))
        preview.orderFront(nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        try writePreview(preview, to: output.appendingPathComponent("experience-statistics.png"))
        func nativeFields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { nativeFields($0) }
        }
        if let search = nativeFields(preview.contentView!).first(where: { $0.placeholderString == L("查找项目（不改变统计筛选）") }),
           preview.makeFirstResponder(search), let editor = search.currentEditor() as? NSTextView {
            let selectionBefore = reloaded.activityExperience.selectedActivityIDs
            editor.selectAll(nil)
            editor.insertText("SQL", replacementRange: editor.selectedRange())
            try await Task.sleep(nanoseconds: 50_000_000)
            try require(editor.string == "SQL" && preview.firstResponder === editor, "Native search typing must retain its field editor")
            editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            for _ in 0..<5 { now = now.addingTimeInterval(1); reloaded.refresh(); try await Task.sleep(nanoseconds: 25_000_000) }
            try require(editor.hasMarkedText() && preview.firstResponder === editor,
                        "Clock and background updates must preserve native marked-text composition and focus")
            editor.unmarkText()
            editor.selectAll(nil); editor.insertText("SQL", replacementRange: editor.selectedRange())
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(reloaded.activityExperience.selectedActivityIDs == selectionBefore,
                        "Typing a project query must not alter the statistics filter")
            try writePreview(preview, to: output.appendingPathComponent("experience-project-search.png"))
            editor.selectAll(nil); editor.insertText("", replacementRange: editor.selectedRange())
            _ = preview.makeFirstResponder(nil)
        } else {
            print("SKIP: native field editor search/composition check could not find an editable AppKit field")
        }
        if let pointer = descendant(of: preview.contentView!, whoseClassContains: "ActivityChartPointerView") as? ActivityChartPointerView {
            let local = CGPoint(x: pointer.plot.maxX - 3, y: pointer.plot.midY)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: pointer.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                                           windowNumber: preview.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            pointer.mouseDown(with: event)
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(pointer.accessibilityValue() as? String == Calendar.current.startOfDay(for: reloaded.now).formatted(date: .abbreviated, time: .omitted),
                        "A mounted chart must retain the clicked date after SwiftUI updates")
            if let scroll = descendantScrollView(in: preview.contentView!) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 470)); scroll.reflectScrolledClipView(scroll.contentView)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            try writePreview(preview, to: output.appendingPathComponent("experience-day-details.png"))
        } else { throw SmokeFailure(description: "Statistics tab must mount a selectable native chart") }
        preview.contentView = NSHostingView(rootView: ActivityTimersView(store: reloaded, initialSection: 2))
        try await Task.sleep(nanoseconds: 250_000_000)
        try writePreview(preview, to: output.appendingPathComponent("experience-records.png"))
        let originalName = reloaded.activityTimers.activities.first { $0.id == sql.id }!.name
        let renameForMenu = await reloaded.performActivityAction(.rename(sql.id, "快捷键撤销测试"))
        try require(renameForMenu == nil, "Native menu fixture rename should save")
        let undoItem = NSMenuItem(title: "", action: #selector(ActivityWorkspaceWindow.undo(_:)), keyEquivalent: "z")
        try require(preview.validateMenuItem(undoItem) && undoItem.title == reloaded.activityUndoTitle,
                    "The native Undo menu must describe the actual operation")
        preview.undo(nil)
        try await waitUntil("native menu undo") { reloaded.activityTimers.activities.first { $0.id == sql.id }?.name == originalName }
        try require(reloaded.activityRedoTitle != nil, "Native Undo must use the operation-specific history")
        let textEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        textEditor.allowsUndo = true
        preview.contentView = textEditor
        _ = preview.makeFirstResponder(textEditor)
        textEditor.insertText("中文草稿", replacementRange: NSRange(location: 0, length: 0))
        textEditor.breakUndoCoalescing()
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(textEditor.undoManager?.canUndo == true, "The field editor should own its text undo")
        let textUndo = textEditor.tryToPerform(#selector(ActivityWorkspaceWindow.undo(_:)), with: nil)
        try require(textUndo && textEditor.string.isEmpty && reloaded.activityTimers.activities.first { $0.id == sql.id }?.name == originalName,
                    "Text Undo must edit the draft without undoing an application record")
        preview.close()
        var many = ActivityTimerDocument()
        for index in 1...50 {
            try many.addActivity(name: "课题 \(index)")
            try many.addRecord(activityID: many.activities.last!.id, startedAt: now.addingTimeInterval(-86400 - Double(index * 60)), duration: Double(30 + index * 30), at: now)
        }
        let manyDirectory = output.appendingPathComponent("experience-many-\(UUID().uuidString)")
        try ActivityTimerStore(storageURL: manyDirectory.appendingPathComponent("timers.json")).save(many)
        let manyStore = PlanStore(storageDirectory: manyDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                                  nowProvider: { now }, startClock: false, useBackgroundActivityIO: true)
        defer { manyStore.stop() }
        try await waitUntil("50 project load") { manyStore.activityDataReady && !manyStore.activityReadInProgress }
        let manyWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 1000), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        manyWindow.isReleasedWhenClosed = false
        manyWindow.contentView = NSHostingView(rootView: ActivityTimersView(store: manyStore, initialSection: 1))
        manyWindow.orderFront(nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        guard let manyPointer = descendant(of: manyWindow.contentView!, whoseClassContains: "ActivityChartPointerView") as? ActivityChartPointerView else {
            throw SmokeFailure(description: "A 50-project statistics page must mount its chart")
        }
        try require(manyPointer.regions.count == 50, "Collapsing a dense legend must not omit any chart data")
        try writePreview(manyWindow, to: output.appendingPathComponent("experience-50-projects.png"))
        if let search = nativeFields(manyWindow.contentView!).first(where: { $0.placeholderString == L("查找项目（不改变统计筛选）") }),
           manyWindow.makeFirstResponder(search), let editor = search.currentEditor() as? NSTextView {
            editor.selectAll(nil); editor.insertText("课题 50", replacementRange: editor.selectedRange())
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(manyStore.activityExperience.selectedActivityIDs?.count == 50,
                        "Looking up one project among fifty must keep all selected until explicit focus")
            func nativeButtons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { nativeButtons($0) }
            }
            if let only = nativeButtons(manyWindow.contentView!).first(where: { $0.title == L("只看此项目") }) {
                only.performClick(nil)
                try await waitUntil("project focus button") { manyStore.activityExperience.selectedActivityIDs == [many.activities.last!.id] }
                try require(manyPointer.regions.count == 1, "The explicit focus button must show only the chosen project's chart")
            } else {
                // SwiftUI can draw a button without an NSButton backing view.
                // Post native window events into this isolated application's
                // event queue, using the rendered candidate row's position.
                manyWindow.makeKeyAndOrderFront(nil)
                let field = search.convert(search.bounds, to: nil)
                let point = NSPoint(x: manyWindow.contentView!.bounds.maxX - 68, y: field.minY - 55)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: manyWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    NSApp.postEvent(event, atStart: false)
                }
                try await waitUntil("SwiftUI project focus click") { manyStore.activityExperience.selectedActivityIDs == [many.activities.last!.id] }
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(manyPointer.regions.count == 1, "A native window click on Focus must update the chart and saved filter together")
            }
            try writePreview(manyWindow, to: output.appendingPathComponent("experience-50-project-search.png"))
        } else { print("SKIP: 50-project native search field is unavailable in this session") }
        manyWindow.close()
        print("PASS: production background experience flow, parameter/recent memory, archive/restore, atomic switch, combined record edits, scoped undo/conflicts, restart and date selection")
    }

    @MainActor
    private static func verifyChartDateSelection() throws {
        let view = ActivityChartPointerView(frame: NSRect(x: 0, y: 0, width: 720, height: 300))
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_793_760_000))
        let end = calendar.date(byAdding: .day, value: 7, to: first)!
        let plot = CGRect(x: 10, y: 10, width: 700, height: 210)
        var selected: [Date] = []
        view.configure(regions: [], plot: plot, dateRange: first...end, onSelectDay: { selected.append($0) }, onHover: { _ in })
        func click(_ x: CGFloat, _ y: CGFloat) {
            let location = view.convert(CGPoint(x: x, y: y), to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            view.mouseDown(with: event)
        }
        click(60, 100)
        try require(selected.last == first, "An empty first column must still select its date")
        click(360, 280)
        try require(selected.last == calendar.date(byAdding: .day, value: 3, to: first), "Clicking the date-axis area must select its day")
        click(710, 100)
        try require(selected.last == calendar.date(byAdding: .day, value: 6, to: first), "The plot's right edge must select its last in-range day")
        let count = selected.count
        click(0, 100); click(60, 0)
        try require(selected.count == count, "Clicks beside the plot or above it must not change the selected date")
        let left = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        view.keyDown(with: left)
        try require(selected.last == calendar.date(byAdding: .day, value: 5, to: first), "A keyboard arrow must move one calendar day")
        for _ in 0..<20 { view.keyDown(with: left) }
        try require(selected.last == first, "Keyboard date navigation must remain inside the chart domain")
        try require(view.acceptsFirstResponder && view.accessibilityCustomActions()?.count == 3,
                    "Selectable charts must provide keyboard focus and assistive date actions")
        view.configure(regions: [], plot: plot, onHover: { _ in })
        let disabledCount = selected.count
        click(60, 100)
        try require(!view.acceptsFirstResponder && selected.count == disabledCount, "Preview-only charts must keep their previous non-selecting behavior")
    }

    @MainActor
    private static func verifyPersistence(in output: URL) throws {
        let directory = output.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plan.json")
        try Data("[]".utf8).write(to: url)
        let preferences = SmokeDefaults()
        let store = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false)
        defer { store.stop() }
        try require(store.tasks.isEmpty, "Empty JSON plan should remain empty")
        let migrated = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: url))
        try require(migrated.tasks.isEmpty && migrated.history.count == 1, "Legacy task array should migrate with today's empty record")
        try require(store.compactSize == PlanStore.defaultCompactSize, "Compact square should default to 56 points")
        try require(!store.isExpanded, "Detail visibility should not be restored across launches")

        let first = PlanTask(startMinutes: 540, endMinutes: 600, title: "  任务一  ", details: " 测试内容 ")
        let second = PlanTask(startMinutes: 600, endMinutes: 660, title: "任务二", details: "相邻时间段")
        try require(store.saveTask(second) == nil, "Adding a task failed")
        try require(store.saveTask(first) == nil, "Adding an adjacent task failed")
        try require(store.tasks.map(\.startMinutes) == [540, 600], "Plan must remain sorted")
        try require(store.tasks.first?.title == "任务一", "Task title should trim surrounding whitespace")
        try require(store.todayProgress.totalCount == 2 && store.todayProgress.completedCount == 0, "Today's progress should track saved tasks")
        try require(store.toggleTaskCompletion(id: first.id) == nil, "Marking today's task complete failed")
        try require(store.isTaskCompleted(first.id) && store.todayProgress.completedCount == 1, "Completion did not update immediately")
        let beforeConflict = try Data(contentsOf: url)
        let conflict = PlanTask(startMinutes: 570, endMinutes: 630, title: "冲突任务", details: "")
        try require(store.saveTask(conflict) != nil, "Overlapping task should be rejected")
        try require(try Data(contentsOf: url) == beforeConflict, "Rejected edits must not change the JSON file")
        let invalid = PlanTask(startMinutes: 700, endMinutes: 690, title: "结束过早", details: "")
        try require(store.saveTask(invalid) != nil, "End-before-start should be rejected")
        try require(store.tasks.count == 2, "Rejected edits must not change the published plan")
        store.alwaysOnTop = false
        store.compactSize = 74
        store.setExpanded(true)

        let reloaded = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false)
        defer { reloaded.stop() }
        try require(reloaded.tasks == store.tasks, "JSON plan did not survive reloading")
        try require(reloaded.isTaskCompleted(first.id), "Completion did not survive reloading")
        try require(!reloaded.alwaysOnTop, "Preferences did not survive reloading")
        try require(reloaded.compactSize == 74, "Compact square size did not survive reloading")
        try require(!reloaded.isExpanded, "A reopened app should start with its detail panel hidden")
        reloaded.compactSize = 1
        try require(reloaded.compactSize == PlanStore.compactSizeRange.lowerBound, "Compact size should clamp to its minimum")
        reloaded.compactSize = 1000
        try require(reloaded.compactSize == PlanStore.compactSizeRange.upperBound, "Compact size should clamp to its maximum")
        reloaded.compactSize = .nan
        try require(reloaded.compactSize == PlanStore.defaultCompactSize, "NaN square sizes must recover to the default")
        reloaded.compactSize = .infinity
        try require(reloaded.compactSize == PlanStore.defaultCompactSize, "Infinite square sizes must recover to the default")
        try require(reloaded.deleteTask(id: second.id) == nil, "Deleting a task failed")
        let persisted = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: url))
        try require(persisted.tasks.count == 1 && persisted.tasks.first?.id == first.id, "Deleted task remained in JSON")
        try require(persisted.history.first?.completedCount == 1 && persisted.history.first?.totalCount == 1, "Completion should survive plan edits by task ID")

        let rolloverDirectory = output.appendingPathComponent("rollover-\(UUID().uuidString)", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var simulatedNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 59))!
        let rollover = PlanStore(
            storageDirectory: rolloverDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
            nowProvider: { simulatedNow }, calendarProvider: { calendar }, startClock: false
        )
        defer { rollover.stop() }
        let completedID = rollover.tasks[0].id
        try require(rollover.toggleTaskCompletion(id: completedID) == nil, "Completion before midnight failed")
        let yesterday = rollover.todayProgress
        simulatedNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 1))!
        rollover.refresh()
        try require(rollover.todayProgress.day != yesterday.day && rollover.todayProgress.completedCount == 0, "A new local day should reset completion")
        try require(rollover.history.first(where: { $0.day == yesterday.day })?.completedCount == 1, "Midnight rollover should preserve yesterday's result")
        let editedToday = PlanTask(startMinutes: 540, endMinutes: 600, title: "今日新增", details: "历史保持原样")
        let revised = try PlanEditing.replacingConflicts(with: editedToday, in: rollover.tasks)
        try require(rollover.replaceTasks(revised) == nil, "Confirmed conflict replacement should commit in one save")
        try require(rollover.tasks.contains(where: { $0.id == editedToday.id }), "The replacement task did not enter today's plan")
        try require(rollover.history.first(where: { $0.day == yesterday.day }) == yesterday, "Editing today's plan should not rewrite yesterday")
        let savedRevision = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: rollover.storageURL))
        try require(savedRevision.tasks == rollover.tasks && savedRevision.history == rollover.history, "Conflict replacement and progress must persist together")
        let rolloverReloaded = PlanStore(
            storageDirectory: rolloverDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
            nowProvider: { simulatedNow }, calendarProvider: { calendar }, startClock: false
        )
        defer { rolloverReloaded.stop() }
        try require(rolloverReloaded.history.first(where: { $0.day == yesterday.day })?.completedCount == 1, "Historical completion did not survive relaunch")

        let damagedDirectory = output.appendingPathComponent("corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        let damagedURL = damagedDirectory.appendingPathComponent("plan.json")
        let damaged = Data("{this is a broken plan".utf8)
        try damaged.write(to: damagedURL)
        let recovered = PlanStore(storageDirectory: damagedDirectory, defaults: SmokeDefaults(), allowsLoginItemChanges: false)
        defer { recovered.stop() }
        try require(recovered.errorMessage != nil, "Damaged JSON should produce a visible warning")
        try require(recovered.tasks.count == DefaultPlan.tasks.count, "Damaged JSON should use the default plan")
        try require(try Data(contentsOf: damagedURL) == damaged, "Damaged original must remain unchanged until an edit")
        let backups = try FileManager.default.contentsOfDirectory(at: damagedDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("plan.corrupt-") }
        try require(backups.count == 1, "Damaged JSON was not backed up")
        try require(try Data(contentsOf: backups[0]) == damaged, "Backup must preserve the original bytes")
        try require(recovered.needsDataRecovery, "A damaged file must require explicit recovery")
        try require(recovered.deleteTask(id: recovered.tasks[0].id) != nil, "Damaged data should block ordinary edits")
        try require(try Data(contentsOf: damagedURL) == damaged, "Blocked edits must not replace the damaged original")
        try require(recovered.recoverWithDefaultPlan() == nil, "Explicit recovery should save a fresh default plan")
        try require(!recovered.needsDataRecovery, "Recovery should clear the blocked state")
        _ = try JSONDecoder().decode(ProgressDocument.self, from: Data(contentsOf: damagedURL))
        print("PASS: migration, completion/reload, rollover history, rejected edits, compact size, explicit damaged-file recovery")
    }

    @MainActor
    private static func verifyQuoteRefresh(in output: URL) throws {
        try require(QuoteRotation.refreshInterval == 3_600, "Quotes should refresh every hour")
        try require(MotivationalQuote.all.allSatisfy { !$0.explanation.isEmpty && !$0.source.isEmpty }, "Every quote needs an explanation and source")
        let randomPreferences = SmokeDefaults()
        var draws = [15, 2, 11].makeIterator()
        let randomRotation = QuoteRotation(defaults: randomPreferences) { _ in draws.next()! }
        let randomStart = Date(timeIntervalSince1970: 1_792_886_400)
        try require(randomRotation.quote(at: randomStart) == MotivationalQuote.all[15], "First quote should use the random selection")
        try require(randomRotation.quote(at: randomStart.addingTimeInterval(3_600)) == MotivationalQuote.all[2], "Hourly selection should jump backward when randomly selected")
        try require(randomRotation.quote(at: randomStart.addingTimeInterval(7_200)) == MotivationalQuote.all[12], "Hourly selection should jump forward without catalog ordering")
        let oldPreferences = SmokeDefaults()
        oldPreferences.set(["id": MotivationalQuote.all[7].id, "selectedAt": randomStart], forKey: QuoteRotation.cacheKey)
        let migratedQuote = QuoteRotation(defaults: oldPreferences, chooseIndex: { _ in 3 })
            .quote(at: randomStart.addingTimeInterval(7_200))
        try require(migratedQuote == MotivationalQuote.all[3], "An existing six-hour cache must immediately use the shorter deadline")
        let directory = output.appendingPathComponent("quotes-\(UUID().uuidString)", isDirectory: true)
        let preferences = SmokeDefaults()
        let start = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!
        var now = start
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let store = PlanStore(
            storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
            nowProvider: { now }, calendarProvider: { calendar }, startClock: false
        )
        defer { store.stop() }
        let initialQuote = store.motivationalQuote
        let savedPlan = try Data(contentsOf: store.storageURL)
        try require(MotivationalQuote.all.contains(initialQuote), "The widget should start with a bundled motivational quote")

        now = start.addingTimeInterval(QuoteRotation.refreshInterval - 1)
        store.refresh()
        try require(store.motivationalQuote == initialQuote, "The quote must remain stable before one hour")

        now = start.addingTimeInterval(QuoteRotation.refreshInterval)
        store.refresh()
        let refreshedQuote = store.motivationalQuote
        try require(refreshedQuote != initialQuote, "The quote must change exactly when one hour have elapsed")
        try require(try Data(contentsOf: store.storageURL) == savedPlan, "Quote updates must not rewrite the task or completion data")
        store.refresh()
        try require(store.motivationalQuote == refreshedQuote, "Repeated refreshes must preserve the new quote")

        let reloaded = PlanStore(
            storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
            nowProvider: { now }, calendarProvider: { calendar }, startClock: false
        )
        defer { reloaded.stop() }
        try require(reloaded.motivationalQuote == refreshedQuote, "The quote must survive relaunch within its one-hour interval")
        now = now.addingTimeInterval(3 * QuoteRotation.refreshInterval)
        reloaded.refresh()
        try require(reloaded.motivationalQuote != refreshedQuote, "Waking after multiple intervals must refresh the quote")
        let afterWake = reloaded.motivationalQuote
        reloaded.refresh()
        try require(reloaded.motivationalQuote == afterWake, "A long sleep should trigger only one quote refresh")
        print("PASS: one-hour quotes, stable hover/relaunch, wake catch-up, unchanged plan data")
    }

    @MainActor
    private static func verifyActivityTimers(in output: URL) throws {
        let directory = output.appendingPathComponent("timers-\(UUID().uuidString)")
        let start = ISO8601DateFormatter().date(from: "2026-10-31T15:59:00Z")!
        var now = start
        let preferences = SmokeDefaults()
        let store = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        defer { store.stop() }
        try require(store.addTimedActivity(name: "  阅读  ") == nil, "Adding a named activity should save")
        let id = store.activityTimers.activities[0].id
        try require(store.activityTimers.activities[0].name == "阅读", "Activity names should trim whitespace")
        try require(store.startActivityTimer(activityID: id, mode: .countdown, duration: 120) == nil, "Countdown should start")
        now = start.addingTimeInterval(30)
        try require(store.toggleActivityTimerPause() == nil, "Timer should pause")
        now = start.addingTimeInterval(300)
        store.refresh()
        try require(store.activityTimers.activeSession?.remaining(at: now) == 90, "Paused countdown must not advance")
        let reloaded = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
                                 nowProvider: { now }, startClock: false)
        defer { reloaded.stop() }
        try require(reloaded.activityTimers == store.activityTimers, "Paused timer must survive restart")
        try require(store.toggleActivityTimerPause() == nil, "Timer should resume")
        let timersURL = directory.appendingPathComponent("timers.json")
        let savedTimer = try Data(contentsOf: timersURL)
        try FileManager.default.removeItem(at: timersURL)
        try FileManager.default.createDirectory(at: timersURL, withIntermediateDirectories: true)
        let before = store.activityTimers
        try require(store.finishActivityTimer() != nil && store.activityTimers == before, "Failed save must not discard an active session")
        now = start.addingTimeInterval(1000)
        store.refresh()
        try require(store.activityTimerError != nil && store.activityTimers.activeSession != nil, "Countdown completion should retry after a failed write")
        try FileManager.default.removeItem(at: timersURL)
        try savedTimer.write(to: timersURL)
        store.refresh()
        try require(store.activityTimers.activeSession == nil, "Refresh should complete countdown after storage recovers")
        try require(store.activityTimers.sessions[0].savedDuration == 120, "Sleep and retry must never overcount target duration")
        try require(store.timerNotice != nil, "Countdown completion should display a notice")
        try require(store.activityTimerError == nil, "Successful retry should clear the timer storage error")
        try require(store.activityTimers.sessions[0].endedAt == start.addingTimeInterval(390), "Countdown should end at its real deadline")
        let completedData = try Data(contentsOf: timersURL)
        store.refresh()
        try require(try Data(contentsOf: timersURL) == completedData, "Completed timer should be recorded only once")
        // A separate same-day instance proves timer operations alone leave the plan file untouched.
        let currentPlanData = try Data(contentsOf: store.storageURL)
        try require(store.startActivityTimer(activityID: id, mode: .stopwatch, duration: nil) == nil, "Stopwatch should start after countdown")
        now = now.addingTimeInterval(45)
        let runningReload = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
                                      nowProvider: { now }, startClock: false)
        defer { runningReload.stop() }
        try require(runningReload.activityTimers.activeSession?.elapsed(at: now) == 45, "Running stopwatch should survive restart")
        try require(store.finishActivityTimer() == nil, "Stopwatch should finish")
        try require(store.activityTimers.total(for: [id], at: now) == 165, "Repeated sessions must accumulate under one activity")
        try require(try Data(contentsOf: store.storageURL) == currentPlanData, "Timer operations should not change plan data")
        try require(store.renameTimedActivity(id: id, name: "阅读书籍") == nil, "Renaming should save")
        try require(store.activityTimers.total(for: [id], at: now) == 165, "Renaming must retain accumulated time")
        try require(store.addTimedActivity(name: "误输事项") == nil, "A second activity should save")
        let otherID = store.activityTimers.activities.last!.id
        try require(store.startActivityTimer(activityID: otherID, mode: .stopwatch, duration: nil) == nil, "Second activity should start")
        let beforeDelete = store.activityTimers
        let beforeDeleteData = try Data(contentsOf: timersURL)
        try FileManager.default.removeItem(at: timersURL)
        try FileManager.default.createDirectory(at: timersURL, withIntermediateDirectories: true)
        try require(store.deleteTimedActivity(id: otherID) != nil, "Deletion must report save failures")
        try require(store.activityTimers == beforeDelete, "A failed deletion must preserve the activity, records and active timer")
        try require(store.renameTimedActivity(id: id, name: "不应保存") != nil, "Rename must report save failures")
        try require(store.activityTimers == beforeDelete, "A failed rename must preserve names and records")
        try FileManager.default.removeItem(at: timersURL)
        try beforeDeleteData.write(to: timersURL)
        try require(store.deleteTimedActivity(id: otherID) == nil, "Deletion should save after storage recovers")
        try require(store.activityTimers.activeSession == nil, "Deleting an active activity should remove its timer")
        try require(store.activityTimers.activities.count == 1 && store.activityTimers.sessions.count == 2, "Deletion must preserve other activities and records")
        let managementReload = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
                                         nowProvider: { now }, startClock: false)
        defer { managementReload.stop() }
        try require(managementReload.activityTimers == store.activityTimers, "Rename and deletion should survive restart")
        try require(try Data(contentsOf: store.storageURL) == currentPlanData, "Managing activities must not change the plan")
        try require(store.startActivityTimer(activityID: id, mode: .countdown, duration: 1) == nil, "Quiet countdown should start")
        now = now.addingTimeInterval(1)
        store.refresh()
        let eventID = store.countdownCompletionEventID
        try require(eventID != nil && store.activityTimers.displayedSession?.id == eventID, "Expired countdown must remain displayed")
        now = now.addingTimeInterval(600)
        store.refresh()
        try require(store.countdownCompletionEventID == eventID, "Repeated refresh must not repeat the completion event")
        try require(store.addTimedActivity(name: "新事项") == nil && store.timerNotice != nil, "Adding an activity must preserve the reminder")
        let quietReload = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
                                    nowProvider: { now }, startClock: false)
        defer { quietReload.stop() }
        try require(quietReload.timerNotice != nil && quietReload.countdownCompletionEventID == nil, "Saved reminder must survive restart without replaying its animation")
        try require(quietReload.renameTimedActivity(id: id, name: "读书") == nil && quietReload.countdownCompletionEventID == nil, "Editing an activity must not replay a saved reminder")
        let reminderData = try Data(contentsOf: timersURL)
        let reminder = quietReload.activityTimers
        try FileManager.default.removeItem(at: timersURL)
        try FileManager.default.createDirectory(at: timersURL, withIntermediateDirectories: true)
        try require(quietReload.extendActivityCountdown() != nil, "Failed extension must report a save error")
        try require(quietReload.finishActivityTimer() != nil && quietReload.activityTimers == reminder, "Failed completion must preserve the reminder and records")
        try FileManager.default.removeItem(at: timersURL)
        try reminderData.write(to: timersURL)
        try require(quietReload.extendActivityCountdown() == nil, "Extension should recover after storage is restored")
        try require(quietReload.activityTimers.activeSession?.remaining(at: now) == 300, "Extension must start five minutes at click time")
        try require(quietReload.activityTimers.total(for: [id], at: now) == 166, "Waiting for a response must not count toward statistics")
        now = now.addingTimeInterval(300)
        quietReload.refresh()
        try require(quietReload.countdownCompletionEventID != eventID && quietReload.timerNotice != nil, "Extended countdown should have its own completion event")
        try require(quietReload.finishActivityTimer() == nil && quietReload.activityTimers.displayedSession == nil, "Acknowledgement must restore the schedule display")
        try require(quietReload.activityTimers.total(for: [id], at: now) == 466, "Extension must accumulate under the original activity")
        print("PASS: activity timer pause, resume, restart, countdown deadline, storage retry and cumulative totals")
        print("PASS: persistent quiet reminders, one-time completion events, extension, acknowledgement and failed-action recovery")
    }

    @MainActor
    private static func verifySleepAndStudyRecords(in output: URL) throws {
        let directory = output.appendingPathComponent("study-regressions-\(UUID().uuidString)")
        let start = ISO8601DateFormatter().date(from: "2026-11-06T14:30:00Z")!
        var now = start
        let preferences = SmokeDefaults()
        let store = PlanStore(storageDirectory: directory, defaults: preferences, allowsLoginItemChanges: false,
                              nowProvider: { now }, useBackgroundActivityIO: false)
        defer { store.stop() }
        try require(store.addTimedActivity(name: "SQL") == nil, "Initial project should save")
        let sqlID = store.activityTimers.activities[0].id
        let stale = PlanStore(storageDirectory: directory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        defer { stale.stop() }
        try require(store.addTimedActivity(name: "cpc") == nil, "New cpc project should save")
        let cpcID = store.activityTimers.activities.last!.id
        try require(store.startActivityTimer(activityID: cpcID, mode: .stopwatch, duration: nil) == nil, "Cpc stopwatch should start")
        now = start.addingTimeInterval(90)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try require(store.activityTimers.activeSession?.isPaused == true, "willSleep must synchronously pause the timer")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        now = start.addingTimeInterval(17 * 3600)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try require(store.activityTimers.activeSession?.isPaused == true, "Wake must keep the timer paused until explicit resume")
        try require(store.activityTimers.total(for: [cpcID], at: now) == 90, "Overnight sleep must not enter study statistics")
        try require(stale.renameTimedActivity(id: sqlID, name: "数据库") == nil, "A stale window should safely apply its edit")
        try require(stale.activityTimers.activities.contains { $0.id == cpcID }, "Stale saves must retain newly created projects")
        store.refresh()
        try require(store.activityTimers.activities[0].name == "数据库", "Refresh must synchronize other windows' changes")
        try require(store.finishActivityTimer() == nil, "A paused overnight timer should finish")
        let sessionID = store.activityTimers.sessions.last!.id
        try require(store.correctActivityDuration(sessionID: sessionID, duration: 60) == nil, "Study duration correction should save")
        try require(store.activityTimers.total(for: [cpcID], at: now) == 60, "Correction must update totals immediately")
        let reloaded = PlanStore(storageDirectory: directory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                                 nowProvider: { now }, startClock: false)
        defer { reloaded.stop() }
        try require(reloaded.activityTimers == store.activityTimers, "Corrected record and project colors must survive restart")
        let url = directory.appendingPathComponent("timers.json")
        let data = try Data(contentsOf: url)
        let before = store.activityTimers
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try require(store.correctActivityDuration(sessionID: sessionID, duration: 30) != nil, "A failed correction must be reported")
        try require(store.activityTimers == before, "A failed correction must preserve displayed and original durations")
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)
        try require(store.correctActivityDuration(sessionID: sessionID, duration: 90) == nil, "Original duration should be restorable")

        // A storage failure at sleep is retried at the original sleep boundary.
        try require(store.startActivityTimer(activityID: sqlID, mode: .countdown, duration: 1800) == nil, "Sleep countdown should start")
        now = now.addingTimeInterval(60)
        let running = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try require(store.activityTimerError != nil, "A failed sleep save must surface an error")
        try require(store.activityTimers.activeSession?.isPaused == true, "Even a failed disk write must leave the visible timer paused")
        now = now.addingTimeInterval(17 * 3600)
        try FileManager.default.removeItem(at: url)
        try running.write(to: url)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try require(store.activityTimers.activeSession?.isPaused == true, "Sleep pause should retry after storage recovers")
        try require(store.activityTimers.activeSession?.elapsed(at: now) == 60, "Retry must use sleep time, not wake time")
        try require(store.activityTimerError == nil, "A successful sleep retry should clear the error")
        try require(store.toggleActivityTimerPause() == nil, "Wake requires explicit resume")
        now = now.addingTimeInterval(30)
        try require(store.finishActivityTimer() == nil, "Resumed countdown should finish")
        try require(store.activityTimers.total(for: [sqlID], at: now) == 90, "Only awake active stretches should accumulate")

        // Reproduce the original long-running finish path independently of sleep.
        try require(store.startActivityTimer(activityID: cpcID, mode: .stopwatch, duration: nil) == nil, "Long stopwatch should start")
        now = now.addingTimeInterval(17 * 3600)
        try require(store.finishActivityTimer() == nil, "17-hour stopwatch should finish and persist")
        let completed = store.activityTimers.sessions.last!
        try require(completed.savedDuration == 61_200, "Long stopwatch must not be capped or dropped")
        try require(store.correctActivityDuration(sessionID: completed.id, duration: 5400) == nil, "Forgotten timer should correct to 90 minutes")
        try require(stale.renameTimedActivity(id: cpcID, name: "CPC") == nil, "Stale edits must preserve a completed correction")
        try require(stale.activityTimers.total(for: [cpcID], at: now) == 5490, "Stale instance must not restore old totals")
        try require(store.addActivityRecord(activityID: cpcID, startedAt: now.addingTimeInterval(-600), duration: 300) == nil, "A missing session can be added manually")
        try require(store.activityTimers.total(for: [cpcID], at: now) == 5790, "Manual records must enter totals")
        print("PASS: sleep/wake notification path, overnight finish, stale windows, duration edits, missing records and write recovery")
    }

    @MainActor
    private static func verifyStudyChartHover(in output: URL) throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-08T10:00:00Z")!
        let directory = output.appendingPathComponent("chart-hover-\(UUID().uuidString)")
        let store = PlanStore(storageDirectory: directory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        let configuration = StudyChartConfiguration()
        let names = ["SQL", "测试", "Python 语言与异步编程 · 服务端任务调度和网络请求练习", "HTTP 与计算机网络",
                     "学习", "cpc", "阅读", "算法", "数据库原理", "操作系统", "系统设计", "英语"]
        let today = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        for index in 0..<8 {
            try require(store.addTimedActivity(name: names[index]) == nil, "Hover fixture project should save")
            try require(store.addActivityRecord(activityID: store.activityTimers.activities.last!.id,
                                               startedAt: yesterday, duration: index == 7 ? 1 : Double(900 + index * 120)) == nil,
                        "Hover fixture record should save")
        }
        let sql = store.activityTimers.activities[0]
        try require(store.addActivityRecord(activityID: sql.id, startedAt: yesterday.addingTimeInterval(-86400), duration: 600) == nil,
                    "A second day's record should save")
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 840, height: 300),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StudyChartPreview(store: store, configuration: configuration))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); store.stop(); AppLanguage.current = .chinese }
        pumpEvents(for: 0.3)
        guard let pointer = descendant(of: window.contentView!, whoseClassContains: "ActivityChartPointerView") as? ActivityChartPointerView else {
            throw SmokeFailure(description: "Daily chart must install its pointer tracking overlay")
        }
        pointer.updateTrackingAreas()
        try require(window.acceptsMouseMovedEvents, "The chart window must distribute mouse-moved events")
        try require(pointer.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.inVisibleRect) },
                    "The chart must track pointer movement in its visible area")

        func move(to location: CGPoint) throws {
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: pointer.convert(location, to: nil),
                                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 0, pressure: 0) else {
                throw SmokeFailure(description: "Unable to create chart pointer event")
            }
            // Synthetic window events do not carry AppKit's tracking-area dispatch.
            // Deliver to the installed area's owner, the same entry point used by AppKit.
            guard let owner = pointer.trackingAreas.first(where: { $0.options.contains(.mouseMoved) })?.owner as? NSResponder else {
                throw SmokeFailure(description: "Chart tracking area must have an event responder")
            }
            owner.mouseMoved(with: event)
            pumpEvents(for: 0.03)
        }

        func hover(_ region: ActivityChartRegion) throws {
            try move(to: CGPoint(x: region.frame.midX, y: region.frame.midY))
            try require(pointer.accessibilityHelp() == region.detail, "Hover must show exactly this block's project, date and duration: \(region.detail)")
        }

        try require(pointer.regions.count == 9, "Zero-duration days must not create hover regions")
        for region in pointer.regions { try hover(region) }
        let steady = pointer.regions.first { $0.frame.height >= 16 }!
        try hover(steady)
        let changes = pointer.hoverChangeCount
        let indexBuilds = pointer.hitIndexBuildCount
        for index in 0..<100 {
            let offset = CGFloat(index % 10) / 20
            try move(to: CGPoint(x: steady.frame.midX + offset, y: steady.frame.midY))
        }
        try require(pointer.hoverChangeCount == changes, "Moving inside one block must not repeatedly redraw the tooltip")
        try require(pointer.hitIndexBuildCount == indexBuilds, "Hovering must reuse the geometry and hit index")
        let thin = pointer.regions.first { $0.segment.point.duration == 1 }!
        try require(thin.frame.height < 1, "The fixture must include a subpixel-height record")
        try hover(thin)
        let first = pointer.regions.first!
        try move(to: CGPoint(x: first.frame.minX - 6, y: first.frame.midY))
        try require(pointer.accessibilityHelp() == nil, "The gap beside a bar must not show a project")
        try move(to: CGPoint(x: first.frame.minX - 2, y: first.frame.midY))
        try require(pointer.accessibilityHelp() == first.detail, "A small horizontal tolerance should make narrow bars easier to hit")
        try move(to: CGPoint(x: first.frame.midX, y: first.frame.maxY + 2))
        try require(pointer.accessibilityHelp() == nil, "Axes and the area below bars must not show a project")
        let stack = pointer.regions.filter { $0.segment.point.day == yesterday }.sorted { $0.segment.lowerBound < $1.segment.lowerBound }
        try move(to: CGPoint(x: stack[0].frame.midX, y: stack[0].frame.minY - 0.01))
        try require(pointer.accessibilityHelp() == stack[1].detail, "Crossing a stack boundary must immediately identify the next project")
        try move(to: CGPoint(x: stack[0].frame.midX, y: stack[0].frame.minY + 0.01))
        try require(pointer.accessibilityHelp() == stack[0].detail, "Crossing back must restore the lower project")

        // Add projects after the chart is already mounted, including beyond the original eight colors.
        for index in 8..<names.count {
            try require(store.addTimedActivity(name: names[index]) == nil, "A later project should save")
            try require(store.addActivityRecord(activityID: store.activityTimers.activities.last!.id,
                                               startedAt: yesterday, duration: 1500) == nil, "A later project's record should save")
        }
        pumpEvents(for: 0.2)
        try require(pointer.regions.count == 13, "New projects must acquire hover regions without reopening the chart")
        try require(Set(pointer.regions.map { $0.activity.chartLabel }).count == 12, "All twelve projects must have distinct visible numbers")
        for region in pointer.regions { try hover(region) }
        let renamedID = sql.id
        try hover(pointer.regions.first { $0.activity.id == renamedID }!)
        try require(store.renameTimedActivity(id: renamedID, name: "SQL · 数据库查询") == nil, "Renaming a hovered project should save")
        pumpEvents(for: 0.1)
        try require(pointer.accessibilityHelp()?.contains("SQL · 数据库查询") == true, "The visible tooltip must follow a rename without mouse movement")
        configuration.excluded = [renamedID]
        pumpEvents(for: 0.1)
        try require(pointer.regions.allSatisfy { $0.activity.id != renamedID }, "Filtered projects must lose their hover regions")
        try require(pointer.accessibilityHelp()?.contains("SQL · 数据库查询") != true, "Filtering must not leave a stale tooltip")
        for region in pointer.regions { try hover(region) }
        configuration.excluded = Set(store.activityTimers.activities.map(\.id))
        pumpEvents(for: 0.1)
        try require(pointer.regions.isEmpty && pointer.accessibilityHelp() == nil, "Clearing the selection must clear hover details")
        configuration.excluded = []
        configuration.days = 30
        window.setContentSize(NSSize(width: 680, height: 280))
        pumpEvents(for: 0.2)
        for region in pointer.regions { try hover(region) }
        configuration.days = 7
        window.setContentSize(NSSize(width: 840, height: 300))
        pumpEvents(for: 0.1)
        let longName = pointer.regions.first { $0.activity.name == names[2] }!
        let dataURL = directory.appendingPathComponent("timers.json")
        let saved = try Data(contentsOf: dataURL)
        try hover(longName)
        try writePreview(window, to: output.appendingPathComponent("study-chart-hover-light.png"))
        store.theme = .horror
        pumpEvents(for: 0.1)
        try hover(pointer.regions.first { $0.activity.name == names[2] }!)
        try writePreview(window, to: output.appendingPathComponent("study-chart-hover-dark.png"))
        store.language = .english
        pumpEvents(for: 0.1)
        try hover(pointer.regions.first { $0.activity.chartLabel == "#12" }!)
        try require(pointer.accessibilityHelp()?.contains("hr") == true, "Hover duration should follow the current language")
        try writePreview(window, to: output.appendingPathComponent("study-chart-hover-en.png"))
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        pointer.mouseExited(with: event)
        pumpEvents(for: 0.05)
        try require(pointer.accessibilityHelp() == nil, "Leaving the chart must dismiss the tooltip")
        try require(try Data(contentsOf: dataURL) == saved, "Hovering, filtering, resizing and theme changes must not change study records")
        print("PASS: chart hover, adjacent stack boundaries, tiny blocks, empty gaps, new projects, distinct numbers, rename, filtering, resize and languages")
    }

    @MainActor
    private static func verifyStudyPreviews(in output: URL) throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-07T04:00:00Z")!
        let directory = output.appendingPathComponent("study-previews-\(UUID().uuidString)")
        let store = PlanStore(storageDirectory: directory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        defer { store.stop(); AppLanguage.current = .chinese }
        store.rememberActivityRange(0)
        for name in ["cpc", "SQL", "Python 语言与异步编程", "HTTP 与计算机网络", "阅读"] {
            try require(store.addTimedActivity(name: name) == nil, "Preview project should save")
        }
        for day in 1...7 {
            for (index, activity) in store.activityTimers.activities.enumerated() {
                let duration = Double(900 + (day * (index + 2) % 7) * 600)
                try require(store.addActivityRecord(activityID: activity.id,
                                                    startedAt: now.addingTimeInterval(Double(-day * 86400 + index * 3600)),
                                                    duration: duration) == nil, "Preview daily record should save")
            }
        }
        let cpcID = store.activityTimers.activities[0].id
        try require(store.addActivityRecord(activityID: cpcID, startedAt: now.addingTimeInterval(-17 * 3600), duration: 17 * 3600) == nil, "Forgotten timer preview should save")
        let sessionID = store.activityTimers.sessions.last!.id
        try require(store.correctActivityDuration(sessionID: sessionID, duration: 5400) == nil, "Preview correction should save")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 1160), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ActivityTimersView(store: store, initialSection: 1))
        window.orderFront(nil)
        pumpEvents(for: 0.2)
        try writePreview(window, to: output.appendingPathComponent("study-statistics-light.png"))
        store.theme = .horror
        pumpEvents(for: 0.2)
        try writePreview(window, to: output.appendingPathComponent("study-statistics-dark.png"))
        if let scroll = descendantScrollView(in: window.contentView!) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
            scroll.reflectScrolledClipView(scroll.contentView)
            pumpEvents(for: 0.2)
            try writePreview(window, to: output.appendingPathComponent("study-project-bars-dark.png"))
            try require(store.addTimedActivity(name: "后续新增学习项目") == nil, "Adding a project with the statistics page open should save")
            let newID = store.activityTimers.activities.last!.id
            try require(store.addActivityRecord(activityID: newID, startedAt: now.addingTimeInterval(-1800), duration: 900) == nil,
                        "The new project's first study record should save")
            pumpEvents(for: 0.2)
            guard let pointer = descendant(of: window.contentView!, whoseClassContains: "ActivityChartPointerView") as? ActivityChartPointerView,
                  let region = pointer.regions.first(where: { $0.activity.id == newID }) else {
                throw SmokeFailure(description: "The full statistics page must automatically select and display newly added projects")
            }
            let location = pointer.convert(CGPoint(x: region.frame.midX, y: region.frame.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            guard let owner = pointer.trackingAreas.first(where: { $0.options.contains(.mouseMoved) })?.owner as? NSResponder else {
                throw SmokeFailure(description: "The full statistics chart must install a mouse tracking responder")
            }
            owner.mouseMoved(with: event)
            pumpEvents(for: 0.1)
            try require(pointer.accessibilityHelp() == region.detail, "The full statistics page must show hover details for a newly added project")
            try writePreview(window, to: output.appendingPathComponent("study-statistics-hover-dark.png"))
        } else {
            throw SmokeFailure(description: "Study statistics must have a scrollable records area")
        }
        window.close()
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        editor.contentView = NSHostingView(rootView: ActivityRecordEditor(store: store, session: store.activityTimers.sessions.last!))
        editor.orderFront(nil)
        try writePreview(editor, to: output.appendingPathComponent("study-duration-editor.png"))
        store.language = .english
        editor.contentView = NSHostingView(rootView: ActivityRecordEditor(store: store, session: store.activityTimers.sessions.last!))
        try writePreview(editor, to: output.appendingPathComponent("study-duration-editor-en.png"))
        editor.close()
    }

    @MainActor
    private static func descendantScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { descendantScrollView(in: $0) }.first
    }

    @MainActor
    private static func accessibilityNodes(in root: Any) -> [NSAccessibilityProtocol] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSAccessibilityProtocol] = []
        func visit(_ object: Any) {
            let identity = ObjectIdentifier(object as AnyObject)
            guard seen.insert(identity).inserted, seen.count < 20000 else { return }
            if let node = object as? NSAccessibilityProtocol {
                result.append(node)
                for child in node.accessibilityChildren() ?? [] { visit(child) }
            }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return result
    }

    @MainActor
    private static func showInteractiveStudyPreview(controller: AppController, output: URL) throws {
        let store = controller.store
        let now = store.now
        for name in ["SQL", "测试", "Python 语言与异步编程", "HTTP 与计算机网络", "学习", "cpc", "阅读", "算法", "数据库原理", "操作系统", "系统设计", "英语"] {
            try require(store.addTimedActivity(name: name) == nil, "Interactive preview project should save")
        }
        for day in 1...7 {
            for (index, activity) in store.activityTimers.activities.enumerated() {
                let start = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(-day * 86400 + index * 2400))
                try require(store.addActivityRecord(activityID: activity.id, startedAt: start, duration: Double(900 + index * 60)) == nil,
                            "Interactive preview record should save")
            }
        }
        store.theme = .horror
        controller.showTimers()
        guard let window = NSApp.windows.first(where: { $0.title == L("事项计时 · FocusDesk") }) else {
            throw SmokeFailure(description: "Interactive preview window did not open")
        }
        window.setContentSize(NSSize(width: 900, height: 760))
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                if let scroll = descendantScrollView(in: window.contentView!) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: 450))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                print("INTERACTIVE_PREVIEW_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
            }
        }
        var previous: String?
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let pointer = descendant(of: window.contentView!, whoseClassContains: "ActivityChartPointerView") as? ActivityChartPointerView else { return }
                let detail = pointer.accessibilityHelp()
                if detail != previous {
                    previous = detail
                    print("POINTER_DETAIL: \(detail ?? "dismissed")")
                    if detail != nil { try? writePreview(window, to: output.appendingPathComponent("ux-real-pointer.png")) }
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in NSApp.terminate(nil) }
    }

    @MainActor
    private static func verifyStudyUsability(in output: URL) throws {
        var now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
        let directory = output.appendingPathComponent("usability-\(UUID().uuidString)")
        let store = PlanStore(storageDirectory: directory, defaults: SmokeDefaults(), allowsLoginItemChanges: false,
                              nowProvider: { now }, startClock: false)
        defer { store.stop(); AppLanguage.current = .chinese }
        store.rememberActivityRange(0)
        for name in ["SQL", "HTTP 与计算机网络", "Python 语言与异步编程 · 服务端任务调度、网络请求与错误处理练习"] {
            try require(store.addTimedActivity(name: name) == nil, "Usability fixture project should save")
        }
        let sqlID = store.activityTimers.activities[0].id
        try require(store.addActivityRecord(activityID: sqlID, startedAt: now.addingTimeInterval(-3600), duration: 600) == nil,
                    "Usability fixture should include today's record")
        try require(store.addActivityRecord(activityID: store.activityTimers.activities[1].id,
                                           startedAt: now.addingTimeInterval(-40 * 86400), duration: 1800) == nil,
                    "All-time totals should include a record outside the trend window")
        func checkCachedTotals() throws {
            let snapshot = store.activityStatistics()
            let actual = snapshot.summaries(days: 0, order: .descending)
            let expected = store.activityTimers.durationSummaries(at: store.now, order: .descending)
            try require(actual.map(\.id) == expected.map(\.id) && actual.map(\.duration) == expected.map(\.duration),
                        "Published store statistics must invalidate with timer mutations")
        }
        try checkCachedTotals()
        try require(store.startActivityTimer(activityID: sqlID, mode: .stopwatch, duration: nil) == nil, "Cache integration timer should start")
        now = now.addingTimeInterval(60)
        store.refresh()
        try checkCachedTotals()
        try require(store.toggleActivityTimerPause() == nil, "Cache integration timer should pause")
        now = now.addingTimeInterval(600)
        store.refresh()
        try checkCachedTotals()
        try require(store.toggleActivityTimerPause() == nil, "Cache integration timer should resume")
        now = now.addingTimeInterval(30)
        try require(store.finishActivityTimer() == nil, "Cache integration timer should finish")
        try checkCachedTotals()
        let completed = store.activityTimers.sessions.last!
        try require(store.correctActivityDuration(sessionID: completed.id, duration: 45) == nil, "Cache integration duration should correct")
        try checkCachedTotals()
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 840, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ActivityTimersView(store: store, initialSection: 1))
        window.orderFront(nil)
        defer { window.close() }
        pumpEvents(for: 0.2)
        func node(_ identifier: String) throws -> NSAccessibilityProtocol {
            guard let value = accessibilityNodes(in: window.contentView!).first(where: { $0.accessibilityIdentifier() == identifier }) else {
                let found = accessibilityNodes(in: window.contentView!).compactMap { $0.accessibilityIdentifier() }
                let children = window.contentView!.accessibilityChildren()?.map { String(describing: Swift.type(of: $0)) } ?? []
                throw SmokeFailure(description: "Missing UI element \(identifier); found: \(found); root children: \(children)")
            }
            return value
        }
        func text(_ element: NSAccessibilityProtocol) -> String {
            (element.accessibilityValue() as? String) ?? element.accessibilityLabel() ?? ""
        }
        func press(_ identifier: String) throws {
            try require(try node(identifier).accessibilityPerformPress(), "UI element should respond to a press: \(identifier)")
            pumpEvents(for: 0.1)
        }
        func type(_ value: String, into identifier: String) throws -> NSTextView {
            let element = try node(identifier)
            let frame = element.accessibilityFrame()
            let fields = accessibilityNodes(in: window.contentView!).compactMap { $0 as? NSTextField }
            guard let field = fields.first(where: { $0.accessibilityIdentifier() == identifier })
                    ?? fields.first(where: { frame.contains(NSPoint(x: $0.accessibilityFrame().midX, y: $0.accessibilityFrame().midY)) }),
                  window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
                throw SmokeFailure(description: "Text field must be editable through its native field editor: \(identifier)")
            }
            editor.selectAll(nil)
            editor.insertText(value, replacementRange: editor.selectedRange())
            pumpEvents(for: 0.05)
            return editor
        }
        func scroll(_ offset: CGFloat) throws {
            guard let scroll = descendantScrollView(in: window.contentView!) else { throw SmokeFailure(description: "Usability page must scroll") }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            pumpEvents(for: 0.15)
        }
        if CommandLine.arguments.contains("--accessibility-actions") {
            // Optional UI-client checks need an active accessibility client/XCUITest host.
            try require(!(try node("addTimedActivity").isAccessibilityEnabled()), "An empty project name should disable Add")
            _ = try type("SQL", into: "newActivityName")
            try press("addTimedActivity")
            try require(store.activityTimers.activities.count == 3, "A duplicate name must not create another project")
            try require(text(try node("activityInputError")).contains("同名"), "Duplicate input should show an inline explanation")
            try require(text(try node("newActivityName")) == "SQL", "An invalid submission must retain the entered name")
            _ = try type("新增后的课题", into: "newActivityName")
            try press("addTimedActivity")
            try require(store.activityTimers.activities.count == 4, "The corrected name should save")
            let runningID = store.activityTimers.activities.last!.id
            try press("startActivityTimer")
            try require(store.activityTimers.activeSession?.activityID == runningID, "The newly added project should be selected for Start")
            let editor = try type("尚未提交的输入", into: "newActivityName")
            for _ in 0..<5 { now = now.addingTimeInterval(1); store.refresh(); pumpEvents(for: 0.03) }
            try require(window.firstResponder === editor && editor.string == "尚未提交的输入", "Clock refreshes must preserve input and keyboard focus")
            now = now.addingTimeInterval(639)
            store.refresh()
            try scroll(500)
            try require(text(try node("activityStatisticsScope")) == L("累计范围：全部记录"), "All-time scope should be explicitly labeled")
            // Keep the editing row fixed while the running project's duration overtakes it.
            try scroll(850)
            try press("activityRename-\(sqlID)")
            let renameEditor = try type("HTTP 与计算机网络", into: "activityRenameField")
            let fieldBefore = try node("activityRenameField").accessibilityFrame()
            now = now.addingTimeInterval(2)
            store.refresh()
            pumpEvents(for: 0.1)
            try require(window.firstResponder === renameEditor && renameEditor.string == "HTTP 与计算机网络", "Duration reordering must not interrupt an edit")
            let fieldAfter = try node("activityRenameField").accessibilityFrame()
            try require(abs(fieldBefore.minY - fieldAfter.minY) < 1, "A live duration crossing must not move the editing row")
            try press("saveActivityRename")
            try require(store.activityTimers.activities.first { $0.id == sqlID }?.name == "SQL", "Duplicate rename must leave the original identity and name")
            try require(text(try node("activityInputError")).contains("同名"), "Rename validation should appear next to the row")
            try writePreview(window, to: output.appendingPathComponent("ux-inline-error.png"))
            _ = try type("SQL 查询与索引", into: "activityRenameField")
            try press("saveActivityRename")
            try require(store.activityTimers.activities.first { $0.id == sqlID }?.name == "SQL 查询与索引", "A corrected rename should save in place")
            try require(store.activityTimers.sessions.contains { $0.activityID == sqlID && $0.savedDuration == 600 }, "Renaming must preserve study records")
            try press("activityRename-\(sqlID)")
            _ = try type("不应保存的名称", into: "activityRenameField")
            try press("cancelActivityRename")
            try require(store.activityTimers.activities.first { $0.id == sqlID }?.name == "SQL 查询与索引", "Cancel should preserve the saved name")
            try require(store.finishActivityTimer() == nil, "Usability timer should finish")
        } else {
            print("SKIP: accessibility button/typing actions require a connected UI client; use --accessibility-actions with that client active")
        }
        let timerDataBeforeThemes = try Data(contentsOf: directory.appendingPathComponent("timers.json"))
        try scroll(0)
        for theme in DeskTheme.allCases {
            store.theme = theme
            window.setContentSize(NSSize(width: 680, height: 700))
            pumpEvents(for: 0.1)
            let expected: NSAppearance.Name = theme.dark ? .darkAqua : .aqua
            try require(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                        "Native controls must follow the \(theme.rawValue) theme")
            try require(window.contentView!.fittingSize.width <= 681, "Long names must not force horizontal overflow")
            try writePreview(window, to: output.appendingPathComponent("ux-timers-\(theme.rawValue).png"))
        }
        store.theme = .horror
        store.language = .english
        pumpEvents(for: 0.1)
        try writePreview(window, to: output.appendingPathComponent("ux-timers-en-small.png"))
        window.setContentSize(NSSize(width: 1040, height: 760))
        pumpEvents(for: 0.1)
        try writePreview(window, to: output.appendingPathComponent("ux-timers-en-wide.png"))
        store.language = .chinese
        try scroll(450)
        try require(try Data(contentsOf: directory.appendingPathComponent("timers.json")) == timerDataBeforeThemes,
                    "Theme, language and window changes must not rewrite study data")
        print("PASS: all theme appearances and responsive long names; optional accessibility actions are reported separately")
    }

    @MainActor
    private static func verifyWindows(controller: AppController, output: URL) throws {
        let panels = NSApp.windows.compactMap { $0 as? NSPanel }
        let compacts = panels.filter { $0.title == "FocusDesk 小方块" }
        let details = panels.filter { $0.title == "FocusDesk 悬浮窗" }
        try require(compacts.count == 1 && details.count == 1, "Expected one compact square and one detail NSPanel")
        let compact = compacts[0]
        let detail = details[0]
        try require(compact.isVisible && !detail.isVisible, "Startup should show only the compact square")
        try require(!controller.store.isExpanded && controller.store.isFloatingVisible, "Startup visibility state is incorrect")
        try require(approximately(compact.frame.width, 56) && approximately(compact.frame.height, 56), "Default square must measure 56 × 56 points")
        try require(!NSApp.isActive, "Showing the compact square at startup must not activate the app")
        for panel in [compact, detail] {
            try require(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow, "Desktop panels must not take keyboard focus")
            try require(panel.styleMask.contains(.nonactivatingPanel), "Desktop panels must be nonactivating")
            try require(panel.collectionBehavior.contains(.canJoinAllSpaces), "Desktop panels should join all Spaces")
            try require(panel.collectionBehavior.contains(.fullScreenAuxiliary), "Desktop panels should support full-screen apps")
            try require(!panel.hidesOnDeactivate && panel.isFloatingPanel, "Desktop panels should remain available across app switches")
            try require(panel.level == .floating, "Always-on-top should be enabled by default")
            panel.contentView?.updateTrackingAreas()
            let tracksInBackground = panel.contentView?.trackingAreas.contains { area in
                area.options.contains(.activeAlways) && area.options.contains(.mouseEnteredAndExited)
                    && area.options.contains(.enabledDuringMouseDrag)
            } == true
            try require(tracksInBackground, "Hover tracking should continue while another app is active and during native dragging")
        }
        try require(compact.isMovableByWindowBackground, "The compact square background should support native dragging")
        try require(compact.contentView?.mouseDownCanMoveWindow == true, "Compact hosting view must permit native window dragging")
        try writePreview(compact, to: output.appendingPathComponent("compact.png"))

        controller.store.alwaysOnTop = false
        try require(compact.level == .normal && detail.level == .normal, "Always-on-top switch should update both panels")
        controller.store.alwaysOnTop = true
        try verifyResizing(controller: controller, compact: compact)
        try verifyHover(controller: controller, compact: compact, detail: detail)
        try verifyPlacement(controller: controller, compact: compact, detail: detail)
        controller.resizeCompact(to: CGFloat(PlanStore.defaultCompactSize))
        controller.setCompactHover(true)
        if let current = controller.store.snapshot.current {
            try require(controller.store.toggleTaskCompletion(id: current.id) == nil, "Completing the current task from the widget should save")
            try require(controller.store.isTaskCompleted(current.id), "Widget completion should update today's progress")
        }
        try writePreview(detail, to: output.appendingPathComponent("floating.png"))
        let originalTasks = controller.store.tasks
        let originalQuoteCache = controller.store.defaults.object(forKey: QuoteRotation.cacheKey)
        if var current = controller.store.snapshot.current,
           let longestQuote = MotivationalQuote.all.max(by: { $0.text.count < $1.text.count }) {
            current.title = "保持专注，把今天最重要的一件事情认真做好"
            try require(controller.store.saveTask(current) == nil, "The long-title preview task should save")
            controller.store.defaults.set(["id": longestQuote.id, "selectedAt": controller.store.now], forKey: QuoteRotation.cacheKey)
            controller.store.refresh()
            try writePreview(detail, to: output.appendingPathComponent("floating-long-content.png"))
            try require(controller.store.replaceTasks(originalTasks) == nil, "The preview should restore the original tasks")
            controller.store.defaults.set(originalQuoteCache, forKey: QuoteRotation.cacheKey)
            controller.store.refresh()
        }
        let openedQuote = controller.store.motivationalQuote
        controller.store.onShowQuoteDetails?(openedQuote)
        let quoteWindows = NSApp.windows.filter { $0.title == "解释与出处 · FocusDesk" }
        try require(quoteWindows.count == 1, "The quote detail action should open one window")
        let quoteWindow = quoteWindows[0]
        try require(quoteWindow.isVisible && quoteWindow.canBecomeKey, "Quote details should remain readable outside the hover panel")
        try require((quoteWindow.contentView as? NSHostingView<QuoteDetailView>)?.rootView.quote == openedQuote, "Details must display the clicked quote and its matching explanation and source")
        try require(!detail.isVisible && !controller.store.isExpanded, "Opening quote details should collapse the hover panel")
        try writePreview(quoteWindow, to: output.appendingPathComponent("quote-details.png"))
        let nextQuote = MotivationalQuote.all.first { $0.id != openedQuote.id }!
        controller.store.onShowQuoteDetails?(nextQuote)
        try require((quoteWindow.contentView as? NSHostingView<QuoteDetailView>)?.rootView.quote == nextQuote, "Reusing the window must update the quote and its source together")
        try require(NSApp.windows.filter { $0.title == "解释与出处 · FocusDesk" }.count == 1, "Opening another quote should reuse the detail window")
        try writePreview(quoteWindow, to: output.appendingPathComponent("quote-details-reused.png"))
        quoteWindow.close()
        controller.store.onShowQuoteDetails?(openedQuote)
        try require(quoteWindow.isVisible, "A closed quote detail window should reopen")
        quoteWindow.close()
        controller.collapseDetails()

        controller.setCompactHover(true)
        controller.setCompactHover(false)
        controller.toggleFloating()
        try require(!compact.isVisible && !detail.isVisible && !controller.store.isFloatingVisible, "Hiding the widget should hide both panels")
        controller.setCompactHover(true)
        pumpEvents(for: 0.4)
        try require(!detail.isVisible && !controller.store.isExpanded, "A hover event must not reopen a hidden widget")
        controller.toggleFloating()
        pumpEvents(for: 0.35)
        try require(compact.isVisible && !detail.isVisible && controller.store.isFloatingVisible, "Showing the widget should restore only its compact square")
        try require(!controller.store.isExpanded, "Showing the widget must reset any pending hover expansion")

        controller.showPlan()
        controller.showPlan()
        let plans = NSApp.windows.filter { $0.title == "今日计划 · FocusDesk" }
        try require(plans.count == 1, "Opening the plan twice should reuse the same window")
        let plan = plans[0]
        try require(plan.isVisible && plan.canBecomeKey, "Plan window should support native editing")
        try writePreview(plan, to: output.appendingPathComponent("plan.png"))
        plan.close()
        controller.showPlan()
        try require(NSApp.windows.filter { $0.title == "今日计划 · FocusDesk" }.count == 1, "Closing and reopening should reuse the plan window")

        controller.showSettings()
        controller.showSettings()
        let settings = NSApp.windows.filter { $0.title == "设置 · FocusDesk" }
        try require(settings.count == 1, "Opening settings twice should reuse the same window")
        try require((settings[0].contentView?.bounds.height ?? 0) >= 520, "Settings content is too short and may clip")
        try writePreview(settings[0], to: output.appendingPathComponent("settings.png"))
        controller.showHistory()
        controller.showHistory()
        let history = NSApp.windows.filter { $0.title == "计划回顾 · FocusDesk" }
        try require(history.count == 1, "Opening history twice should reuse the same window")
        try require(history[0].isVisible && history[0].canBecomeKey, "History should open as a readable native window")
        try writePreview(history[0], to: output.appendingPathComponent("history.png"))
        try require(controller.store.addTimedActivity(name: "阅读") == nil, "Preview activity should save")
        let activity = controller.store.activityTimers.activities[0]
        try require(controller.store.startActivityTimer(activityID: activity.id, mode: .countdown, duration: 1500) == nil, "Preview timer should start")
        controller.showTimers()
        controller.showTimers()
        let timers = NSApp.windows.filter { $0.title == "事项计时 · FocusDesk" }
        try require(timers.count == 1 && timers[0].isVisible && timers[0].canBecomeKey, "Timers should reuse a native interactive window")
        try writePreview(timers[0], to: output.appendingPathComponent("timers.png"))
        timers[0].setContentSize(NSSize(width: 680, height: 540))
        try writePreview(timers[0], to: output.appendingPathComponent("timers-small.png"))
        timers[0].close()
        controller.showTimers()
        try require(timers[0].isVisible, "Closed timers window should reopen")
        timers[0].close()
        controller.setCompactHover(true)
        try writePreview(detail, to: output.appendingPathComponent("floating-timer.png"))
        try writePreview(compact, to: output.appendingPathComponent("compact-timer.png"))
        try require(controller.store.toggleActivityTimerPause() == nil, "Widget timer should pause")
        try writePreview(detail, to: output.appendingPathComponent("floating-timer-paused.png"))
        controller.collapseDetails()
        try require(controller.store.finishActivityTimer() == nil, "Preview timer should finish")
        try require(controller.store.startActivityTimer(activityID: activity.id, mode: .countdown, duration: 1) == nil, "Quiet preview countdown should start")
        let keyWindow = NSApp.keyWindow
        pumpEvents(for: 1.3)
        controller.store.refresh()
        try require(controller.store.activityTimers.pendingCountdown != nil, "Quiet preview countdown should remain visible after reaching zero")
        try require(!detail.isVisible && NSApp.keyWindow === keyWindow && !compact.isKeyWindow, "Countdown expiry must not expand details or steal keyboard focus")
        pumpEvents(for: 1.9)
        try writePreview(compact, to: output.appendingPathComponent("compact-timer-due.png"))
        controller.resizeCompact(to: 32)
        pumpEvents(for: 0.05)
        try writePreview(compact, to: output.appendingPathComponent("compact-timer-due-small.png"))
        controller.resizeCompact(to: 112)
        pumpEvents(for: 0.05)
        try writePreview(compact, to: output.appendingPathComponent("compact-timer-due-large.png"))
        controller.resizeCompact(to: CGFloat(PlanStore.defaultCompactSize))
        controller.setCompactHover(true)
        try writePreview(detail, to: output.appendingPathComponent("floating-timer-due.png"))
        controller.showTimers()
        try writePreview(timers[0], to: output.appendingPathComponent("timers-due.png"))
        timers[0].close()
        try require(controller.store.extendActivityCountdown() == nil, "Widget countdown should extend")
        controller.setCompactHover(true)
        try writePreview(detail, to: output.appendingPathComponent("floating-timer-extended.png"))
        try require(controller.store.finishActivityTimer() == nil && controller.store.activityTimers.displayedSession == nil, "Finishing must restore the daily schedule")
        try writePreview(detail, to: output.appendingPathComponent("floating-timer-finished.png"))
        controller.collapseDetails()
        try require(controller.store.addTimedActivity(name: "运动") == nil, "Second preview activity should save")
        try require(controller.store.addTimedActivity(name: "练字") == nil, "Third preview activity should save")
        timers[0].setContentSize(NSSize(width: 800, height: 900))
        controller.showTimers()
        try writePreview(timers[0], to: output.appendingPathComponent("timers-management.png"))
        timers[0].close()
        // Exercise every palette and effect through the same windows used by the app.
        let timerFileBeforeThemes = try Data(contentsOf: controller.store.storageURL.deletingLastPathComponent().appendingPathComponent("timers.json"))
        for theme in DeskTheme.allCases {
            controller.store.theme = theme
            controller.setCompactHover(true)
            pumpEvents(for: 0.08)
            try writePreview(detail, to: output.appendingPathComponent("theme-\(theme.rawValue).png"))
            try writePreview(compact, to: output.appendingPathComponent("square-\(theme.rawValue).png"))
        }
        // Coverage means the circle/screen intersection, including corners and ultrawide screens.
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 3440, height: 1440), CGSize(width: 900, height: 1600)] {
            for origin in [CGPoint.zero, CGPoint(x: size.width/2, y: size.height/2), CGPoint(x: size.width-20, y: 10)] {
                for coverage in [0.1, 0.5, 0.75, 0.85, 1.0] {
                    let radius = EffectGeometry.radius(size: size, origin: origin, coverage: coverage)
                    let ratio = EffectGeometry.area(size: size, origin: origin, radius: radius)/(size.width*size.height)
                    try require(abs(ratio-coverage) < 0.003, "Coverage must match reachable screen area")
                }
            }
        }
        var invalid = EffectConfiguration(); invalid.coverage = .infinity; invalid.duration = 99; invalid.dim = -1; invalid.waves = 40
        try require(invalid.normalized.coverage == 0.5 && invalid.normalized.duration == 12 && invalid.normalized.dim == 0 && invalid.normalized.waves == 3, "Invalid effect values must be bounded")
        let migrationDefaults = SmokeDefaults(); migrationDefaults.set("dramatic", forKey: "appearance.intensity")
        let migrated = PlanStore(storageDirectory: output.appendingPathComponent("effect-migration"), defaults: migrationDefaults, allowsLoginItemChanges: false, startClock: false)
        defer { migrated.stop() }
        try require(migrated.effectConfiguration.coverage == 0.85, "Old dramatic intensity must migrate to a large-area preset")
        controller.store.theme = .cyber
        controller.store.effectIntensity = .dramatic
        controller.store.effectConfiguration.speed = 1.3
        let customConfiguration = controller.store.effectConfiguration
        for effect in CountdownEffect.allCases {
            controller.store.countdownEffect = effect
            let previousKey = NSApp.keyWindow
            controller.playCountdownEffect(preview: true)
            pumpEvents(for: 0.5)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let overlay = NSApp.windows.first { $0.title == "FocusDesk 到时特效" && $0.isVisible }
                try require(overlay != nil && overlay!.ignoresMouseEvents && !overlay!.canBecomeKey, "Effects must pass clicks through and never accept focus")
                let screenFrame = compact.screen!.frame
                try require(overlay!.frame == screenFrame, "Overlay must use the physical screen frame")
                try require(controller.effectPanels.count == 1, "Default effect must stay on the square's screen")
                try require(NSApp.keyWindow === previousKey, "Effect preview must preserve keyboard focus")
                try writePreview(overlay!, to: output.appendingPathComponent("effect-\(effect.rawValue).png"))
            }
        }
        pumpEvents(for: 5.2)
        try require(!NSApp.windows.contains { $0.title == "FocusDesk 到时特效" && $0.isVisible }, "Effect window must disappear after playback")
        controller.store.effectConfiguration.allScreens = true
        controller.playCountdownEffect(preview: true)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try require(controller.effectPanels.count == NSScreen.screens.count, "All-monitor mode needs one overlay per screen")
        }
        controller.stopCountdownEffect()
        try require(controller.effectPanels.isEmpty, "Stop must release all canvases")
        controller.store.effectConfiguration = customConfiguration
        controller.playCountdownEffect(preview: true)
        controller.store.effectsEnabled = false
        pumpEvents(for: 0.1)
        try require(controller.effectPanels.isEmpty, "Disabling must stop the current playback")
        controller.playCountdownEffect(preview: true)
        try require(!NSApp.windows.contains { $0.title == "FocusDesk 到时特效" && $0.isVisible }, "Disabled effects must not create a visible overlay")
        controller.store.effectsEnabled = true
        for coverage in [0.5, 0.85, 1.0] {
            var config = EffectIntensity.dramatic.configuration; config.coverage = coverage
            let size = CGSize(width: 1280, height: 720), origin = CGPoint(x: 154, y: 130)
            let radius = EffectGeometry.radius(size: size, origin: origin, coverage: coverage)
            let snapshot = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            snapshot.isReleasedWhenClosed = false
            snapshot.contentView = NSHostingView(rootView: Canvas { context, canvasSize in
                CountdownEffectView.draw(context: &context, size: canvasSize, theme: .cyber, effect: .energy,
                                         configuration: config, origin: origin, radius: radius, elapsed: 1.7)
            }.frame(width: size.width, height: size.height))
            try writePreview(snapshot, to: output.appendingPathComponent("screen-effect-\(Int(coverage*100)).png"))
            snapshot.close()
        }
        controller.store.theme = .vintage
        controller.showSettings()
        try writePreview(settings[0], to: output.appendingPathComponent("theme-settings.png"))
        settings[0].close()
        let appearanceReload = PlanStore(storageDirectory: controller.store.storageURL.deletingLastPathComponent(),
                                         defaults: controller.store.defaults, allowsLoginItemChanges: false, startClock: false)
        defer { appearanceReload.stop() }
        try require(appearanceReload.effectConfiguration == customConfiguration, "Advanced custom settings must survive reload")
        try require(appearanceReload.theme == .vintage && appearanceReload.countdownEffect == .pixels && appearanceReload.effectIntensity == .dramatic, "Theme and effect choices must survive reload")
        try require(try Data(contentsOf: controller.store.storageURL.deletingLastPathComponent().appendingPathComponent("timers.json")) == timerFileBeforeThemes, "Appearance changes and previews must not alter timer records")
        controller.store.defaults.set("unknown-theme", forKey: "appearance.theme")
        let fallback = PlanStore(storageDirectory: controller.store.storageURL.deletingLastPathComponent(), defaults: controller.store.defaults, allowsLoginItemChanges: false, startClock: false)
        defer { fallback.stop() }
        try require(fallback.theme == .classic, "Unknown saved themes must fall back safely")
        print("PASS: all themes, effect overlays, focus, click-through, cleanup, preferences and unchanged timer data")
        controller.store.language = .english
        controller.store.theme = .terminal
        controller.showSettings()
        try writePreview(settings[0], to: output.appendingPathComponent("settings-en.png"))
        settings[0].close()
        controller.setCompactHover(true)
        try writePreview(detail, to: output.appendingPathComponent("floating-en.png"))
        try require(L("已到时") == "Time's up", "English UI translation")
        try require(L("%@，%@", "Name %@", "done") == "Name %@, done", "Interpolation must preserve percent signs in user names")
        let englishDefaults = SmokeDefaults()
        englishDefaults.set("en", forKey: "appearance.language")
        let englishStore = PlanStore(storageDirectory: output.appendingPathComponent("english-preview-\(UUID().uuidString)"), defaults: englishDefaults, allowsLoginItemChanges: false, startClock: false)
        defer { englishStore.stop() }
        englishStore.theme = .terminal
        try require(!englishStore.motivationalQuote.text.contains("。"), "English quote is translated on first launch")
        let englishWindow = NSWindow(contentRect: NSRect(origin: .zero, size: FloatingView.panelSize), styleMask: [.borderless], backing: .buffered, defer: false)
        englishWindow.contentView = NSHostingView(rootView: FloatingView(store: englishStore))
        englishWindow.orderFrontRegardless()
        try writePreview(englishWindow, to: output.appendingPathComponent("floating-en.png"))
        englishWindow.orderOut(nil)
        controller.store.language = .chinese
        controller.store.setLaunchAtLogin(true)
        try require(controller.store.errorMessage?.contains("测试模式") == true, "Smoke mode must block system login-item changes")
        print("PASS: nonactivating compact/detail panels, hover transitions, resize, geometry, reusable plan/settings/history windows")
    }

    @MainActor
    private static func verifyResizing(controller: AppController, compact: NSPanel) throws {
        let visible = compact.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        compact.setFrameOrigin(NSPoint(x: visible.midX - 28, y: visible.maxY - 100))
        pumpEvents(for: 0.05)
        let oldTop = compact.frame.maxY
        controller.resizeCompact(to: 88)
        pumpEvents(for: 0.05)
        try require(approximately(compact.frame.width, 88) && approximately(compact.frame.height, 88), "Resizing should preserve a square aspect ratio; actual frame: \(compact.frame), size preference: \(controller.store.compactSize)")
        try require(approximately(compact.frame.maxY, oldTop), "Resizing should preserve the top edge away from screen bounds")
        try require(visible.contains(compact.frame), "The resized square must remain inside the usable screen")
        try require(controller.store.compactSize == 88, "Native resizing should update the stored size")

        controller.resizeCompact(to: 1)
        pumpEvents(for: 0.05)
        try require(approximately(compact.frame.width, 32) && approximately(compact.frame.height, 32), "Native resizing should enforce the 32-point minimum")
        controller.resizeCompact(to: 1000)
        pumpEvents(for: 0.05)
        try require(approximately(compact.frame.width, 112) && approximately(compact.frame.height, 112), "Native resizing should enforce the 112-point maximum")
        try require(visible.contains(compact.frame), "Maximum compact size must remain on screen")
        let reloaded = PlanStore(
            storageDirectory: controller.store.storageURL.deletingLastPathComponent(),
            defaults: controller.store.defaults, allowsLoginItemChanges: false
        )
        defer { reloaded.stop() }
        try require(reloaded.compactSize == 112, "Native compact size did not survive a preference reload")
        controller.resizeCompact(to: CGFloat(PlanStore.defaultCompactSize))
        pumpEvents(for: 0.05)
        try verifyResizeHandle(compact)
        controller.resizeCompact(to: CGFloat(PlanStore.defaultCompactSize))
        pumpEvents(for: 0.05)

        // AppKit rounds fractional window origins to whole screen points.
        let destination = NSPoint(x: floor(visible.midX), y: floor(visible.midY))
        compact.setFrameOrigin(destination)
        pumpEvents(for: 0.05)
        let stored = controller.store.defaults.dictionary(forKey: "compactWindowPosition")
        try require(stored?["x"] as? Double == Double(destination.x) && stored?["y"] as? Double == Double(destination.y), "Native compact movement should persist its position; target: \(destination), frame: \(compact.frame.origin), saved: \(String(describing: stored))")
        print("PASS: square resizing, limits, top-edge anchoring, bounds, persisted size and position")
    }

    @MainActor
    private static func verifyResizeHandle(_ compact: NSPanel) throws {
        guard let root = compact.contentView,
              let handle = descendant(of: root, whoseClassContains: "ResizeHandleView") else {
            throw SmokeFailure(description: "Compact square has no native resize handle")
        }
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + 20, y: start.y - 20)
        let top = compact.frame.maxY
        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: compact.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1
            ) else { throw SmokeFailure(description: "Unable to construct an isolated resize event") }
            return event
        }
        // Deliver only to the test view; the real system pointer never moves.
        handle.mouseDown(with: try event(.leftMouseDown, at: start))
        handle.mouseDragged(with: try event(.leftMouseDragged, at: end))
        pumpEvents(for: 0.05, mode: .eventTracking)
        try require(approximately(compact.frame.width, 76) && approximately(compact.frame.height, 76), "Dragging the native resize handle should resize 56 to 76 points before mouse-up in event-tracking mode")
        try require(approximately(compact.frame.maxY, top), "Native resize handle dragging should preserve the square's top edge")
        handle.mouseUp(with: try event(.leftMouseUp, at: end))
    }

    @MainActor
    private static func descendant(of view: NSView, whoseClassContains name: String) -> NSView? {
        if String(describing: type(of: view)).contains(name) { return view }
        for child in view.subviews {
            if let match = descendant(of: child, whoseClassContains: name) { return match }
        }
        return nil
    }

    @MainActor
    private static func verifyHover(controller: AppController, compact: NSPanel, detail: NSPanel) throws {
        controller.setCompactHover(true)
        try require(detail.isVisible && controller.store.isExpanded && compact.isVisible, "Entering the compact square should expand task details")
        try require(!NSApp.isActive && !detail.isKeyWindow, "Hover expansion must not activate the app or steal focus")
        controller.setCompactHover(false)
        pumpEvents(for: 0.1)
        try require(detail.isVisible, "The short hide delay should permit moving into the detail panel")
        controller.setDetailHover(true)
        pumpEvents(for: 0.35)
        try require(detail.isVisible && controller.store.isExpanded, "Moving from square to detail should keep the detail panel open")
        controller.setDetailHover(false)
        pumpEvents(for: 0.4)
        try require(!detail.isVisible && !controller.store.isExpanded && compact.isVisible, "Leaving both panels should collapse details and preserve the square")

        controller.setCompactHover(true)
        controller.setCompactHover(false)
        pumpEvents(for: 0.1)
        controller.setCompactHover(true)
        pumpEvents(for: 0.4)
        try require(detail.isVisible && controller.store.isExpanded, "Quick reentry should cancel a pending collapse")
        controller.setCompactHover(false)
        pumpEvents(for: 0.4)
        try require(!detail.isVisible, "A subsequent complete exit should still collapse details")
        controller.setCompactHover(true)
        controller.collapseDetails()
        try require(!detail.isVisible && !controller.store.isExpanded, "Explicit collapse should hide the detail panel")
        print("PASS: enter, square-to-detail transfer, delayed exit, rapid reentry, explicit collapse")
    }

    @MainActor
    private static func verifyPlacement(controller: AppController, compact: NSPanel, detail: NSPanel) throws {
        let original = compact.frame.origin
        let visible = compact.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let side = compact.frame.width
        let corners = [
            NSPoint(x: visible.minX, y: visible.maxY - side),
            NSPoint(x: visible.maxX - side, y: visible.maxY - side),
            NSPoint(x: visible.minX, y: visible.minY),
            NSPoint(x: visible.maxX - side, y: visible.minY)
        ]
        for origin in corners {
            controller.collapseDetails()
            compact.setFrameOrigin(origin)
            pumpEvents(for: 0.05)
            controller.setCompactHover(true)
            try require(visible.contains(detail.frame), "Details must remain inside the usable screen near every corner")
            let intersection = compact.frame.intersection(detail.frame)
            try require(intersection.isNull || intersection.width * intersection.height < 1, "Details must not cover the compact square")
            try require(approximately(detail.frame.width, FloatingView.panelSize.width) && approximately(detail.frame.height, FloatingView.panelSize.height), "Detail layout should fit tasks and the motivational quote")
        }
        controller.collapseDetails()
        compact.setFrameOrigin(original)
        pumpEvents(for: 0.05)
        print("PASS: corner placement, visible screen bounds, unobstructed compact square")
    }

    private static func approximately(_ first: CGFloat, _ second: CGFloat) -> Bool {
        abs(first - second) < 0.5
    }

    @MainActor
    private static func pumpEvents(for interval: TimeInterval, mode: RunLoop.Mode = .default) {
        let deadline = Date(timeIntervalSinceNow: interval)
        while Date() < deadline {
            RunLoop.current.run(mode: mode, before: deadline)
        }
    }

    @MainActor
    private static func writePreview(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else { throw SmokeFailure(description: "Window has no content") }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SmokeFailure(description: "Unable to create a window preview")
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        guard let captured = bitmap.cgImage,
              let context = CGContext(
                data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw SmokeFailure(description: "Unable to composite the window preview")
        }
        let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(rect)
        context.draw(captured, in: rect)
        guard let composited = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: composited).representation(using: .png, properties: [:]) else {
            throw SmokeFailure(description: "Unable to encode the window preview")
        }
        try data.write(to: url)
    }
}
