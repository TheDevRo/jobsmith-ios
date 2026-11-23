import XCTest
@testable import JobsmithKit

/// Declarative JSON portals: strict format validation, the host allowlist on
/// every hop, mapping of the three bundled portals from synthetic bodies, the
/// feed and schema_org kinds, off-by-default wiring and failure isolation.
/// Offline: HTTP goes through an injected transport. Mirrors the desktop
/// tests/job_sources/test_portals.py (no recorded third-party fixtures).
final class PortalValidationTests: XCTestCase {
    static func good(_ mutate: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var base: [String: Any] = [
            "id": "demo", "name": "Demo", "version": "1.0.0",
            "homepage": "https://demo.example/", "terms_url": "https://demo.example/terms",
            "free": true, "hosts": ["api.demo.example"], "kind": "json_api",
            "request": ["url": "https://api.demo.example/jobs?q={query}&page={page}", "max_pages": 2],
            "items": "data.jobs",
            "fields": ["title": "title", "url": "link", "company": "org.name"],
        ]
        mutate(&base)
        return base
    }

    static func portal(_ raw: [String: Any]) throws -> Portal {
        try Portal.parse(data: JSONSerialization.data(withJSONObject: raw))
    }

    private func assertRejected(_ raw: [String: Any], _ fragment: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Self.portal(raw), file: file, line: line) { error in
            if let fragment {
                XCTAssertTrue((error as? Portal.ValidationError)?.message.contains(fragment) == true,
                              "\(error) should mention \(fragment)", file: file, line: line)
            }
        }
    }

    func testGoodFileIsAccepted() throws {
        let portal = try Self.portal(Self.good())
        XCTAssertEqual(portal.id, "demo")
        XCTAssertEqual(portal.maxPages, 2)
        XCTAssertEqual(portal.maxQueries, 3)
    }

    func testBundledPortalsAreValidAndHttpsOnly() {
        XCTAssertEqual(PortalCatalog.bundled.map(\.id), ["himalayas", "jobicy", "remotive"])
        for portal in PortalCatalog.bundled {
            XCTAssertTrue(portal.free)
            XCTAssertTrue(portal.termsURL.hasPrefix("https://"))
            XCTAssertTrue(portal.requestURL.hasPrefix("https://"))
            XCTAssertNotNil(portal.attribution)
        }
        let remotive = PortalCatalog.portal(id: "remotive")
        XCTAssertEqual(remotive?.minIntervalMinutes, 360)
        XCTAssertEqual(remotive?.maxQueries, 1)
        XCTAssertEqual(PortalCatalog.portal(id: "himalayas")?.maxPages, 2)
        XCTAssertEqual(PortalCatalog.portal(id: "jobicy")?.delaySeconds, 2)
    }

    func testUnknownKeysAreRejectedAtEveryLevel() {
        assertRejected(Self.good { $0["extra"] = 1 }, "unknown key")
        assertRejected(Self.good { $0["request"] = ["url": "https://api.demo.example/j", "method": "POST"] }, "unknown key")
        assertRejected(Self.good { $0["defaults"] = ["company": "x"] }, "unknown key")
    }

    func testUnknownJobFieldIsRejected() {
        assertRejected(Self.good { $0["fields"] = ["title": "t", "url": "u", "salary": "s"] }, "unknown job field")
    }

    func testNonHttpsRequestIsRejected() {
        for url in ["http://api.demo.example/jobs", "ftp://api.demo.example/jobs", "//api.demo.example/jobs"] {
            assertRejected(Self.good { $0["request"] = ["url": url] }, "https")
        }
    }

    func testNonHttpsHomepageOrTermsIsRejected() {
        assertRejected(Self.good { $0["homepage"] = "http://demo.example/" }, "homepage")
        assertRejected(Self.good { $0["terms_url"] = "javascript:alert(1)" }, "terms_url")
    }

    func testHostOutsideTheAllowlistIsRejected() {
        assertRejected(Self.good { $0["request"] = ["url": "https://evil.example/jobs"] }, "not in hosts")
    }

    func testSneakyUrlsAreRejected() {
        for url in ["https://user:pw@api.demo.example/jobs", "https://api.demo.example:8443/jobs",
                    "https://{query}.demo.example/jobs", "https://api.demo.example/jobs?x={unknown}"] {
            assertRejected(Self.good { $0["request"] = ["url": url] })
        }
    }

    func testIPWildcardAndBareHostsAreRejected() {
        for host in ["127.0.0.1", "10.0.0.5", "localhost", "*.demo.example", "Demo.example"] {
            assertRejected(Self.good { $0["hosts"] = [host] }, "hosts")
        }
    }

    func testKindRules() {
        assertRejected(Self.good { $0["kind"] = "graphql" }, "kind")
        assertRejected(Self.good { $0.removeValue(forKey: "items") }, "items")
        assertRejected(Self.good { $0["kind"] = "feed" }, "not used by feed")
        assertRejected(Self.good { $0["kind"] = "schema_org" }, "not used by schema_org")
    }

    func testLimitsAreCapped() {
        assertRejected(Self.good { $0["request"] = ["url": "https://api.demo.example/j?p={page}", "max_pages": 50] }, "max_pages")
        assertRejected(Self.good { $0["request"] = ["url": "https://api.demo.example/j", "max_queries": 4] }, "max_queries")
        assertRejected(Self.good { $0["request"] = ["url": "https://api.demo.example/j", "delay_seconds": 0.1] }, "delay_seconds")
        assertRejected(Self.good { $0["request"] = ["url": "https://api.demo.example/j?p={page}"] }, "max_pages")
        assertRejected(Self.good { $0["min_interval_minutes"] = 99999 }, "min_interval_minutes")
    }

    func testHeadersAreRestricted() throws {
        _ = try Self.portal(Self.good {
            $0["request"] = ["url": "https://api.demo.example/j", "headers": ["Authorization": "Bearer {api_key}"]]
        })
        for headers in [["Host": "x"], ["X-A": "{query}"], ["X-A": "a\nb"]] {
            assertRejected(Self.good { $0["request"] = ["url": "https://api.demo.example/j", "headers": headers] })
        }
        assertRejected(Self.good { $0["request"] = ["url": "https://api.demo.example/j?k={api_key}"] },
                       "only allowed in headers")
    }

    func testBadFilesAreSkippedNotRaised() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portals_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ raw: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: raw).write(to: dir.appendingPathComponent(name))
        }
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try write("extra.json", Self.good { $0["id"] = "extra"; $0["surprise"] = true })
        try write("fine.json", Self.good { $0["id"] = "fine" })
        try write("zdupe.json", Self.good { $0["id"] = "fine"; $0["name"] = "Second" })
        try write("reserved.json", Self.good { $0["id"] = "remoteok" })
        try write("big.json", Self.good { $0["name"] = String(repeating: "x", count: Portal.maxFileBytes + 1) })
        let loaded = PortalCatalog.load(from: dir, reserved: ["remoteok"])
        XCTAssertEqual(loaded.map(\.id), ["fine"])
        XCTAssertEqual(loaded.first?.name, "Demo", "the first file for an id wins")
    }
}

/// Collects the URLs a portal asked for and answers from a closure.
private final class FakeWeb: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    private var headerLog: [[String: String]] = []
    let respond: @Sendable (URL) -> PortalSource.Response

    init(_ respond: @escaping @Sendable (URL) -> PortalSource.Response) { self.respond = respond }

    var seen: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    var headers: [[String: String]] { lock.lock(); defer { lock.unlock() }; return headerLog }

    var transport: PortalSource.Transport {
        { [self] request in
            lock.lock()
            urls.append(request.url?.absoluteString ?? "")
            headerLog.append(request.allHTTPHeaderFields ?? [:])
            lock.unlock()
            return respond(request.url!)
        }
    }

    static func json(_ object: Any, status: Int = 200) -> PortalSource.Response {
        PortalSource.Response(status: status, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
    static func text(_ body: String, status: Int = 200) -> PortalSource.Response {
        PortalSource.Response(status: status, data: Data(body.utf8))
    }
    static func redirect(_ status: Int = 302, to location: String) -> PortalSource.Response {
        PortalSource.Response(status: status, data: Data(), headers: ["location": location])
    }
}

final class PortalFetchTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "portal-tests-\(UUID().uuidString)")
    }

    private func config(_ keywords: [String] = ["engineer"], exclude: [String] = []) -> AppConfig {
        var config = AppConfig()
        config.search.keywords = keywords
        config.search.excludeKeywords = exclude
        return config
    }

    private func source(_ portal: Portal, _ web: FakeWeb, now: @escaping @Sendable () -> Date = { Date() }) -> PortalSource {
        PortalSource(portal: portal, transport: web.transport, defaults: defaults, now: now, sleep: { _ in })
    }

    private func portal(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Portal {
        try PortalValidationTests.portal(PortalValidationTests.good(mutate))
    }

    private func titles(_ jobs: [NormalizedJob]) -> [String] { jobs.map(\.title) }

    private static let oneJob: [String: Any] = [
        "data": ["jobs": [["title": "Engineer", "link": "https://x.example/1", "org": ["name": "Example Corp"]]]],
    ]

    // MARK: request safety

    func testRedirectToAForeignHostIsBlocked() async throws {
        let web = FakeWeb { url in
            url.host == "api.demo.example" ? FakeWeb.redirect(to: "https://evil.example/steal")
                : FakeWeb.json(Self.oneJob)
        }
        let jobs = try await source(try portal(), web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs, [])
        XCTAssertEqual(web.seen, ["https://api.demo.example/jobs?q=engineer&page=1"])  // never reached evil.example
    }

    func testRedirectToHttpIsBlocked() async throws {
        let web = FakeWeb { _ in FakeWeb.redirect(301, to: "http://api.demo.example/jobs") }
        let jobs = try await source(try portal(), web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs, [])
        XCTAssertEqual(web.seen.count, 1)
    }

    func testRedirectWithinTheAllowlistIsFollowed() async throws {
        let web = FakeWeb { url in
            url.path == "/jobs" ? FakeWeb.redirect(301, to: "/v2/jobs?q=engineer") : FakeWeb.json(Self.oneJob)
        }
        let p = try portal { $0["request"] = ["url": "https://api.demo.example/jobs?q={query}"] }
        let jobs = try await source(p, web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(titles(jobs), ["Engineer"])
        XCTAssertEqual(web.seen.last, "https://api.demo.example/v2/jobs?q=engineer")
    }

    func testRedirectLoopIsCutOff() async throws {
        let web = FakeWeb { url in FakeWeb.redirect(to: url.absoluteString) }
        let jobs = try await source(try portal(), web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs, [])
        XCTAssertEqual(web.seen.count, Portal.maxRedirects + 1)
    }

    func testRequestBudgetIsConservative() async throws {
        let web = FakeWeb { url in
            FakeWeb.json(["data": ["jobs": [["title": "Engineer \(url.absoluteString)",
                                             "link": "https://x.example/\(url.query ?? "")"]]]])
        }
        let p = try portal { $0["request"] = ["url": "https://api.demo.example/j?q={query}&p={page}", "max_pages": 3] }
        _ = try await source(p, web).fetchJobs(config: config(["a", "b", "c", "d", "e"]), knownExternalIDs: [])
        XCTAssertEqual(web.seen.count, Portal.maxQueriesCap * 3)
        XCTAssertFalse(web.seen.contains { $0.contains("q=d") || $0.contains("q=e") })
    }

    func testHttpErrorKeepsEarlierResults() async throws {
        let web = FakeWeb { url in
            url.absoluteString.contains("page=2") ? FakeWeb.text("", status: 500) : FakeWeb.json(Self.oneJob)
        }
        let jobs = try await source(try portal(), web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs.count, 1)
    }

    func testBadJSONEndsThePortalQuietly() async throws {
        let web = FakeWeb { _ in FakeWeb.text("<html>not json</html>") }
        let jobs = try await source(try portal(), web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs, [])
    }

    func testMinIntervalIsHonoured() async throws {
        let web = FakeWeb { _ in FakeWeb.json(["data": ["jobs": []]]) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let p = try portal { $0["min_interval_minutes"] = 60 }
        let s = source(p, web, now: { clock.now })
        _ = try await s.fetchJobs(config: config(), knownExternalIDs: [])
        let n = web.seen.count
        XCTAssertGreaterThan(n, 0)
        _ = try await s.fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(web.seen.count, n, "a second run inside the interval makes no request")
        clock.advance(3700)
        _ = try await s.fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertGreaterThan(web.seen.count, n)
    }

    func testApiKeyHeaderIsLeftOutWhenThereIsNoKey() async throws {
        let web = FakeWeb { _ in FakeWeb.json(["data": ["jobs": []]]) }
        let p = try portal {
            $0["request"] = ["url": "https://api.demo.example/j",
                             "headers": ["Authorization": "Bearer {api_key}", "X-Plain": "ok"]]
        }
        _ = try await source(p, web).fetchJobs(config: config(), knownExternalIDs: [])
        let sent = try XCTUnwrap(web.headers.first)
        XCTAssertNil(sent["Authorization"])
        XCTAssertEqual(sent["X-Plain"], "ok")
        XCTAssertTrue(sent["User-Agent"]?.hasPrefix("Jobsmith") == true)
    }

    func testNoKeywordsMeansNoRequest() async throws {
        let web = FakeWeb { _ in FakeWeb.json([:]) }
        let jobs = try await source(try portal(), web).fetchJobs(config: config([]), knownExternalIDs: [])
        XCTAssertEqual(jobs, [])
        XCTAssertEqual(web.seen, [])
    }

    func testJavascriptUrlsAreDropped() async throws {
        let web = FakeWeb { _ in
            FakeWeb.json(["data": ["jobs": [["title": "Engineer", "link": "javascript:alert(1)"],
                                            ["title": "Engineer", "link": "https://x.example/ok"]]]])
        }
        let jobs = try await source(try portal(), web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs.map(\.url), ["https://x.example/ok"])
    }

    func testExcludeKeywordsApply() async throws {
        let web = FakeWeb { _ in
            FakeWeb.json(["data": ["jobs": [["title": "Staff Engineer", "link": "https://x.example/1"],
                                            ["title": "Engineer", "link": "https://x.example/2"]]]])
        }
        let jobs = try await source(try portal(), web).fetchJobs(config: config(exclude: ["staff"]), knownExternalIDs: [])
        XCTAssertEqual(jobs.map(\.url), ["https://x.example/2"])
    }

    // MARK: bundled portals, mapped from synthetic bodies

    private func bundled(_ id: String) throws -> Portal { try XCTUnwrap(PortalCatalog.portal(id: id)) }

    func testRemotiveMapsAndFiltersByKeywordLocally() async throws {
        let body: [String: Any] = ["jobs": [
            ["id": 11, "url": "https://remotive.com/remote-jobs/x-11", "title": "Rails Engineer",
             "company_name": "Example Corp", "candidate_required_location": "USA",
             "publication_date": "2026-11-19T14:58:42", "tags": ["ruby", "rails"],
             "description": "<p>Build <b>things</b></p>"],
            ["id": 12, "url": "https://remotive.com/remote-jobs/y-12", "title": "Chef",
             "company_name": "Other Corp", "candidate_required_location": "Anywhere", "tags": ["food"],
             "description": "Cook"],
        ]]
        let web = FakeWeb { _ in FakeWeb.json(body) }
        let jobs = try await source(try bundled("remotive"), web)
            .fetchJobs(config: config(["rails"]), knownExternalIDs: [])
        XCTAssertEqual(web.seen, ["https://remotive.com/api/remote-jobs?limit=100"])
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual([job.source, job.externalId, job.company, job.location],
                       ["remotive", "11", "Example Corp", "USA"])
        XCTAssertEqual(job.datePosted, "2026-11-19T14:58:42")
        XCTAssertEqual(job.tags, ["ruby", "rails"])
        XCTAssertTrue(job.isRemote)
        XCTAssertFalse(job.description.contains("<"))
    }

    func testHimalayasMapsSalaryDedupesPagesAndKeepsTheApplyLink() async throws {
        let body: [String: Any] = ["jobs": [
            ["guid": "https://himalayas.app/companies/example/jobs/1", "title": "Python Developer",
             "companyName": "Example Corp", "locationRestrictions": [],
             "applicationLink": "https://himalayas.app/apply/1?utm_source=api", "description": "Build",
             "pubDate": 1793013430, "minSalary": 2000, "maxSalary": 3000, "salaryPeriod": "monthly",
             "currency": "USD", "categories": ["Engineering"]],
            ["guid": "https://himalayas.app/companies/example/jobs/2", "title": "Python Analyst",
             "companyName": "Other Corp", "locationRestrictions": ["Canada", "United Kingdom"],
             "applicationLink": "https://himalayas.app/apply/2", "description": "Analyse",
             "pubDate": 1793013431],
        ]]
        let web = FakeWeb { _ in FakeWeb.json(body) }
        let jobs = try await source(try bundled("himalayas"), web)
            .fetchJobs(config: config(["python"]), knownExternalIDs: [])
        XCTAssertEqual(web.seen.first, "https://himalayas.app/jobs/api/search?q=python&sort=recent&page=1")
        XCTAssertEqual(web.seen.count, 2, "max_pages")
        XCTAssertEqual(jobs.count, 2, "the same two postings on both pages dedupe")
        let first = jobs[0], second = jobs[1]
        XCTAssertTrue(first.url.hasSuffix("?utm_source=api"))
        XCTAssertEqual(first.datePosted, "1793013430")
        XCTAssertEqual([first.salaryMin, first.salaryMax], [24000, 36000])  // USD monthly -> annual
        XCTAssertEqual(first.salaryPeriod, "annual")
        XCTAssertEqual(first.location, "Remote")
        XCTAssertEqual(second.location, "Canada, United Kingdom")
        XCTAssertNil(second.salaryMin)
    }

    func testJobicyDropsNonUSDSalariesAndHonoursTheDelay() async throws {
        let body: [String: Any] = ["jobs": [
            ["id": 7, "url": "https://jobicy.com/jobs/7-noc", "jobTitle": "Incident Manager",
             "companyName": "Example Corp", "jobGeo": "Spain", "jobDescription": "<p>Respond</p>",
             "pubDate": "2026-11-20", "salaryMin": 40000, "salaryMax": 50000, "salaryCurrency": "EUR",
             "salaryPeriod": "yearly", "jobIndustry": ["Support"]],
        ]]
        let web = FakeWeb { _ in FakeWeb.json(body) }
        let delays = Delays()
        let s = PortalSource(portal: try bundled("jobicy"), transport: web.transport, defaults: defaults,
                             now: { Date() }, sleep: { delays.add($0) })
        let jobs = try await s.fetchJobs(config: config(["incident", "support"]), knownExternalIDs: [])
        XCTAssertEqual(web.seen, ["https://jobicy.com/api/jobs?count=50&tag=incident",
                                  "https://jobicy.com/api/jobs?count=50&tag=support"])
        XCTAssertEqual(delays.values, [2])
        XCTAssertEqual(jobs.count, 1, "the same posting from both queries dedupes")
        XCTAssertEqual(jobs[0].externalId, "7")
        XCTAssertNil(jobs[0].salaryMin, "EUR figures are not mixed into the USD salary floor")
        XCTAssertFalse(jobs[0].description.contains("<"))
    }

    // MARK: other kinds

    private func kindPortal(_ kind: String, host: String, url: String,
                            defaults: [String: Any]? = nil) throws -> Portal {
        try portal {
            $0["kind"] = kind
            $0["hosts"] = [host]
            $0["request"] = ["url": url]
            $0.removeValue(forKey: "items")
            $0.removeValue(forKey: "fields")
            if let defaults { $0["defaults"] = defaults }
        }
    }

    func testFeed() async throws {
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item><title>Platform Engineer</title><link>https://feed.example/jobs/1</link>
        <description>&lt;p&gt;Build things&lt;/p&gt;</description><pubDate>Mon, 23 Nov 2026 10:00:00 GMT</pubDate>
        <author>Example Corp</author></item>
        <item><title>Chef</title><link>https://feed.example/jobs/2</link><description>Cook</description></item>
        </channel></rss>
        """
        let web = FakeWeb { _ in FakeWeb.text(rss) }
        let p = try kindPortal("feed", host: "feed.example", url: "https://feed.example/rss", defaults: ["remote": true])
        let jobs = try await source(p, web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs.map(\.title), ["Platform Engineer"])
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual([job.company, job.url, job.datePosted],
                       ["Example Corp", "https://feed.example/jobs/1", "Mon, 23 Nov 2026 10:00:00 GMT"])
        XCTAssertTrue(job.description.contains("Build things"))
        XCTAssertFalse(job.description.contains("<"))
        XCTAssertTrue(job.isRemote)
    }

    func testAtomEntries() async throws {
        let atom = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry><title>SRE Engineer</title><link href="https://feed.example/a/1"/><id>tag:feed.example,1</id>
        <summary>Keep it up</summary><updated>2026-11-20T00:00:00Z</updated></entry></feed>
        """
        let web = FakeWeb { _ in FakeWeb.text(atom) }
        let p = try kindPortal("feed", host: "feed.example", url: "https://feed.example/atom")
        let jobs = try await source(p, web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs.map { [$0.title, $0.url, $0.externalId] },
                       [["SRE Engineer", "https://feed.example/a/1", "tag:feed.example,1"]])
    }

    func testFeedWithEntitiesIsRefused() async throws {
        let web = FakeWeb { _ in FakeWeb.text(#"<!DOCTYPE x [<!ENTITY a "b">]><rss/>"#) }
        let p = try kindPortal("feed", host: "feed.example", url: "https://feed.example/rss")
        let jobs = try await source(p, web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs, [])
    }

    func testSchemaOrgReadsEveryJobPostingOnThePage() async throws {
        let page = """
        <html><head>
        <script type="application/ld+json">{"@context":"https://schema.org","@graph":[
        {"@type":"JobPosting","title":"Data Engineer","url":"https://pg.example/j/1",
         "hiringOrganization":{"@type":"Organization","name":"Example Corp"},
         "description":"<p>Pipelines</p>","datePosted":"2026-11-20"},
        {"@type":"JobPosting","title":"Cook","hiringOrganization":"Diner"}]}</script>
        <script type="application/ld+json">not json</script>
        <script type="application/ld+json">{"@type":"JobPosting","title":"Engineer II","url":"https://pg.example/j/3"}</script>
        </head></html>
        """
        let web = FakeWeb { _ in FakeWeb.text(page) }
        let p = try kindPortal("schema_org", host: "pg.example", url: "https://pg.example/careers")
        let jobs = try await source(p, web).fetchJobs(config: config(), knownExternalIDs: [])
        XCTAssertEqual(jobs.map(\.title), ["Data Engineer", "Engineer II"])
        XCTAssertEqual(jobs[0].company, "Example Corp")
        XCTAssertEqual(jobs[0].url, "https://pg.example/j/1")
        XCTAssertEqual(jobs[1].url, "https://pg.example/j/3")
    }

    // MARK: wiring: opt-in config and registry

    func testPortalsAreOffByDefaultAndEnabledPerDevice() {
        var config = AppConfig()
        XCTAssertTrue(config.search.enabledPortals.isEmpty)
        for id in ["remotive", "himalayas", "jobicy"] {
            XCTAssertTrue(SourceRegistry.portalIDs.contains(id))
            XCTAssertFalse(SourceRegistry.enabledIDs(for: config).contains(id))
        }
        config.search.enabledPortals = ["jobicy"]
        XCTAssertEqual(SourceRegistry.enabledPortalIDs(for: config), ["jobicy"])
        XCTAssertTrue(SourceRegistry.enabledIDs(for: config).contains("jobicy"))
        XCTAssertFalse(SourceRegistry.enabledIDs(for: config).contains("remotive"))
    }

    func testPortalsResolveThroughTheRegistry() {
        XCTAssertTrue(SourceRegistry.source(for: "remotive") is PortalSource)
        XCTAssertNotNil(SourceRegistry.timeout(for: "himalayas"))
        XCTAssertNil(SourceRegistry.source(for: "not-a-portal"))
        XCTAssertEqual(SourceCatalog.displayName(for: "remotive"), "Remotive")
        XCTAssertEqual(SourceCatalog.displayName(for: "himalayas"), "Himalayas")
        XCTAssertEqual(SourceCatalog.displayName(for: "jobicy"), "Jobicy")
    }

    func testEnabledPortalsSurviveAConfigRoundTripAndOldConfigsDecode() throws {
        var config = AppConfig()
        config.search.enabledPortals = ["remotive"]
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data).search.enabledPortals, ["remotive"])
        let old = #"{"keywords": ["swift"]}"#
        XCTAssertEqual(try JSONDecoder().decode(SearchConfig.self, from: Data(old.utf8)).enabledPortals, [])
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
}

private final class Delays: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func add(_ value: Double) { lock.lock(); list.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return list }
}
