import XCTest
@testable import JobsmithKit

/// Port of the desktop tests/test_fact_guard.py: names, numbers and credentials
/// the candidate's own material doesn't back. All text here is synthetic.
final class FactGuardTests: XCTestCase {
    private func profile(certifications: [String] = ["AWS Solutions Architect"],
                         facts: [String] = ["Speaks at regional meetups.", "Managed a budget of $2.5M"]) -> Profile {
        Profile(
            fullName: "Sam Example",
            summary: "Backend engineer who ships reliable services.",
            skills: ["Python", "PostgreSQL", "CI/CD", "AWS"],
            experience: [
                WorkExperience(title: "Senior Engineer", company: "Northwind Labs",
                               startDate: "2019-03", endDate: "Present",
                               bullets: ["Cut deploy time by 40%", "Served 4,000 daily users",
                                         "Mentored 3 engineers"]),
                WorkExperience(title: "Engineer", company: "Contoso Works",
                               startDate: "2016-06", endDate: "2019-02",
                               bullets: ["Built the billing service"]),
            ],
            education: [Education(degree: "B.S. Computer Science",
                                  school: "Example State University", year: "2016")],
            certifications: certifications,
            facts: facts)
    }

    private let job = Job(from: NormalizedJob(
        source: "t", externalId: "e1", title: "Platform Engineer", company: "Fabrikam",
        location: "Remote",
        description: "Fabrikam needs a platform engineer. 5+ years of Python. Kubernetes a plus."))

    private func flags(_ text: String, level: HonestyConfig.Level = .honest,
                       profile: Profile? = nil, job: Job?? = nil,
                       appFacts: [String] = [], extra: [String] = []) -> [String] {
        FactGuard.check(text, profile: profile ?? self.profile(), job: job ?? self.job,
                        honesty: level, appFacts: appFacts, extra: extra)
    }

    // MARK: numbers

    func testFormattingVariantsAreTheSameNumber() {
        for variant in ["4,000", "4000", "4k", "4K", "4 000", "4,000+"] {
            XCTAssertEqual(flags("Served \(variant) daily users."), [], variant)
        }
    }

    func testPercentagesAndPlainValues() {
        XCTAssertEqual(flags("Cut deploy time by 40%."), [])
        XCTAssertEqual(flags("Cut deploy time by 60%."), ["60%"])
    }

    func testInventedMetricIsFlagged() {
        XCTAssertEqual(flags("Served 90,000 daily users."), ["90,000"])
    }

    func testScaledWords() {
        XCTAssertEqual(flags("Managed a $2.5 million budget."), [])
        XCTAssertEqual(flags("Managed a $2.5M budget."), [])
        XCTAssertEqual(flags("Managed a $9 million budget."), ["9 million"])
    }

    func testNumberWords() {
        XCTAssertEqual(flags("Mentored three engineers."), [])
        XCTAssertEqual(flags("Mentored seven engineers."), ["seven"])
        XCTAssertEqual(flags("One of the best teams."), [])  // not a claim
    }

    func testNumbersFromThePostingAreFine() {
        XCTAssertEqual(flags("Over 5 years of Python."), [])
    }

    func testYearsOfExperienceTheProfileAddsUpTo() {
        // 2019-03..2026-11 = 7y8m, plus 2016-06..2019-02 = 2y8m -> 10 years
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 1
        let today = Calendar(identifier: .gregorian).date(from: parts)!
        let sources = FactGuard.buildSources(profile: profile(), job: job, today: today)
        XCTAssertEqual(FactGuard.unverifiedFacts(in: "10 years of experience", sources: sources), [])
        XCTAssertEqual(FactGuard.unverifiedFacts(in: "15 years of experience", sources: sources), ["15"])
    }

    func testProfileDatesAreBacked() {
        XCTAssertEqual(flags("Dates: Mar 2019 - Present\nDates: Jun 2016 - Feb 2019"), [])
        XCTAssertEqual(flags("Dates: 2011 - 2014"), ["2011", "2014"])
    }

    // MARK: names and credentials

    func testProfileAndPostingNamesAreFine() {
        XCTAssertEqual(flags("Worked at Northwind Labs and Contoso Works; excited about Fabrikam."), [])
    }

    func testInventedEmployerIsFlagged() {
        XCTAssertEqual(flags("I worked with engineers at Globex Corporation."), ["Globex", "Corporation"])
    }

    func testSentenceStartsAreNotNames() {
        XCTAssertEqual(flags("Built the billing service. Reliable systems matter. Shipping is a habit."), [])
        XCTAssertEqual(flags("- Led the work\n- Improved the pipeline"), [])
    }

    func testAcronymsAreCheckedEvenAtSentenceStart() {
        XCTAssertEqual(flags("AWS is my main cloud."), [])
        XCTAssertEqual(flags("PMP lead."), ["PMP"])
    }

    func testCredentialWords() {
        XCTAssertEqual(flags("Certified in the AWS Solutions Architect track."), [])  // profile lists one
        XCTAssertEqual(flags("Chartered engineer."), ["Chartered"])
        XCTAssertEqual(flags("I am a licensed pilot."), ["licensed"])
        XCTAssertEqual(flags("Certified in cloud.", profile: profile(certifications: [])), ["Certified"])
    }

    func testSectionHeadersAndLabelsAreQuiet() {
        let resume = """
        SUMMARY
        Backend engineer.

        TECHNICAL SKILLS
        Python, AWS

        EXPERIENCE
        Title: Senior Engineer
        Company: Northwind Labs
        Dates: Mar 2019 - Present
        - Built the billing service

        EDUCATION
        Degree: B.S. Computer Science
        School: Example State University
        Year: 2016

        CERTIFICATIONS
        - AWS Solutions Architect

        """
        XCTAssertEqual(flags(resume), [])
    }

    func testLetterFurnitureIsQuiet() {
        let letter = "Dear Hiring Manager,\n\nI am excited about Fabrikam.\n\nSincerely,\nSam Example"
        XCTAssertEqual(flags(letter), [])
    }

    func testPossessiveAndMonths() {
        XCTAssertEqual(flags("In March I joined Fabrikam's mission, and in May I left Northwind's team."), [])
    }

    func testEachItemReportedOnceInOrder() {
        // The first capital starts the sentence, the repeats are one flag each.
        XCTAssertEqual(flags("Zeta hired 77 people for Zeta and Zeta, then 77 more."), ["Zeta", "77"])
    }

    // MARK: sources

    func testProfileFactsAndApplicationFactsBackClaims() {
        XCTAssertEqual(flags("Spoke at regional meetups."), [])
        XCTAssertEqual(flags("Won the Quartz Award."), ["Quartz", "Award"])
        XCTAssertEqual(flags("Won the Quartz Award in 2020.", appFacts: ["Won the Quartz Award in 2020"]), [])
    }

    func testInstructionsTheUserTypedCountAsSources() {
        XCTAssertEqual(flags("Mentored 12 engineers.", extra: ["Mention that I mentored 12 engineers"]), [])
    }

    func testSecretsNeverBecomeSources() {
        // The iOS profile has no password field; the flattener still drops the keys by name.
        XCTAssertEqual(FactGuard.flatten(["workday_password": "hunter2-secret-99", "ok": "fine"]), ["fine"])
        XCTAssertNotEqual(flags("My password is hunter2-secret-99."), [])
    }

    func testRecordIdsDoNotBackNumbers() {
        // UUID digits in the profile must not make arbitrary numbers look known.
        let sources = FactGuard.buildSources(profile: profile(), job: nil)
        XCTAssertFalse(sources.text.contains(profile().experience[0].id.uuidString.lowercased()))
    }

    func testEmptyProfileAndNoJobDoNotThrow() {
        XCTAssertEqual(flags("Built things at Acme Corp.", profile: Profile(facts: []), job: .some(nil)),
                       ["Acme", "Corp"])
        XCTAssertEqual(FactGuard.check("Hello", profile: nil, job: nil, honesty: .honest), [])
    }

    // MARK: levels

    func testOnlyHonestAndTailoredAreChecked() {
        for (level, expected) in [(HonestyConfig.Level.honest, true), (.tailored, true),
                                  (.embellished, false), (.fabricated, false)] {
            XCTAssertEqual(!flags("Served 90,000 users at Globex.", level: level).isEmpty, expected,
                           "\(level)")
        }
    }

    func testBlankTextIsClean() {
        XCTAssertEqual(flags("   "), [])
    }

    func testCheckDocumentsShape() {
        let out = FactGuard.checkDocuments(resume: "Served 90,000 users.", coverLetter: "I admire Fabrikam.",
                                           profile: profile(), job: job, honesty: .honest)
        XCTAssertEqual(out, FactGuard.DocumentFlags(resume: ["90,000"], coverLetter: []))
        let off = FactGuard.checkDocuments(resume: "Served 90,000 users.", coverLetter: "x",
                                           profile: profile(), job: job, honesty: .fabricated)
        XCTAssertEqual(off, FactGuard.DocumentFlags())
    }

    // MARK: notice

    func testNoticeIsQuietWhenCleanAndCapsLongLists() {
        XCTAssertNil(FactGuard.notice([]))
        XCTAssertEqual(FactGuard.notice(["a", "b"]), "Check this: a, b")
        let many = (1...10).map(String.init)
        XCTAssertEqual(FactGuard.notice(many, limit: 3), "Check this: 1, 2, 3 and 7 more")
    }
}
