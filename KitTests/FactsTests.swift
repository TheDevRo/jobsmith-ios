import XCTest
@testable import JobsmithKit

/// "Facts about me" / "Facts for this application": validation, the prompt
/// block, the per-application store, and where the facts reach the prompts.
final class CandidateFactsTests: XCTestCase {
    func testCleanTrimsAndRejectsEmptyAndOverlong() throws {
        XCTAssertEqual(try CandidateFacts.clean("  Speaks at meetups \n"), "Speaks at meetups")
        XCTAssertThrowsError(try CandidateFacts.clean("   ")) {
            XCTAssertEqual($0 as? CandidateFacts.FactError, .empty)
        }
        XCTAssertNoThrow(try CandidateFacts.clean(String(repeating: "a", count: 1000)))
        XCTAssertThrowsError(try CandidateFacts.clean(String(repeating: "a", count: 1001))) {
            XCTAssertEqual($0 as? CandidateFacts.FactError, .tooLong)
        }
    }

    func testCountCapIsFifty() throws {
        XCTAssertNoThrow(try CandidateFacts.checkNewCount(49))
        XCTAssertThrowsError(try CandidateFacts.checkNewCount(50)) {
            XCTAssertEqual($0 as? CandidateFacts.FactError, .tooMany)
        }
        XCTAssertThrowsError(try CandidateFacts.cleanList(Array(repeating: "x", count: 51)))
        XCTAssertEqual(try CandidateFacts.cleanList([" a ", "b"]), ["a", "b"])
    }

    func testUsableDropsBlanks() {
        XCTAssertEqual(CandidateFacts.usable(["  a ", "", "   ", "b"]), ["a", "b"])
    }

    func testBlockIsEmptyWithoutFacts() {
        XCTAssertEqual(CandidateFacts.block(aboutMe: [], aboutApplication: []), "")
        XCTAssertEqual(CandidateFacts.block(aboutMe: ["", ""], aboutApplication: [""]), "")
    }

    func testBlockTextMatchesTheDesktop() {
        let block = CandidateFacts.block(aboutMe: ["Speaks at meetups."],
                                         aboutApplication: ["Prefers small teams."],
                                         honesty: .honest)
        XCTAssertEqual(block, """

        FACTS FROM THE CANDIDATE
        The candidate wrote these themselves, so they are true. Use the ones that help this document, in your own words, rather than listing them. Where a fact says what to emphasise or how to come across, do that, staying within the facts.
        They count as part of the candidate's real background: you may state them even when the profile above doesn't mention them.
        About the candidate (every application):
        - Speaks at meetups.
        About this application:
        - Prefers small teams.

        """)
    }

    func testBackgroundSentenceOnlyForTheStrictLevels() {
        let sentence = "They count as part of the candidate's real background"
        for level in [HonestyConfig.Level.honest, .tailored] {
            XCTAssertTrue(CandidateFacts.block(aboutMe: ["x"], aboutApplication: [], honesty: level)
                .contains(sentence))
        }
        for level in [HonestyConfig.Level.embellished, .fabricated] {
            XCTAssertFalse(CandidateFacts.block(aboutMe: ["x"], aboutApplication: [], honesty: level)
                .contains(sentence))
        }
    }

    func testOnlyTheScopesWithFactsGetAHeading() {
        let onlyMe = CandidateFacts.block(aboutMe: ["a"], aboutApplication: [])
        XCTAssertTrue(onlyMe.contains("About the candidate (every application):"))
        XCTAssertFalse(onlyMe.contains("About this application:"))
        let onlyApp = CandidateFacts.block(aboutMe: [], aboutApplication: ["b"])
        XCTAssertFalse(onlyApp.contains("About the candidate"))
        XCTAssertTrue(onlyApp.contains("- b"))
    }
}

final class ApplicationFactStoreTests: XCTestCase {
    private func makeStores() throws -> (ApplicationFactStore, ApplicationStore, JobStore, AppDatabase) {
        let db = try AppDatabase.inMemory()
        return (ApplicationFactStore(db), ApplicationStore(db), JobStore(db), db)
    }

    private func application(_ jobs: JobStore, _ apps: ApplicationStore, external: String = "e1") throws -> Application {
        try jobs.upsert([NormalizedJob(source: "t", externalId: external, title: "Engineer", company: "Example Corp")])
        let job = try XCTUnwrap(jobs.jobs().first { $0.externalId == external })
        return try apps.createOrReplace(jobId: job.id, resume: "R", coverLetter: "C",
                                        honestyLevel: "honest", stylePreset: "ledger")
    }

    func testAddListEditDelete() throws {
        let (facts, apps, jobs, _) = try makeStores()
        let app = try application(jobs, apps)
        let first = try facts.add(applicationId: app.id, text: "  Prefers small teams  ")
        try facts.add(applicationId: app.id, text: "Open to relocation")
        XCTAssertEqual(try facts.texts(applicationId: app.id), ["Prefers small teams", "Open to relocation"])

        try facts.update(id: try XCTUnwrap(first.id), text: "Prefers tiny teams")
        XCTAssertEqual(try facts.texts(applicationId: app.id).first, "Prefers tiny teams")

        try facts.delete(id: try XCTUnwrap(first.id))
        XCTAssertEqual(try facts.texts(applicationId: app.id), ["Open to relocation"])
    }

    func testLimitsAreEnforced() throws {
        let (facts, apps, jobs, _) = try makeStores()
        let app = try application(jobs, apps)
        XCTAssertThrowsError(try facts.add(applicationId: app.id, text: "  "))
        XCTAssertThrowsError(try facts.add(applicationId: app.id, text: String(repeating: "x", count: 1001)))
        for i in 0..<CandidateFacts.maxFacts { try facts.add(applicationId: app.id, text: "fact \(i)") }
        XCTAssertThrowsError(try facts.add(applicationId: app.id, text: "one too many")) {
            XCTAssertEqual($0 as? CandidateFacts.FactError, .tooMany)
        }
        XCTAssertEqual(try facts.facts(applicationId: app.id).count, 50)
    }

    func testFactsAreRemovedWithTheirApplicationAndCarriedOverByReTailor() throws {
        let (facts, apps, jobs, _) = try makeStores()
        let old = try application(jobs, apps)
        try facts.add(applicationId: old.id, text: "Keep: prefers small teams.")
        let jobId = old.jobId
        let carried = try facts.texts(jobId: jobId)
        XCTAssertEqual(carried, ["Keep: prefers small teams."])

        // A re-tailor replaces the application; the cascade removes the old facts.
        let replacement = try apps.createOrReplace(jobId: jobId, resume: "R2", coverLetter: "C2",
                                                   honestyLevel: "honest", stylePreset: "ledger")
        XCTAssertEqual(try facts.texts(applicationId: old.id), [])
        try facts.add(applicationId: replacement.id, texts: carried)
        XCTAssertEqual(try facts.texts(jobId: jobId), ["Keep: prefers small teams."])
    }

    func testBulkAddSkipsBlanksAndStopsAtTheCap() throws {
        let (facts, apps, jobs, _) = try makeStores()
        let app = try application(jobs, apps)
        try facts.add(applicationId: app.id, texts: ["a", "  ", "b"] + (0..<60).map { "n\($0)" })
        XCTAssertEqual(try facts.facts(applicationId: app.id).count, CandidateFacts.maxFacts)
    }
}

/// Answers every prompt with the same text and keeps what it was asked.
private final class RecordingEngine: AIEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [CompletionRequest] = []
    var requests: [CompletionRequest] { lock.lock(); defer { lock.unlock() }; return seen }

    func complete(_ req: CompletionRequest, config: AIConfig) async throws -> String {
        lock.lock(); seen.append(req); lock.unlock()
        return "SUMMARY\nDone."
    }
    func listModels(config: AIConfig) async throws -> [String] { [] }
    func pingChat(model: String, config: AIConfig) async throws {}
}

final class FactsInPromptsTests: XCTestCase {
    private func engine() -> RecordingEngine { RecordingEngine() }

    func testTailorResumeAndCoverLetterCarryBothFactLists() async throws {
        let engine = engine()
        var profile = aiTestProfile()
        profile.facts = ["Speaks at regional meetups."]
        _ = try await TailoringService.tailorResume(job: aiTestJob(), profile: profile, config: AppConfig(),
                                                    engine: engine, appFacts: ["Prefers small teams."])
        _ = try await TailoringService.coverLetter(job: aiTestJob(), profile: profile, config: AppConfig(),
                                                   engine: engine, appFacts: ["Prefers small teams."])
        XCTAssertEqual(engine.requests.count, 2)
        for request in engine.requests {
            XCTAssertTrue(request.user.contains("FACTS FROM THE CANDIDATE"))
            XCTAssertTrue(request.user.contains("- Speaks at regional meetups."))
            XCTAssertTrue(request.user.contains("- Prefers small teams."))
        }
    }

    func testRevisionsCarryFactsEvenWithAnOverriddenTemplate() async throws {
        let engine = engine()
        var config = AppConfig()
        config.promptOverrides["revise_resume"] = "Edit: {user_instructions}\n{current_resume}"
        config.promptOverrides["revise_cover_letter"] = "Edit: {user_instructions}\n{current_letter}"
        var profile = aiTestProfile()
        profile.facts = ["Speaks at regional meetups."]
        _ = try await TailoringService.reviseResume(currentResume: "SUMMARY\nOld", instructions: "tighten",
                                                    job: aiTestJob(), profile: profile, config: config,
                                                    engine: engine, appFacts: ["Open to relocation."])
        _ = try await TailoringService.reviseCoverLetter(currentLetter: "Dear Team,", instructions: "tighten",
                                                         job: aiTestJob(), profile: profile, config: config,
                                                         engine: engine, appFacts: ["Open to relocation."])
        for request in engine.requests {
            XCTAssertTrue(request.user.contains("- Speaks at regional meetups."))
            XCTAssertTrue(request.user.contains("- Open to relocation."))
        }
    }

    func testNoFactsMeansNoBlock() async throws {
        let engine = engine()
        _ = try await TailoringService.tailorResume(job: aiTestJob(), profile: aiTestProfile(),
                                                    config: AppConfig(), engine: engine)
        XCTAssertFalse(try XCTUnwrap(engine.requests.first).user.contains("FACTS FROM THE CANDIDATE"))
    }

    func testApplyAnswersCarryFacts() async throws {
        let engine = engine()
        var profile = aiTestProfile()
        profile.facts = ["Speaks at regional meetups."]
        let field = FieldDescriptor(fieldId: "f1", label: "Why do you want this job?")
        _ = await FieldMapper.essayAnswer(field: field, profile: profile,
                                          job: ApplyJobContext(jobId: "j", title: "Engineer", company: "Example Corp"),
                                          config: AppConfig(), engine: engine,
                                          appFacts: ["Prefers small teams."])
        let user = try XCTUnwrap(engine.requests.first).user
        XCTAssertTrue(user.contains("- Speaks at regional meetups."))
        XCTAssertTrue(user.contains("- Prefers small teams."))
    }
}

/// `Profile.facts` is local: the vendored profile sync contract doesn't carry it.
final class ProfileFactsSyncTests: XCTestCase {
    func testFactsSurviveAnImportAndAreNeverExported() throws {
        var local = Profile(fullName: "Sample Candidate")
        local.facts = ["Speaks at regional meetups."]
        let snapshot = SyncManager.profileToDict(local)

        // Export: the canonical record doesn't carry facts.
        XCTAssertNil(SyncEntities.profileIOSToCanonical(snapshot)["facts"])

        // Import of a record that has a `facts` key of its own (a desktop profile):
        // the engine merges mapped fields over the local snapshot.
        let incoming: [String: JSONValue] = [
            "full_name": .string("Sample Candidate"),
            "summary": .string("From the desktop"),
            "facts": .array([.string("Desktop-side fact")]),
        ]
        let merged = snapshot.merging(SyncEntities.profileCanonicalToIOS(incoming)) { _, new in new }
        let result = SyncManager.dictToProfile(merged)
        XCTAssertEqual(result.summary, "From the desktop")
        XCTAssertEqual(result.facts, ["Speaks at regional meetups."])
    }

    func testOldProfilesWithoutFactsStillDecode() throws {
        let json = #"{"fullName":"Sample Candidate","skills":["Python"]}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.facts, [])
        XCTAssertEqual(profile.skills, ["Python"])
    }

    func testProfileFactsRoundTripThroughCodable() throws {
        var profile = Profile()
        profile.facts = ["One", "Two"]
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: data).facts, ["One", "Two"])
    }
}
