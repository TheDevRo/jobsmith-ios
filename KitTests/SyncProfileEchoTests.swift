import XCTest
@testable import JobsmithKit

/// Receiving a profile must not make the next sync send it straight back out.
/// It used to: the "last seen" snapshot was built from the pre-sync profile, so
/// the next cycle saw a change and re-sent the phone's copy as the newest one.
/// With entries the phone couldn't decode, that copy had empty lists and
/// overwrote the desktop's profile.
final class SyncProfileEchoTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sync/changes"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// One desktop-written profile record: snake_case, entries without ids.
    private func writeDesktopProfile() throws {
        let line = #"{"v":1,"entity":"profile","id":"me","updated_at":"2026-01-01T00:00:00.000Z","device":"DESK","deleted":false,"data":{"full_name":"Test Person","experience":[{"title":"Role A","company":"Company A","start_date":"2020","end_date":"Present","bullets":["Did a thing"],"pinned":false}],"education":[{"degree":"B.A.","school":"School A","year":"2015"}]}}"#
        try (line + "\n").write(to: root.appendingPathComponent("sync/changes/DESK.jsonl"),
                                atomically: true, encoding: .utf8)
    }

    private func profileRecords(from device: String) throws -> Int {
        let url = root.appendingPathComponent("sync/changes/\(device).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { $0.contains(#""entity":"profile""#) }.count
    }

    func testAReceivedProfileIsNotSentBack() async throws {
        try writeDesktopProfile()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "echo-\(UUID().uuidString)"))
        let db = try AppDatabase.inMemory()
        let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
        let manager = SyncManager.shared
        let folder = root.appendingPathComponent("sync")
        let docs = root.appendingPathComponent("docs")

        _ = try await manager.syncOnce(folder: folder, db: db, configStore: store,
                                       docsLocalDir: docs, defaults: defaults)
        let received = await store.load().profile
        XCTAssertEqual(received.fullName, "Test Person")
        XCTAssertEqual(received.experience.map(\.title), ["Role A"])
        XCTAssertEqual(received.education.map(\.school), ["School A"])

        _ = try await manager.syncOnce(folder: folder, db: db, configStore: store,
                                       docsLocalDir: docs, defaults: defaults)
        let device = manager.deviceId(defaults)
        XCTAssertEqual(try profileRecords(from: device), 0,
                       "the phone re-sent a profile it had only received")
        let after = await store.load().profile
        XCTAssertEqual(after, received)
    }
}
