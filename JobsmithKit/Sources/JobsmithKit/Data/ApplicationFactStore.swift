import Foundation
import GRDB

/// One short true statement the candidate keeps for a single application
/// ("Facts for this application"). Device-local, like the desktop's
/// `application_facts` table; deleted with its application.
public struct ApplicationFact: Codable, Equatable, Sendable, Identifiable,
                               FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "application_facts"

    public var id: Int64?
    public var applicationId: String
    public var text: String
    public var createdAt: String

    public init(applicationId: String, text: String) {
        self.id = nil
        self.applicationId = applicationId
        self.text = text
        self.createdAt = ISO8601DateFormatter().string(from: Date())
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Port of the desktop `get/add/update/delete_application_fact` helpers.
/// Validation (non-empty, 1000 chars, 50 per application) lives in
/// `CandidateFacts`.
public struct ApplicationFactStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    /// The facts for one application, oldest first.
    public func facts(applicationId: String) throws -> [ApplicationFact] {
        try db.writer.read {
            try ApplicationFact.filter(Column("applicationId") == applicationId)
                .order(Column("id")).fetchAll($0)
        }
    }

    public func texts(applicationId: String) throws -> [String] {
        try facts(applicationId: applicationId).map(\.text)
    }

    /// The fact texts of whatever application a job currently has — what a
    /// re-tailor reads before it replaces the draft, then copies to the new one.
    public func texts(jobId: String) throws -> [String] {
        try db.writer.read { dbc in
            try String.fetchAll(dbc, sql: """
                SELECT f.text FROM application_facts f
                JOIN applications a ON a.id = f.applicationId
                WHERE a.jobId = ? ORDER BY f.id
                """, arguments: [jobId])
        }
    }

    /// Add one fact. Throws `CandidateFacts.FactError` for empty/overlong text
    /// or when the application already has the maximum.
    @discardableResult
    public func add(applicationId: String, text: String) throws -> ApplicationFact {
        let clean = try CandidateFacts.clean(text)
        return try db.writer.write { dbc in
            let count = try ApplicationFact.filter(Column("applicationId") == applicationId)
                .fetchCount(dbc)
            try CandidateFacts.checkNewCount(count)
            var fact = ApplicationFact(applicationId: applicationId, text: clean)
            try fact.insert(dbc)
            return fact
        }
    }

    /// Add several facts (a re-tailored draft inheriting the old one's); stops
    /// quietly at the cap and skips blanks.
    public func add(applicationId: String, texts: [String]) throws {
        for text in texts {
            do { try add(applicationId: applicationId, text: text) }
            catch is CandidateFacts.FactError { continue }
        }
    }

    public func update(id: Int64, text: String) throws {
        let clean = try CandidateFacts.clean(text)
        try db.writer.write {
            try $0.execute(sql: "UPDATE application_facts SET text = ? WHERE id = ?",
                           arguments: [clean, id])
        }
    }

    public func delete(id: Int64) throws {
        try db.writer.write {
            try $0.execute(sql: "DELETE FROM application_facts WHERE id = ?", arguments: [id])
        }
    }
}
