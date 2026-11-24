import Foundation

/// A warning-only check on AI-written documents. Port of the desktop
/// `backend/fact_guard.py`.
///
/// After a resume or cover letter is generated or revised, the names, numbers,
/// years, percentages and credential words in it are looked up in everything
/// the candidate has said: the profile, the posting, and their facts. What
/// can't be found is returned so the UI can say "Check this: …". It never
/// blocks anything.
///
/// Only the honest and tailored levels are checked: embellished and fabricated
/// are allowed to go beyond the profile, so flagging would only be noise.
public enum FactGuard {
    public static func isGuarded(_ level: HonestyConfig.Level) -> Bool {
        level == .honest || level == .tailored
    }

    // MARK: - Vocabulary

    private static let numberWords: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "hundred": 100,
    ]

    private static let skipWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug",
        "sep", "sept", "oct", "nov", "dec",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        // Capitalised mid-sentence, but not names.
        "i", "i'm", "i’m", "i've", "i’ve", "i'd", "i’d", "i'll", "i’ll", "ok",
        // Resume and letter furniture that legitimately isn't in the sources.
        "present", "current", "dear", "hiring", "manager", "team", "sincerely", "regards",
        "best", "thank", "thanks", "respectfully", "recruiter", "recruiting", "committee",
        "title", "company", "dates", "degree", "school", "year",
    ]

    /// Section headers the document parser accepts.
    static let resumeHeaders: Set<String> = [
        "SUMMARY", "PROFESSIONAL SUMMARY", "PROFILE SUMMARY", "PROFILE", "ABOUT ME", "SKILLS",
        "TECHNICAL SKILLS", "CORE COMPETENCIES", "KEY SKILLS", "COMPETENCIES", "EXPERIENCE",
        "PROFESSIONAL EXPERIENCE", "WORK EXPERIENCE", "EMPLOYMENT HISTORY", "CAREER HISTORY",
        "EDUCATION", "EDUCATIONAL BACKGROUND", "ACADEMIC BACKGROUND", "CERTIFICATIONS",
        "CERTIFICATES", "LICENSES", "LICENSES & CERTIFICATIONS", "PROJECTS", "AWARDS",
        "ACHIEVEMENTS",
    ]

    private static let secretKeys: Set<String> = [
        "workday_password", "ats_login_password", "workday_email", "password",
        // The iOS profile spells them in camelCase.
        "workdayPassword", "atsLoginPassword", "workdayEmail",
    ]

    private static let scale: [String: Double] = [
        "k": 1_000, "m": 1_000_000, "b": 1_000_000_000,
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    // Python's `[^\W_]` is a letter or digit; `\w` adds the underscore. The
    // patterns below spell the former `[\p{L}\p{N}]`.
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are literals below; a failure here is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// A number as people write it: "4,000+", "4 000", "120k", "30%", "2.5", "12", "10 million".
    private static let numberRx = regex(
        "(?<![\\p{L}\\p{N}])(\\d{1,3}(?:[,.\\u00a0\\u202f ]\\d{3})+|\\d+(?:[.,]\\d+)?)"
        + "\\s*(?:(k|m|b)(?![\\p{L}\\p{N}])|\\s(thousand|million|billion)(?![\\p{L}\\p{N}]))?%?(?![\\p{L}\\p{N}])",
        [.caseInsensitive])
    private static let thousandsRx = regex("^\\d{1,3}(?:[,.\\u00a0\\u202f ]\\d{3})+$")
    private static let wordRx = regex("[\\p{L}\\p{N}][\\p{L}\\p{N}_&'’.+#\\-]*")
    private static let capitalisedRx = regex("\\p{L}[\\p{L}\\p{N}_&'’+#\\-]*")
    private static let credentialRx = regex(
        "\\b(certified|certification|certificate|licensed|license|accredited|chartered)\\b",
        [.caseInsensitive])
    private static let alphaWordRx = regex("\\b([a-z]+)\\b", [.caseInsensitive])
    private static let yearMonthRx = regex("(\\d{4})(?:[-/](\\d{1,2}))?")
    private static let possessiveRx = regex("['’]s$")
    private static let leadRx = regex("^\\s*(?:[-*•·]\\s+)?")
    private static let boundaryRx = regex(
        "(?:[.!?:;][\"”’)]?\\s+|\\n)\\s*(?:[-*•·]\\s+)?(?=\\S)")
    private static let headerPrefixRx = regex("^[#*_`]+\\s*")

    // MARK: - Sources

    public struct Sources: Equatable, Sendable {
        public var text: String = ""
        public var words: Set<String> = []
        public var numbers: Set<Double> = []
        public init(text: String = "", words: Set<String> = [], numbers: Set<Double> = []) {
            self.text = text; self.words = words; self.numbers = numbers
        }
    }

    private static func matches(_ rx: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        rx.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func trimEnd(_ word: String, _ marks: Set<Character>) -> String {
        var out = Substring(word)
        while let last = out.last, marks.contains(last) { out = out.dropLast() }
        return String(out)
    }

    private static func numberValue(_ digits: String, _ suffix: String?) -> Double? {
        let ns = digits as NSString
        let base: Double?
        if thousandsRx.firstMatch(in: digits, range: NSRange(location: 0, length: ns.length)) != nil {
            base = Double(digits.filter { $0.isASCII && $0.isNumber })
        } else {
            base = Double(digits.replacingOccurrences(of: ",", with: "."))
        }
        guard let base else { return nil }
        return base * (scale[(suffix ?? "").lowercased()] ?? 1)
    }

    /// Every number-like thing in `text`: (as written, value).
    static func numbers(in text: String) -> [(raw: String, value: Double)] {
        let ns = text as NSString
        var found: [(raw: String, value: Double)] = []
        for m in matches(numberRx, in: text) {
            let raw = ns.substring(with: m.range(at: 0)).trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = ns.substring(with: m.range(at: 1))
            var suffix: String?
            for g in [2, 3] where m.range(at: g).location != NSNotFound {
                suffix = ns.substring(with: m.range(at: g))
                break
            }
            if let value = numberValue(digits, suffix) { found.append((raw: raw, value: value)) }
        }
        for m in matches(alphaWordRx, in: text) {
            let word = ns.substring(with: m.range(at: 1))
            if let value = numberWords[word.lowercased()] { found.append((raw: word, value: value)) }
        }
        return found
    }

    public static func sources(from parts: [String]) -> Sources {
        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n").lowercased()
        let ns = text as NSString
        let words = Set(matches(wordRx, in: text).map {
            trimEnd(ns.substring(with: $0.range), [".", "'", "’"])
        })
        return Sources(text: text, words: words, numbers: Set(numbers(in: text).map { $0.value }))
    }

    /// Every string/number inside a profile-shaped value, secrets excluded.
    static func flatten(_ value: Any) -> [String] {
        switch value {
        case let s as String:
            return [s]
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return [] }
            return [n.stringValue]
        case let d as [String: Any]:
            // Record ids are bookkeeping, not claims: their digits must not back a number.
            return d.sorted { $0.key < $1.key }
                .filter { !secretKeys.contains($0.key) && $0.key != "id" }
                .flatMap { flatten($0.value) }
        case let a as [Any]:
            return a.flatMap(flatten)
        default:
            return []
        }
    }

    /// Whole years the profile's roles add up to (the model likes "8 years of experience").
    static func experienceYears(_ profile: Profile, today: Date = Date()) -> Int? {
        let cal = Calendar(identifier: .gregorian)
        let parts = cal.dateComponents([.year, .month], from: today)
        let ty = parts.year ?? 1970, tm = parts.month ?? 1
        var months = 0
        for role in profile.experience {
            guard let start = yearMonth(role.startDate) else { continue }
            let (ey, em) = yearMonth(role.endDate).map { ($0.year, $0.month ?? 12) } ?? (ty, tm)
            months += max(0, (ey - start.year) * 12 + (em - (start.month ?? 1)))
        }
        return months > 0 ? months / 12 : nil
    }

    private static func yearMonth(_ raw: String) -> (year: Int, month: Int?)? {
        let ns = raw as NSString
        guard let m = yearMonthRx.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              let year = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        let month = m.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 2)))
        return (year, month)
    }

    /// Everything a claim may be backed by: profile (with its facts), posting, application facts.
    public static func buildSources(profile: Profile?, job: Job? = nil, appFacts: [String] = [],
                                    extra: [String] = [], today: Date = Date()) -> Sources {
        let profile = profile ?? Profile()
        var profileStrings: [String] = []
        if let data = try? JSONEncoder().encode(profile),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            profileStrings = flatten(obj)
        }
        let years = experienceYears(profile, today: today)
        // A listed certification backs saying "certified" (the credential words are checked by stem).
        let certified = profile.certifications.isEmpty ? "" : "certified certification"
        // Built up in steps: one long `+` chain is too much for the type checker.
        var parts: [String] = [certified]
        parts.append(contentsOf: profileStrings)
        parts.append(job?.title ?? "")
        parts.append(job?.company ?? "")
        parts.append(job?.location ?? "")
        parts.append(job?.description ?? "")
        parts.append(contentsOf: appFacts)
        parts.append(contentsOf: extra)
        if let years { parts.append(String(years)) }
        return sources(from: parts)
    }

    // MARK: - Checking

    private static func sentenceStarts(_ text: String) -> Set<Int> {
        let ns = text as NSString
        var starts: Set<Int> = []
        if let m = leadRx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            starts.insert(m.range.location + m.range.length)
        }
        let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let tns = trimmed as NSString
        for m in boundaryRx.matches(in: trimmed, range: NSRange(location: 0, length: tns.length)) {
            starts.insert(m.range.location + m.range.length)
        }
        return starts
    }

    /// Blank out section-header lines (SUMMARY, EXPERIENCE…) so they aren't read as acronyms.
    static func stripHeaders(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = trimmed as NSString
            let bare = headerPrefixRx.stringByReplacingMatches(
                in: trimmed, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            var key = bare.uppercased()
            while let last = key.last, last == ":" || last == " " { key.removeLast() }
            return resumeHeaders.contains(key) ? "" : line
        }.joined(separator: "\n")
    }

    /// What in `text` the sources don't back, in order, once each.
    public static func unverifiedFacts(in rawText: String, sources: Sources) -> [String] {
        var flags: [String] = []
        func flag(_ value: String) { if !flags.contains(value) { flags.append(value) } }

        let text = stripHeaders(rawText)
        let ns = text as NSString

        // Names: capitalised words that don't start a sentence, and acronyms anywhere.
        let starts = sentenceStarts(text)
        for m in matches(capitalisedRx, in: text) {
            let raw = ns.substring(with: m.range)
            guard raw.first?.isUppercase == true else { continue }
            let stem = possessiveRx.stringByReplacingMatches(
                in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "")
            let word = trimEnd(stem, ["-", "'", "’"])
            let lower = word.lowercased()
            // Two capitals or more (PhD, MBA, UX) mark an acronym or credential, even at a sentence start.
            let acronym = word.filter(\.isUppercase).count >= 2
            if starts.contains(m.range.location) && !acronym { continue }
            if skipWords.contains(lower) || sources.words.contains(lower) || sources.text.contains(lower) {
                continue
            }
            flag(word)
        }

        // Numbers, years and percentages, however they're formatted.
        for (raw, value) in numbers(in: text) {
            if sources.numbers.contains(value) { continue }
            // "one of the…", "a single…" aren't claims.
            if raw.allSatisfy(\.isLetter) && value <= 2 { continue }
            flag(raw)
        }

        // Credentials in words: "certified", "licensed"…
        for m in matches(credentialRx, in: text) {
            let word = ns.substring(with: m.range(at: 1))
            if !sources.text.contains(String(word.lowercased().prefix(7))) { flag(word) }
        }
        return flags
    }

    /// Flags for one document, or [] when the level opts out or the text is empty.
    public static func check(_ text: String, profile: Profile?, job: Job?,
                             honesty: HonestyConfig.Level, appFacts: [String] = [],
                             extra: [String] = [], today: Date = Date()) -> [String] {
        guard isGuarded(honesty), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let sources = buildSources(profile: profile, job: job, appFacts: appFacts,
                                   extra: extra, today: today)
        return unverifiedFacts(in: text, sources: sources)
    }

    /// Flags for both documents of an application.
    public struct DocumentFlags: Equatable, Sendable {
        public var resume: [String]
        public var coverLetter: [String]
        public init(resume: [String] = [], coverLetter: [String] = []) {
            self.resume = resume; self.coverLetter = coverLetter
        }
    }

    public static func checkDocuments(resume: String, coverLetter: String, profile: Profile?,
                                      job: Job?, honesty: HonestyConfig.Level,
                                      appFacts: [String] = [], extra: [String] = [],
                                      today: Date = Date()) -> DocumentFlags {
        DocumentFlags(
            resume: check(resume, profile: profile, job: job, honesty: honesty,
                          appFacts: appFacts, extra: extra, today: today),
            coverLetter: check(coverLetter, profile: profile, job: job, honesty: honesty,
                               appFacts: appFacts, extra: extra, today: today))
    }

    /// The one-line notice the UI shows: "Check this: A, B, C" (nil when clean).
    public static func notice(_ flags: [String], limit: Int = 8) -> String? {
        guard !flags.isEmpty else { return nil }
        let shown = flags.prefix(limit).joined(separator: ", ")
        let more = flags.count > limit ? " and \(flags.count - limit) more" : ""
        return "Check this: \(shown)\(more)"
    }
}
