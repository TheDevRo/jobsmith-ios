import Foundation

/// Requirement coverage: "this job covers N of M requirements". Port of the
/// desktop `backend/coverage.py`.
///
/// Stored as JSON in `jobs.coverage` next to the 0-100 fit score, in the
/// desktop's shape:
///   {"requirements": [{"text", "kind": "must"|"nice", "met": bool,
///                      "evidence": str|null, "dismissed"?: true}],
///    "covered": int, "total": int, "missing_must": int}
///
/// It comes from the scoring LLM's "requirements" array, parsed here and
/// deliberately apart from `ScoreResponseParser`, which is pinned by the
/// cross-language score fixtures. A score prompt that doesn't ask for
/// requirements (an old override) simply yields no coverage.
public struct RequirementCoverage: Codable, Equatable, Sendable {
    public struct Requirement: Codable, Equatable, Sendable {
        public var text: String
        /// "must" or "nice".
        public var kind: String
        public var met: Bool
        public var evidence: String?
        public var dismissed: Bool?

        public init(text: String, kind: String, met: Bool, evidence: String? = nil,
                    dismissed: Bool? = nil) {
            self.text = text; self.kind = kind; self.met = met
            self.evidence = evidence; self.dismissed = dismissed
        }

        public var isMust: Bool { kind == "must" }

        enum CodingKeys: String, CodingKey { case text, kind, met, evidence, dismissed }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            try c.encode(kind, forKey: .kind)
            try c.encode(met, forKey: .met)
            try c.encode(evidence, forKey: .evidence)  // explicit null, like the desktop
            try c.encodeIfPresent(dismissed, forKey: .dismissed)
        }
    }

    public var requirements: [Requirement]
    public var covered: Int
    public var total: Int
    public var missingMust: Int

    enum CodingKeys: String, CodingKey {
        case requirements, covered, total
        case missingMust = "missing_must"
    }

    public static let maxRequirements = 20

    /// The coverage with its derived counts; nil for an empty list.
    public static func build(_ requirements: [Requirement]) -> RequirementCoverage? {
        guard !requirements.isEmpty else { return nil }
        return RequirementCoverage(
            requirements: requirements,
            covered: requirements.filter(\.met).count,
            total: requirements.count,
            missingMust: requirements.filter { $0.isMust && !$0.met }.count)
    }

    /// Coverage from an LLM scoring response's "requirements" array. Tolerant:
    /// nil for anything malformed or empty, never throws. Items that are not
    /// usable are skipped and the rest is kept (partial input works).
    public static func parse(_ text: String?) -> RequirementCoverage? {
        guard let text,
              let blob = Rx.first("\\{.*\\}", in: text, options: [.dotMatchesLineSeparators])?[0],
              let data = blob.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              case .object(let object) = JSONValue.from(any),
              case .array(let raw)? = object["requirements"] else { return nil }

        var out: [Requirement] = []
        for item in raw {
            guard case .object(let o) = item, case .bool(let met)? = o["met"],
                  case .string(let rawText)? = o["text"] else { continue }
            let req = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if req.isEmpty { continue }
            var kind = "nice"
            if case .string(let k)? = o["kind"],
               ["must", "must-have", "required"].contains(k.lowercased()) {
                kind = "must"
            }
            var evidence: String?
            if case .string(let e)? = o["evidence"] {
                let trimmed = e.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { evidence = String(trimmed.prefix(200)) }
            }
            out.append(Requirement(text: String(req.prefix(200)), kind: kind, met: met,
                                   evidence: evidence))
            if out.count >= maxRequirements { break }
        }
        return build(out)
    }

    /// The stored JSON for the `jobs.coverage` column.
    public var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Decode a stored column value; nil when absent, malformed, or empty.
    public static func decode(_ json: String?) -> RequirementCoverage? {
        guard let json, let data = json.data(using: .utf8),
              let cov = try? JSONDecoder().decode(RequirementCoverage.self, from: data),
              cov.total > 0, !cov.requirements.isEmpty else { return nil }
        return cov
    }

    /// "Best coverage" ordering: share covered, then fewer missing must-haves,
    /// then fit score. Jobs without coverage sink below those with it.
    public static func isOrderedBefore(_ a: Job, _ b: Job) -> Bool {
        let ca = decode(a.coverage), cb = decode(b.coverage)
        switch (ca, cb) {
        case (nil, nil): break
        case (_?, nil): return true
        case (nil, _?): return false
        case let (x?, y?):
            let rx = Double(x.covered) / Double(x.total), ry = Double(y.covered) / Double(y.total)
            if rx != ry { return rx > ry }
            if x.missingMust != y.missingMust { return x.missingMust < y.missingMust }
        }
        let fa = a.fitScore ?? -1, fb = b.fitScore ?? -1
        if fa != fb { return fa > fb }
        return a.dateDiscovered > b.dateDiscovered
    }

    /// Short badge text, "N/M".
    public var badge: String { "\(covered)/\(total)" }

    /// Accessibility / tooltip sentence.
    public var summary: String {
        "Covers \(covered) of \(total) requirements"
            + (missingMust > 0 ? "; \(missingMust) must-have\(missingMust == 1 ? "" : "s") missing" : "")
    }
}

public extension Job {
    /// The stored requirement coverage, if the score produced any.
    var requirementCoverage: RequirementCoverage? { RequirementCoverage.decode(coverage) }
}
