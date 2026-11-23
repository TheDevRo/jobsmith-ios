import Foundation
import SwiftSoup

/// Runs a `Portal`: one request per search keyword (up to three) when the URL
/// has `{query}`, otherwise a single request filtered locally by keyword. Port
/// of `fetch_portal` and the three parsers in the desktop `portals.py`.
///
/// Every request is https to a listed host, re-checked on every redirect hop
/// (redirects are followed by hand, at most three). Portals are opt-in: each is
/// off until its id is in `SearchConfig.enabledPortals`.
public struct PortalSource: JobSource {
    /// Unused: each instance fetches for its own `portal.id`; the registry
    /// keys portals by that id.
    public static let id = "portal"
    public static let timeout: Duration = .seconds(60)

    /// One HTTP response, as far as the engine cares.
    public struct Response: Sendable {
        public let status: Int
        public let data: Data
        public let headers: [String: String]
        public init(status: Int, data: Data, headers: [String: String] = [:]) {
            self.status = status; self.data = data; self.headers = headers
        }
    }

    /// Sends one request without following redirects. Injectable for tests.
    public typealias Transport = @Sendable (URLRequest) async throws -> Response

    public let portal: Portal
    let transport: Transport
    let defaults: UserDefaults
    let now: @Sendable () -> Date
    let sleep: @Sendable (Double) async throws -> Void

    public init(portal: Portal,
                transport: @escaping Transport = PortalSource.liveTransport,
                defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.portal = portal
        self.transport = transport
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
    }

    // MARK: Transport

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)  // the engine follows redirects itself, hop by hop
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Portal.requestTimeout
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    public static let liveTransport: Transport = { request in
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return Response(status: http?.statusCode ?? 0, data: data, headers: headers)
    }

    // MARK: Min interval

    private func stateKey() -> String { "jobsmith.portal.lastFetch.\(portal.id)" }

    /// Whether the portal's terms say to skip this fetch (fetched too recently).
    func isRateLimited() -> Bool {
        let interval = Double(portal.minIntervalMinutes) * 60
        let last = defaults.double(forKey: stateKey())
        return interval > 0 && last > 0 && now().timeIntervalSince1970 - last < interval
    }

    // MARK: Fetch

    /// URL-encode every placeholder value; unknown names fill with "".
    static func fill(_ template: String, _ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~")
        let ns = template as NSString
        var out = ""
        var cursor = 0
        for m in Portal.placeholderRx.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let name = ns.substring(with: m.range(at: 1))
            out += (values[name] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            cursor = m.range.location + m.range.length
        }
        return out + ns.substring(from: cursor)
    }

    /// GET following redirects by hand: each hop must stay https and on a listed host.
    func get(_ startURL: String, headers: [String: String]) async throws -> Response {
        var url = startURL
        for _ in 0...Portal.maxRedirects {
            try Portal.checkURLHost(url, hosts: portal.hosts, "request")
            guard let target = URL(string: url) else { throw Portal.ValidationError("request: not a URL") }
            var request = URLRequest(url: target, timeoutInterval: Portal.requestTimeout)
            request.httpMethod = "GET"
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let resp = try await transport(request)
            if [301, 302, 303, 307, 308].contains(resp.status) {
                guard let location = resp.headers["location"], !location.isEmpty,
                      let next = URL(string: location, relativeTo: target)?.absoluteURL else {
                    throw Portal.ValidationError("HTTP \(resp.status) without a Location")
                }
                url = next.absoluteString
                continue
            }
            if resp.data.count > Portal.maxResponseBytes {
                throw Portal.ValidationError("response is too large")
            }
            return resp
        }
        throw Portal.ValidationError("more than \(Portal.maxRedirects) redirects")
    }

    public func fetchJobs(config: AppConfig, knownExternalIDs: Set<String>) async throws -> [NormalizedJob] {
        let search = config.search
        let keywords = search.keywords.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !keywords.isEmpty else { return [] }

        let template = portal.requestURL
        let usesQuery = ((try? Portal.placeholders(template, "request.url")) ?? []).contains("query")
        let queries = usesQuery ? Array(keywords.prefix(min(portal.maxQueries, Portal.maxQueriesCap))) : [""]
        let pages = template.contains("{page}") ? min(portal.maxPages, Portal.maxPagesCap) : 1
        let delay = max(portal.delaySeconds, Portal.minDelay)

        if isRateLimited() { return [] }

        // The iOS app keeps no per-portal API keys, so a header that needs one is left out.
        var headers = ["User-Agent": "Jobsmith (+https://github.com/TheDevRo/Jobsmith)"]
        for (name, value) in portal.headers where !value.contains("{api_key}") { headers[name] = value }
        let location = search.locations.first {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t.lowercased() != "remote"
        } ?? ""

        var jobs: [NormalizedJob] = []
        var seen: Set<String> = []
        let started = now()
        var first = true
        defaults.set(now().timeIntervalSince1970, forKey: stateKey())
        do {
            outer: for query in queries {
                for page in 1...pages {
                    if now().timeIntervalSince(started) > Portal.runBudget {
                        throw Portal.ValidationError("run time budget exceeded")
                    }
                    if !first { try await sleep(delay) }
                    first = false
                    let url = Self.fill(template, ["query": query, "location": location, "page": String(page)])
                    let resp = try await get(url, headers: headers)
                    guard resp.status == 200 else { break }
                    let body = String(decoding: resp.data, as: UTF8.self)
                    let batch: [NormalizedJob]
                    switch portal.kind {
                    case .jsonAPI: batch = try Self.parseJSONAPI(portal, data: resp.data)
                    case .feed: batch = try Self.parseFeed(portal, body: body)
                    case .schemaOrg: batch = Self.parseSchemaOrg(portal, body: body, pageURL: url)
                    }
                    let fresh = batch.filter { !seen.contains($0.externalId) }
                    seen.formUnion(fresh.map(\.externalId))
                    jobs.append(contentsOf: fresh)
                    if batch.isEmpty { continue outer }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            // Keep what earlier requests returned; the portal just ends early.
            NSLog("Portal \(portal.id) stopped early: \(error)")
        }

        let excludes = JobFilters.compileExcludes(search.excludeKeywords)
        return jobs.filter { job in
            if JobFilters.matchesExclude(job.title, excludes) { return false }
            if !usesQuery {
                let haystack = "\(job.title) \(job.company) \(job.tags.joined(separator: " ")) \(job.description)"
                if !JobFilters.matchesKeywords(haystack, keywords) { return false }
            }
            return true
        }
    }

    // MARK: Value helpers

    /// Walk a dotted path through dictionaries and arrays (digits index lists).
    static func dig(_ root: Any?, _ path: String) -> Any? {
        var node = root
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            if let dict = node as? [String: Any] {
                node = dict[String(part)]
            } else if let list = node as? [Any], let index = Int(part), index >= 0, index < list.count {
                node = list[index]
            } else {
                return nil
            }
        }
        return node is NSNull ? nil : node
    }

    static func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let list as [Any]:
            return list.map { text($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
        case is [String: Any]: return ""
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
            return n.stringValue
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return String(describing: value!).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func number(_ value: Any?) -> Int? {
        if value == nil || value is NSNull { return nil }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let s = text(value).replacingOccurrences(of: ",", with: "")
        if s.isEmpty { return nil }
        guard let d = Double(s), d.isFinite else { return nil }
        return Int(d)
    }

    private static let annualFactor: [String: Int] = [
        "monthly": 12, "fortnightly": 26, "biweekly": 26, "weekly": 52,
    ]

    /// salary_min/max/period from raw mapped values; non-USD figures are dropped
    /// because the global salary floor compares raw numbers.
    static func salary(_ values: [String: Any?]) -> (min: Int?, max: Int?, period: String?) {
        let currency = text(values["salary_currency"] ?? nil).uppercased()
        var lo = number(values["salary_min"] ?? nil), hi = number(values["salary_max"] ?? nil)
        if (!currency.isEmpty && currency != "USD") || ((lo ?? 0) == 0 && (hi ?? 0) == 0) {
            return (nil, nil, nil)
        }
        var period = text(values["salary_period"] ?? nil).lowercased()
        if let factor = annualFactor[period] {
            if let l = lo, l != 0 { lo = l * factor }
            if let h = hi, h != 0 { hi = h * factor }
            period = "annual"
        } else if ["yearly", "annual", "year"].contains(period) {
            period = "annual"
        } else if ["hourly", "hour"].contains(period) {
            period = "hourly"
        } else {
            period = ""
        }
        return ((lo ?? 0) == 0 ? nil : lo, (hi ?? 0) == 0 ? nil : hi, period.isEmpty ? nil : period)
    }

    static func truthy(_ value: Any?) -> Bool {
        if let s = value as? String {
            return ["true", "1", "yes", "remote"].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
        }
        if let n = value as? NSNumber { return n.boolValue }
        return value != nil && !(value is NSNull)
    }

    /// Map raw per-field values to the job shape the other sources return.
    static func buildJob(_ portal: Portal, _ values: [String: Any?]) -> NormalizedJob? {
        let title = text(values["title"] ?? nil), url = text(values["url"] ?? nil)
        let scheme = URLComponents(string: url)?.scheme?.lowercased()
        guard !title.isEmpty, scheme == "http" || scheme == "https" else { return nil }
        let remoteValue = values["remote"] ?? nil
        let isRemote = remoteValue != nil ? truthy(remoteValue) : (portal.defaultRemote ?? false)
        var location = text(values["location"] ?? nil)
        if location.isEmpty { location = portal.defaultLocation ?? "" }
        if location.isEmpty && isRemote { location = "Remote" }

        var tags: [String] = []
        let rawTags = values["tags"] ?? nil
        if let s = rawTags as? String {
            tags = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .replacingOccurrences(of: "'", with: "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if let list = rawTags as? [Any] {
            tags = list.map { text($0) }
        }
        let pay = salary(values)
        let externalID = text(values["external_id"] ?? nil)
        return NormalizedJob(
            source: portal.id,
            externalId: externalID.isEmpty ? url : externalID,
            title: title,
            company: text(values["company"] ?? nil),
            location: location,
            url: url,
            description: JobFilters.cleanDescription(text(values["description"] ?? nil)),
            salaryMin: pay.min, salaryMax: pay.max, salaryPeriod: pay.period,
            tags: tags,
            datePosted: text(values["posted_at"] ?? nil),
            isRemote: isRemote || location.lowercased().contains("remote"))
    }

    // MARK: Parsers

    static func parseJSONAPI(_ portal: Portal, data: Data) throws -> [NormalizedJob] {
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let itemsPath = portal.items, let fields = portal.fields else { return [] }
        let items = itemsPath == "$" ? root : dig(root, itemsPath)
        guard let list = items as? [Any] else { return [] }
        var jobs: [NormalizedJob] = []
        for case let item as [String: Any] in list.prefix(Portal.maxItems) {
            var values: [String: Any?] = [:]
            for (name, path) in fields { values[name] = dig(item, path) }
            if let job = buildJob(portal, values) { jobs.append(job) }
        }
        return jobs
    }

    private static let feedDefaults: [String: String] = [
        "title": "title", "url": "link", "description": "description", "posted_at": "pubDate",
        "company": "author", "external_id": "guid",
    ]
    private static let atomDefaults: [String: String] = [
        "url": "link", "description": "summary", "posted_at": "updated", "external_id": "id",
    ]

    static func parseFeed(_ portal: Portal, body: String) throws -> [NormalizedJob] {
        // Refuse documents declaring entities, to stay clear of entity-bomb tricks.
        if body.contains("<!ENTITY") { throw Portal.ValidationError("feed declares entities") }
        let collector = FeedCollector()
        let parser = XMLParser(data: Data(body.utf8))
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw Portal.ValidationError("feed is not valid XML") }
        let custom = portal.fields ?? [:]
        var jobs: [NormalizedJob] = []
        for children in collector.entries {
            var values: [String: Any?] = [:]
            for name in Portal.jobFields {
                let candidates = custom[name].map { [$0] } ?? [feedDefaults[name], atomDefaults[name]].compactMap { $0 }
                values[name] = candidates.compactMap { children[$0] }.first
            }
            if let job = buildJob(portal, values) { jobs.append(job) }
            if jobs.count >= Portal.maxItems { break }
        }
        return jobs
    }

    /// Collects the first non-empty value per child element of each RSS `<item>` / Atom `<entry>`.
    private final class FeedCollector: NSObject, XMLParserDelegate {
        var entries: [[String: String]] = []
        private var depthOfEntry: Int?
        private var depth = 0
        private var current: [String: String] = [:]
        private var childName: String?
        private var childText = ""
        private var childHref = ""

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            let name = local(elementName)
            if depthOfEntry == nil, name == "item" || name == "entry" {
                depthOfEntry = depth
                current = [:]
            } else if let entryDepth = depthOfEntry, depth == entryDepth + 1 {
                childName = name
                childText = ""
                childHref = attributeDict["href"] ?? ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if childName != nil { childText += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if childName != nil { childText += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if let entryDepth = depthOfEntry {
                if depth == entryDepth + 1, let name = childName {
                    let value = childText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = value.isEmpty ? childHref : value
                    if !text.isEmpty, current[name] == nil { current[name] = text }
                    childName = nil
                } else if depth == entryDepth {
                    entries.append(current)
                    depthOfEntry = nil
                }
            }
            depth -= 1
        }
    }

    /// Every JobPosting JSON-LD node on the page, parsed by the shared generic parser.
    static func parseSchemaOrg(_ portal: Portal, body: String, pageURL: String) -> [NormalizedJob] {
        guard let doc = try? SwiftSoup.parse(body) else { return [] }
        var nodes: [[String: Any]] = []
        for script in (try? doc.select("script[type=application/ld+json]").array()) ?? [] {
            if let json = try? JSONSerialization.jsonObject(with: Data(script.data().utf8)) {
                collectJobPostings(json, into: &nodes)
            }
        }
        var jobs: [NormalizedJob] = []
        for node in nodes.prefix(Portal.maxItems) {
            let nodeURL = (node["url"] as? String).flatMap { URL(string: $0) } ?? URL(string: pageURL)
            guard let nodeURL,
                  let data = try? JSONSerialization.data(withJSONObject: node),
                  let snippet = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "</", with: "<\\/"),
                  let parsed = GenericJobParser.parse(
                    html: "<script type=\"application/ld+json\">\(snippet)</script>", url: nodeURL)
            else { continue }
            var externalID: String?
            if let identifier = node["identifier"] as? [String: Any] { externalID = text(identifier["value"]) }
            let values: [String: Any?] = [
                "title": parsed.title, "company": parsed.company, "location": parsed.location,
                "url": parsed.url, "description": parsed.description, "posted_at": parsed.datePosted,
                "salary_min": parsed.salaryMin, "salary_max": parsed.salaryMax,
                "salary_period": parsed.salaryPeriod, "tags": parsed.tags,
                "remote": parsed.isRemote, "external_id": externalID,
            ]
            if let job = buildJob(portal, values) { jobs.append(job) }
        }
        return jobs
    }

    private static func collectJobPostings(_ node: Any, into out: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            let type = dict["@type"]
            if (type as? String) == "JobPosting" || ((type as? [Any])?.contains { ($0 as? String) == "JobPosting" } ?? false) {
                out.append(dict)
            }
            if let graph = dict["@graph"] as? [Any] { for value in graph { collectJobPostings(value, into: &out) } }
        } else if let list = node as? [Any] {
            for value in list { collectJobPostings(value, into: &out) }
        }
    }
}
