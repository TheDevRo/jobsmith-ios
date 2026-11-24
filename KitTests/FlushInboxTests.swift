import XCTest
import GRDB
@testable import JobsmithKit

/// Inbox Flush: which jobs are removed vs kept, the age filter, and that the
/// removal is a hard delete that syncs as `job` tombstones and leaves the
/// posting re-discoverable.
final class FlushInboxTests: XCTestCase {

    private let source = "greenhouse"

    private func seed(_ store: JobStore, _ externalId: String) throws -> String {
        let job = NormalizedJob(source: source, externalId: externalId,
                                title: "Engineer", company: "Company A")
        try store.upsert([job])
        let all = try store.jobs()
        return try XCTUnwrap(all.first { $0.externalId == externalId }).id
    }

    private func setDiscovered(_ db: AppDatabase, _ id: String, daysAgo: Int) throws {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        let text = ISO8601DateFormatter().string(from: date)
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE jobs SET dateDiscovered = ? WHERE id = ?",
                            arguments: [text, id])
        }
    }

    private func setCoverage(_ db: AppDatabase, _ id: String, dismissed: Bool) throws {
        let req = RequirementCoverage.Requirement(
            text: "Swift", kind: "must", met: false, dismissed: dismissed ? true : nil)
        let coverage = try XCTUnwrap(RequirementCoverage.build([req]))
        let json = try XCTUnwrap(coverage.json)
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE jobs SET coverage = ? WHERE id = ?",
                            arguments: [json, id])
        }
    }

    private func externalIds(_ db: AppDatabase) throws -> [String] {
        try db.writer.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT externalId FROM jobs ORDER BY externalId")
        }
    }

    func testFlushesPlainInboxJobsAndKeepsEverythingElse() throws {
        let db = try AppDatabase.inMemory()
        let store = JobStore(db)
        let apps = ApplicationStore(db)

        _ = try seed(store, "plain")
        let covered = try seed(store, "covered")
        try setCoverage(db, covered, dismissed: false)
        let shortlisted = try seed(store, "shortlisted")
        try store.setTriage("shortlisted", jobId: shortlisted)
        let passed = try seed(store, "passed")
        try store.setTriage("dismissed", jobId: passed)
        let deleted = try seed(store, "deleted")
        try store.delete(jobId: deleted)
        let drafted = try seed(store, "drafted")
        _ = try apps.createOrReplace(jobId: drafted, resume: "r", coverLetter: "c",
                                     honestyLevel: "honest", stylePreset: "standard")
        let dismissedGap = try seed(store, "gap")
        try setCoverage(db, dismissedGap, dismissed: true)

        XCTAssertEqual(try store.flushableCount(olderThan: nil), 2)
        XCTAssertEqual(try store.flushInbox(olderThan: nil), 2)

        let remaining = try externalIds(db)
        XCTAssertEqual(remaining, ["deleted", "drafted", "gap", "passed", "shortlisted"])
        try db.writer.read { dbc in
            let count = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM applications")
            XCTAssertEqual(count, 1)
        }
    }

    func testAppliedJobIsKept() throws {
        let db = try AppDatabase.inMemory()
        let store = JobStore(db)
        let apps = ApplicationStore(db)
        let id = try seed(store, "applied")
        let app = try apps.createOrReplace(jobId: id, resume: "r", coverLetter: "c",
                                           honestyLevel: "honest", stylePreset: "standard")
        try apps.updateStatus(id: app.id, status: "applied")

        XCTAssertEqual(try store.flushableCount(olderThan: nil), 0)
        XCTAssertEqual(try store.flushInbox(olderThan: nil), 0)
        XCTAssertEqual(try externalIds(db), ["applied"])
    }

    func testAgeFilterOnlyFlushesOlderJobs() throws {
        let db = try AppDatabase.inMemory()
        let store = JobStore(db)
        let old = try seed(store, "old")
        let fresh = try seed(store, "fresh")
        try setDiscovered(db, old, daysAgo: 30)
        try setDiscovered(db, fresh, daysAgo: 2)
        let cutoff = Date().addingTimeInterval(-14 * 86_400)

        XCTAssertEqual(try store.flushableCount(olderThan: cutoff), 1)
        XCTAssertEqual(try store.flushableCount(olderThan: nil), 2)
        XCTAssertEqual(try store.flushInbox(olderThan: cutoff), 1)
        XCTAssertEqual(try externalIds(db), ["fresh"])
    }

    /// Jobs synced from the desktop carry its date formats; the age filter must read them.
    func testAgeFilterReadsDesktopDateFormats() throws {
        let db = try AppDatabase.inMemory()
        let store = JobStore(db)
        let sqliteStyle = try seed(store, "sqlite-style")
        let pythonStyle = try seed(store, "python-style")
        let recent = try seed(store, "recent")
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE jobs SET dateDiscovered = ? WHERE id = ?",
                            arguments: ["2020-01-02 03:04:05", sqliteStyle])
            try dbc.execute(sql: "UPDATE jobs SET dateDiscovered = ? WHERE id = ?",
                            arguments: ["2020-01-02T03:04:05.123456+00:00", pythonStyle])
        }
        try setDiscovered(db, recent, daysAgo: 1)
        let cutoff = Date().addingTimeInterval(-14 * 86_400)

        XCTAssertEqual(try store.flushableCount(olderThan: cutoff), 2)
        XCTAssertEqual(try store.flushInbox(olderThan: cutoff), 2)
        XCTAssertEqual(try externalIds(db), ["recent"])
    }

    func testFlushedPostingIsInsertedFreshByLaterUpsert() throws {
        let db = try AppDatabase.inMemory()
        let store = JobStore(db)
        _ = try seed(store, "again")
        XCTAssertEqual(try store.flushInbox(olderThan: nil), 1)
        XCTAssertTrue(try externalIds(db).isEmpty)

        let job = NormalizedJob(source: source, externalId: "again",
                                title: "Engineer", company: "Company A")
        let summary = try store.upsert([job])
        XCTAssertEqual(summary.inserted, 1)
        let inbox = try store.inbox()
        XCTAssertEqual(inbox.map(\.externalId), ["again"])
        XCTAssertEqual(inbox.first?.timesSeen, 1)
    }

    func testExportAfterFlushEmitsJobTombstonesAndPeerDropsJobs() throws {
        let clock = SyncEngineTests.Clock()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("flushtest-\(UUID().uuidString)")
        let dbA = try AppDatabase.inMemory()
        let storeA = JobStore(dbA)
        _ = try seed(storeA, "1")
        _ = try seed(storeA, "2")
        let a = SyncEngine(db: dbA, deviceId: "A1B2", now: clock.now)
        let dbB = try AppDatabase.inMemory()
        let b = SyncEngine(db: dbB, deviceId: "C3D4", now: clock.now)

        try a.export(to: folder)
        try b.importChanges(from: folder)
        XCTAssertEqual(try externalIds(dbB), ["1", "2"])

        XCTAssertEqual(try storeA.flushInbox(olderThan: nil), 2)
        let exported = try a.export(to: folder)
        // Two jobs, each a `job` tombstone plus a `triage` tombstone.
        XCTAssertEqual(exported.tombstones, 4)
        XCTAssertEqual(exported.live, 0)

        let imported = try b.importChanges(from: folder)
        XCTAssertEqual(imported.deletes, 2)
        XCTAssertTrue(try externalIds(dbB).isEmpty)
    }
}
