import XCTest
import GRDB
@testable import JobsmithKit

/// Requirement coverage ("covers N of M"): the tolerant parser, scoring with
/// and without a `requirements` array, persistence and the Best coverage order.
/// Mirrors the desktop tests/test_requirement_coverage.py.
final class RequirementCoverageTests: XCTestCase {
    private let good = """
    {"score": 70, "reasoning": "ok", "matched_skills": ["Python"], "requirements": [
      {"text": "5+ years of Python", "kind": "must", "met": true, "evidence": "Data Engineer at Example Corp, 2018-present"},
      {"text": "Airflow experience", "kind": "nice", "met": false, "evidence": null},
      {"text": "Bachelor's degree", "kind": "must", "met": false}
    ]}
    """

    func testParseGood() throws {
        let cov = try XCTUnwrap(RequirementCoverage.parse(good))
        XCTAssertEqual([cov.covered, cov.total, cov.missingMust], [1, 3, 1])
        XCTAssertEqual(cov.requirements[0],
                       .init(text: "5+ years of Python", kind: "must", met: true,
                             evidence: "Data Engineer at Example Corp, 2018-present"))
        XCTAssertNil(cov.requirements[2].evidence)
        XCTAssertEqual(cov.badge, "1/3")
    }

    func testSurvivesProseAndCodeFences() {
        XCTAssertEqual(RequirementCoverage.parse("Here you go:\n```json\n\(good)\n```")?.total, 3)
    }

    func testPartialKeepsUsableItems() throws {
        let data = """
        {"requirements": [
          {"text": "Good one", "kind": "MUST", "met": true},
          {"text": "No met flag", "kind": "must"},
          {"text": "met is a string", "met": "yes"},
          {"text": "met is a number", "met": 1},
          {"text": "", "met": false},
          "not a dict",
          {"text": "Unknown kind", "kind": "banana", "met": false, "evidence": 5}
        ]}
        """
        let cov = try XCTUnwrap(RequirementCoverage.parse(data))
        XCTAssertEqual(cov.requirements.map { [$0.text, $0.kind, "\($0.met)", $0.evidence ?? "nil"] },
                       [["Good one", "must", "true", "nil"], ["Unknown kind", "nice", "false", "nil"]])
    }

    func testMustSynonyms() throws {
        let data = #"{"requirements": [{"text":"a","kind":"must-have","met":true},{"text":"b","kind":"Required","met":true},{"text":"c","kind":"preferred","met":true}]}"#
        let kinds = try XCTUnwrap(RequirementCoverage.parse(data)).requirements.map(\.kind)
        XCTAssertEqual(kinds, ["must", "must", "nice"])
    }

    func testGarbageIsNilAndNeverThrows() {
        for text in ["", "no json at all", "{broken", "[]", "null", #"{"score": 50}"#,
                     #"{"requirements": "none"}"#, #"{"requirements": []}"#,
                     #"{"requirements": [1, 2]}"#, #"{"requirements": {"a": 1}}"#] {
            XCTAssertNil(RequirementCoverage.parse(text), text)
        }
        XCTAssertNil(RequirementCoverage.parse(nil))
    }

    func testListIsCapped() {
        let items = (0..<50).map { #"{"text": "req \#($0)", "met": true}"# }.joined(separator: ",")
        XCTAssertEqual(RequirementCoverage.parse(#"{"requirements": [\#(items)]}"#)?.total,
                       RequirementCoverage.maxRequirements)
    }

    func testTextAndEvidenceAreClipped() throws {
        let long = String(repeating: "x", count: 500)
        let cov = try XCTUnwrap(RequirementCoverage.parse(
            #"{"requirements": [{"text": "\#(long)", "met": true, "evidence": "\#(long)"}]}"#))
        XCTAssertEqual(cov.requirements[0].text.count, 200)
        XCTAssertEqual(cov.requirements[0].evidence?.count, 200)
    }

    func testJSONRoundTripKeepsTheDesktopShape() throws {
        let cov = try XCTUnwrap(RequirementCoverage.parse(good))
        let json = try XCTUnwrap(cov.json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["requirements", "covered", "total", "missing_must"])
        let first = try XCTUnwrap((object["requirements"] as? [[String: Any]])?[1])
        XCTAssertTrue(first["evidence"] is NSNull, "evidence is an explicit null, like the desktop")
        XCTAssertEqual(RequirementCoverage.decode(json), cov)
    }

    func testDecodeRejectsEmptyOrMalformed() {
        XCTAssertNil(RequirementCoverage.decode(nil))
        XCTAssertNil(RequirementCoverage.decode("nope"))
        XCTAssertNil(RequirementCoverage.decode(#"{"requirements": [], "covered": 0, "total": 0, "missing_must": 0}"#))
    }

    // MARK: scoring

    private func job() -> Job {
        Job(from: NormalizedJob(source: "t", externalId: "e", title: "Analyst",
                                company: "Example Corp", description: "d"))
    }

    func testScoreKeepsTheParsedScoreAndAddsCoverage() async throws {
        let engine = MockAIEngine()
        engine.register("career advisor", .text(good))
        let result = try await ScoringService.score(job: job(), profile: Profile(fullName: "Sample Candidate"),
                                                    config: AppConfig(), engine: engine)
        XCTAssertEqual(result.score, 70)
        XCTAssertEqual(result.reasoning, "ok")
        XCTAssertEqual(RequirementCoverage.decode(result.coverageJSON)?.covered, 1)
        // The default prompt asks for them.
        XCTAssertTrue(try XCTUnwrap(engine.requests.first).user.contains("\"requirements\""))
    }

    func testOldPromptOverrideWithoutRequirementsStillScores() async throws {
        let engine = MockAIEngine()
        engine.register("OLDOVERRIDE", .text(#"{"score": 50, "reasoning": "ok", "matched_skills": ["Python"]}"#))
        var config = AppConfig()
        config.promptOverrides["score_job_fit"] = "OLDOVERRIDE for {job_title}. Return score JSON."
        let result = try await ScoringService.score(job: job(), profile: Profile(), config: config, engine: engine)
        XCTAssertEqual(result.score, 50)
        XCTAssertEqual(result.reasoning, "ok")
        XCTAssertNil(result.coverageJSON)
    }

    func testRequirementsWithoutSkillListsStillYieldCoverage() async throws {
        let engine = MockAIEngine()
        engine.register("career advisor", .text(
            #"{"score": 40, "reasoning": "r", "requirements": [{"text": "x", "kind": "must", "met": false}]}"#))
        let result = try await ScoringService.score(job: job(), profile: Profile(), config: AppConfig(), engine: engine)
        XCTAssertNil(result.matchReportJSON.flatMap { LenientJSON.parseObject($0)?["requirements"] })
        XCTAssertEqual(RequirementCoverage.decode(result.coverageJSON)?.missingMust, 1)
    }

    /// The pinned cross-language parser must not learn about requirements.
    func testScoreResponseParserIsUnchangedByRequirements() throws {
        let parsed = try XCTUnwrap(ScoreResponseParser.parse(good))
        XCTAssertEqual(parsed.score, 70)
        XCTAssertEqual(parsed.reasoning, "ok")
        let report = try XCTUnwrap(parsed.matchReportJSON.flatMap { LenientJSON.parseObject($0) })
        XCTAssertNil(report["requirements"])
        XCTAssertNil(report["coverage"])
    }

    // MARK: storage

    func testCoverageIsStoredWithTheScoreAndReplacedByTheNext() throws {
        let db = try AppDatabase.inMemory()
        let store = JobStore(db)
        try store.upsert([NormalizedJob(source: "t", externalId: "e", title: "Analyst", company: "Example Corp")])
        let id = try XCTUnwrap(store.jobs().first).id
        let cov = try XCTUnwrap(RequirementCoverage.parse(good))

        try store.setScore(jobId: id, score: 70, reasoning: "ok", matchReport: nil, coverage: cov.json)
        XCTAssertEqual(try XCTUnwrap(store.job(id: id)).requirementCoverage, cov)

        // A re-score without requirements clears the stale list.
        try store.setScore(jobId: id, score: 55, reasoning: "ok", matchReport: nil)
        XCTAssertNil(try XCTUnwrap(store.job(id: id)).requirementCoverage)
    }

    func testMigrationAddsTheColumnAndTheFactsTable() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { dbc in
            XCTAssertTrue(try dbc.columns(in: "jobs").contains { $0.name == "coverage" })
            XCTAssertTrue(try dbc.tableExists("application_facts"))
        }
    }

    // MARK: Best coverage

    private func scored(_ id: String, fit: Double?, covered: Int?, total: Int = 4, missingMust: Int = 0,
                        date: String = "2026-01-01T00:00:00Z") -> Job {
        var job = Job(from: NormalizedJob(source: "t", externalId: id, title: id))
        job.fitScore = fit
        job.dateDiscovered = date
        if let covered {
            job.coverage = RequirementCoverage(
                requirements: (0..<total).map { .init(text: "r\($0)", kind: "nice", met: $0 < covered) },
                covered: covered, total: total, missingMust: missingMust).json
        }
        return job
    }

    func testBestCoverageOrder() {
        let none = scored("none", fit: 99, covered: nil)
        let low = scored("low", fit: 90, covered: 1)
        let highManyGaps = scored("highGaps", fit: 50, covered: 3, missingMust: 2)
        let highFewGaps = scored("highFew", fit: 50, covered: 3, missingMust: 0)
        let highFewBetterFit = scored("highFewFit", fit: 80, covered: 3, missingMust: 0)
        let sorted = [none, low, highManyGaps, highFewGaps, highFewBetterFit].sorted(by: RequirementCoverage.isOrderedBefore)
        XCTAssertEqual(sorted.map(\.title), ["highFewFit", "highFew", "highGaps", "low", "none"])
    }
}
