import Foundation

/// A declarative job portal: a small JSON file describing a JSON API, an
/// RSS/Atom feed, or a page carrying schema.org JobPosting data. Port of the
/// desktop `backend/job_sources/portals.py` (format: the desktop's
/// `docs/portals.md`).
///
/// The engine only *reads* the file; nothing in it is evaluated. Validation is
/// strict: unknown keys are rejected at every level, URLs must be https to a
/// listed host, and every limit is conservative.
public struct Portal: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case jsonAPI = "json_api", feed, schemaOrg = "schema_org"
    }

    public let id: String
    public let name: String
    public let version: String
    public let homepage: String
    public let termsURL: String
    public let free: Bool
    public let hosts: [String]
    public let kind: Kind
    public let attribution: String?
    public let minIntervalMinutes: Int
    public let requestURL: String
    public let headers: [String: String]
    public let maxPages: Int
    public let maxQueries: Int
    public let delaySeconds: Double
    public let items: String?
    public let fields: [String: String]?
    public let defaultRemote: Bool?
    public let defaultLocation: String?

    /// A portal file is malformed or breaks a rule.
    public struct ValidationError: Error, Equatable, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    // MARK: Limits (a portal file may only ask for less)

    public static let maxFileBytes = 64 * 1024
    public static let maxResponseBytes = 5 * 1024 * 1024
    public static let maxPagesCap = 3
    public static let maxQueriesCap = 3
    public static let maxItems = 200
    public static let maxRedirects = 3
    public static let requestTimeout: TimeInterval = 15
    /// Seconds for one portal run, under the pipeline's own budget.
    public static let runBudget: TimeInterval = 45
    public static let minDelay: Double = 1.0

    static let jobFields: [String] = [
        "title", "company", "location", "url", "description", "posted_at",
        "salary_min", "salary_max", "salary_period", "salary_currency",
        "remote", "external_id", "tags",
    ]

    private static let topKeys: Set<String> = [
        "id", "name", "version", "homepage", "terms_url", "free", "hosts", "kind",
        "request", "items", "fields", "defaults", "attribution", "min_interval_minutes",
    ]
    private static let requestKeys: Set<String> = [
        "url", "headers", "max_pages", "max_queries", "delay_seconds",
    ]
    private static let defaultKeys: Set<String> = ["location", "remote"]
    private static let placeholderNames: Set<String> = ["query", "location", "page", "api_key"]
    private static let forbiddenHeaders: Set<String> = [
        "host", "cookie", "content-length", "connection", "transfer-encoding",
    ]

    // `\z` (not `$`) so a trailing newline can't slip through.
    private static let idRx = rx("^[a-z0-9][a-z0-9_-]{1,31}\\z")
    private static let hostRx = rx("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\\z")
    private static let pathRx = rx("^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)*\\z")
    private static let tagRx = rx("^[A-Za-z][A-Za-z0-9_.:-]*\\z")
    private static let headerNameRx = rx("^[A-Za-z][A-Za-z0-9-]*\\z")
    static let placeholderRx = rx("\\{([^{}]*)\\}")

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    // MARK: Helpers

    private static func checkKeys(_ object: [String: JSONValue], _ allowed: Set<String>,
                                  _ where_: String) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        if !unknown.isEmpty {
            throw ValidationError("\(where_): unknown key(s) \(unknown.map { "'\($0)'" }.joined(separator: ", "))")
        }
    }

    /// The placeholder names in `template`; throws for unknown names or stray braces.
    static func placeholders(_ template: String, _ where_: String) throws -> Set<String> {
        let ns = template as NSString
        let found = Set(placeholderRx.matches(in: template, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) })
        let bad = found.subtracting(placeholderNames)
        if !bad.isEmpty { throw ValidationError("\(where_): unknown placeholder(s) \(bad.sorted())") }
        let rest = placeholderRx.stringByReplacingMatches(
            in: template, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        if rest.contains("{") || rest.contains("}") { throw ValidationError("\(where_): unbalanced braces") }
        return found
    }

    private static func checkHTTPS(_ value: JSONValue?, _ where_: String) throws -> String {
        guard case .string(let url)? = value, !url.isEmpty else {
            throw ValidationError("\(where_): must be a non-empty string")
        }
        guard URLComponents(string: url)?.scheme == "https" else {
            throw ValidationError("\(where_): must be an https URL")
        }
        return url
    }

    /// Scheme/host/userinfo/port rules shared by templates and live URLs.
    static func checkURLHost(_ url: String, hosts: [String], _ where_: String) throws {
        guard let parts = URLComponents(string: url), parts.scheme == "https" else {
            throw ValidationError("\(where_): must be https")
        }
        if parts.user != nil || parts.password != nil || parts.port != nil {
            throw ValidationError("\(where_): credentials and ports are not allowed in the URL")
        }
        let host = (parts.host ?? "").lowercased()
        if !hosts.contains(host) {
            throw ValidationError("\(where_): host '\(host)' is not in hosts")
        }
    }

    private static func isInt(_ value: JSONValue?) -> Int? {
        if case .int(let i)? = value { return i }
        return nil
    }

    // MARK: Validation

    /// The portal for a parsed JSON value, or a `ValidationError`.
    public static func validate(_ raw: JSONValue) throws -> Portal {
        guard case .object(let obj) = raw else { throw ValidationError("portal file must be a JSON object") }
        try checkKeys(obj, topKeys, "portal")
        for key in ["id", "name", "version", "homepage", "terms_url", "free", "hosts", "kind", "request"]
        where obj[key] == nil {
            throw ValidationError("portal: missing required key '\(key)'")
        }

        guard case .string(let id)? = obj["id"], matches(idRx, id) else {
            throw ValidationError("id: must be 3-32 chars of a-z, 0-9, '-' or '_'")
        }
        var strings: [String: String] = [:]
        for key in ["name", "version"] {
            guard case .string(let s)? = obj[key],
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("\(key): must be a non-empty string")
            }
            strings[key] = s
        }
        let homepage = try checkHTTPS(obj["homepage"], "homepage")
        let terms = try checkHTTPS(obj["terms_url"], "terms_url")
        guard case .bool(let free)? = obj["free"] else { throw ValidationError("free: must be true or false") }

        guard case .array(let hostValues)? = obj["hosts"], !hostValues.isEmpty, hostValues.count <= 5 else {
            throw ValidationError("hosts: must be a list of 1-5 hostnames")
        }
        var hosts: [String] = []
        for value in hostValues {
            guard case .string(let host) = value, matches(hostRx, host),
                  !(host.split(separator: ".").last.map { $0.allSatisfy(\.isNumber) } ?? true) else {
                throw ValidationError("hosts: \(value) is not a plain lowercase hostname")
            }
            hosts.append(host)
        }

        guard case .string(let kindRaw)? = obj["kind"], let kind = Kind(rawValue: kindRaw) else {
            throw ValidationError("kind: must be one of json_api, feed, schema_org")
        }

        var attribution: String?
        if let value = obj["attribution"] {
            guard case .string(let s) = value, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("attribution: must be a non-empty string")
            }
            attribution = s
        }
        var interval = 0
        if let value = obj["min_interval_minutes"] {
            guard let i = isInt(value), (0...10080).contains(i) else {
                throw ValidationError("min_interval_minutes: must be an integer from 0 to 10080")
            }
            interval = i
        }

        guard case .object(let req)? = obj["request"] else { throw ValidationError("request: must be an object") }
        try checkKeys(req, requestKeys, "request")
        let template = try checkHTTPS(req["url"], "request.url")
        let used = try placeholders(template, "request.url")
        if authority(of: template).contains("{") {
            throw ValidationError("request.url: the host cannot contain a placeholder")
        }
        let filled = placeholderRx.stringByReplacingMatches(
            in: template, range: NSRange(location: 0, length: (template as NSString).length), withTemplate: "x")
        try checkURLHost(filled, hosts: hosts, "request.url")
        if used.contains("page") && req["max_pages"] == nil {
            throw ValidationError("request.max_pages: required when the URL uses {page}")
        }
        if used.contains("api_key") { throw ValidationError("request.url: {api_key} is only allowed in headers") }
        var caps: [String: Int] = [:]
        for (key, cap) in [("max_pages", maxPagesCap), ("max_queries", maxQueriesCap)] {
            guard let value = req[key] else { continue }
            guard let i = isInt(value), (1...cap).contains(i) else {
                throw ValidationError("request.\(key): must be an integer from 1 to \(cap)")
            }
            caps[key] = i
        }
        var delay = minDelay
        if let value = req["delay_seconds"] {
            switch value {
            case .int(let i) where (Int(minDelay)...30).contains(i): delay = Double(i)
            case .double(let d) where d >= minDelay && d <= 30: delay = d
            default: throw ValidationError("request.delay_seconds: must be a number from 1 to 30")
            }
        }
        var headers: [String: String] = [:]
        if let value = req["headers"] {
            guard case .object(let h) = value, h.count <= 5 else {
                throw ValidationError("request.headers: must be an object with at most 5 headers")
            }
            for (name, v) in h {
                if !matches(headerNameRx, name) || forbiddenHeaders.contains(name.lowercased()) {
                    throw ValidationError("request.headers: header name '\(name)' is not allowed")
                }
                guard case .string(let s) = v, !s.contains("\n"), !s.contains("\r") else {
                    throw ValidationError("request.headers.\(name): must be a single-line string")
                }
                let bad = try placeholders(s, "request.headers.\(name)").subtracting(["api_key"])
                if !bad.isEmpty { throw ValidationError("request.headers.\(name): only {api_key} may be used here") }
                headers[name] = s
            }
        }

        let itemsValue = obj["items"], fieldsValue = obj["fields"]
        var items: String?
        var fields: [String: String]?
        switch kind {
        case .jsonAPI:
            guard case .string(let path)? = itemsValue, path == "$" || matches(pathRx, path) else {
                throw ValidationError("items: required for json_api — a dotted path, or '$' for a top-level array")
            }
            items = path
            guard case .object(let f)? = fieldsValue else { throw ValidationError("fields: required for json_api") }
            for needed in ["title", "url"] where f[needed] == nil {
                throw ValidationError("fields: '\(needed)' is required")
            }
            fields = try mapFields(f, kind: kind)
        case .feed:
            if itemsValue != nil { throw ValidationError("items: not used by feed portals") }
            if let fieldsValue {
                guard case .object(let f) = fieldsValue else { throw ValidationError("fields: must be an object") }
                fields = try mapFields(f, kind: kind)
            }
        case .schemaOrg:
            if itemsValue != nil || fieldsValue != nil {
                throw ValidationError("items/fields: not used by schema_org portals")
            }
        }

        var defaultRemote: Bool?
        var defaultLocation: String?
        if let value = obj["defaults"] {
            guard case .object(let d) = value else { throw ValidationError("defaults: must be an object") }
            try checkKeys(d, defaultKeys, "defaults")
            if let r = d["remote"] {
                guard case .bool(let b) = r else { throw ValidationError("defaults.remote: must be true or false") }
                defaultRemote = b
            }
            if let l = d["location"] {
                guard case .string(let s) = l else { throw ValidationError("defaults.location: must be a string") }
                defaultLocation = s
            }
        }

        return Portal(id: id, name: strings["name"] ?? "", version: strings["version"] ?? "",
                      homepage: homepage, termsURL: terms, free: free, hosts: hosts, kind: kind,
                      attribution: attribution, minIntervalMinutes: interval, requestURL: template,
                      headers: headers, maxPages: caps["max_pages"] ?? 1,
                      maxQueries: caps["max_queries"] ?? maxQueriesCap, delaySeconds: delay,
                      items: items, fields: fields, defaultRemote: defaultRemote,
                      defaultLocation: defaultLocation)
    }

    private static func mapFields(_ f: [String: JSONValue], kind: Kind) throws -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in f {
            if !jobFields.contains(name) { throw ValidationError("fields: unknown job field '\(name)'") }
            let pattern = kind == .jsonAPI ? pathRx : tagRx
            guard case .string(let path) = value, matches(pattern, path) else {
                throw ValidationError("fields.\(name): invalid \(kind == .jsonAPI ? "path" : "tag name")")
            }
            out[name] = path
        }
        return out
    }

    /// The "host" part of an https template, tolerant of `{placeholders}`.
    private static func authority(of template: String) -> String {
        guard let range = template.range(of: "://") else { return "" }
        let rest = template[range.upperBound...]
        let end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Parse and validate one portal file's bytes.
    public static func parse(data: Data, name: String = "portal") throws -> Portal {
        if data.count > maxFileBytes {
            throw ValidationError("\(name): file is larger than \(maxFileBytes) bytes")
        }
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            throw ValidationError("\(name): not valid JSON")
        }
        return try validate(JSONValue.from(any))
    }
}

/// The portals that ship with the app, loaded from the Kit's resource bundle.
public enum PortalCatalog {
    /// Every valid bundled portal, in file-name order. Bad files are skipped,
    /// never raised, and nothing may take a built-in source's name.
    public static let bundled: [Portal] = {
        guard let dir = Bundle.module.url(forResource: "portals", withExtension: nil) else { return [] }
        return load(from: dir, reserved: Set(SourceRegistry.allIDs))
    }()

    public static func portal(id: String) -> Portal? {
        bundled.first { $0.id == id.lowercased() }
    }

    /// Load every `*.json` in `directory`; first id wins, reserved ids are refused.
    static func load(from directory: URL, reserved: Set<String>) -> [Portal] {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [Portal] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let portal = try? Portal.parse(data: data, name: file.lastPathComponent),
                  !out.contains(where: { $0.id == portal.id }), !reserved.contains(portal.id)
            else { continue }
            out.append(portal)
        }
        return out
    }
}
