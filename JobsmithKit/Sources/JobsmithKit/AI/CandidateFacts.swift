import Foundation

/// Short true statements the candidate wants the AI to know. Port of the
/// desktop `backend/facts.py`.
///
/// Two scopes: profile-wide ("Facts about me", `Profile.facts`) and
/// per-application (the `application_facts` table). Both reach every writing
/// prompt through `block`, which the services append in code, so a
/// user-overridden prompt template can't lose them.
public enum CandidateFacts {
    public static let maxFacts = 50
    public static let maxFactChars = 1000

    public enum FactError: Error, LocalizedError, Equatable {
        case empty
        case tooLong
        case tooMany

        public var errorDescription: String? {
            switch self {
            case .empty: return "A fact must not be empty"
            case .tooLong: return "A fact must be at most \(CandidateFacts.maxFactChars) characters"
            case .tooMany: return "You can keep at most \(CandidateFacts.maxFacts) facts here; remove one first"
            }
        }
    }

    /// The trimmed fact text, or a `FactError` with a user-facing reason.
    public static func clean(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw FactError.empty }
        if trimmed.unicodeScalars.count > maxFactChars { throw FactError.tooLong }
        return trimmed
    }

    public static func checkNewCount(_ current: Int) throws {
        if current >= maxFacts { throw FactError.tooMany }
    }

    /// Validate a whole list (used when a profile save carries `facts`).
    public static func cleanList(_ items: [String]) throws -> [String] {
        if items.count > maxFacts { throw FactError.tooMany }
        return try items.map(clean)
    }

    /// The usable facts of a stored list: trimmed, blanks dropped.
    public static func usable(_ raw: [String]) -> [String] {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The prompt section for both fact lists ("" when there are none).
    /// Text is the desktop `facts_block` verbatim.
    public static func block(aboutMe: [String], aboutApplication: [String],
                             honesty: HonestyConfig.Level = .honest) -> String {
        let me = aboutMe.filter { !$0.isEmpty }
        let application = aboutApplication.filter { !$0.isEmpty }
        if me.isEmpty && application.isEmpty { return "" }
        var lines = [
            "\nFACTS FROM THE CANDIDATE",
            "The candidate wrote these themselves, so they are true. Use the ones "
                + "that help this document, in your own words, rather than listing them. "
                + "Where a fact says what to emphasise or how to come across, do that, "
                + "staying within the facts.",
        ]
        if honesty == .honest || honesty == .tailored {
            lines.append("They count as part of the candidate's real background: you may "
                + "state them even when the profile above doesn't mention them.")
        }
        if !me.isEmpty {
            lines.append("About the candidate (every application):")
            lines.append(contentsOf: me.map { "- \($0)" })
        }
        if !application.isEmpty {
            lines.append("About this application:")
            lines.append(contentsOf: application.map { "- \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Convenience: the block for a profile plus this application's facts.
    public static func block(profile: Profile, applicationFacts: [String],
                             honesty: HonestyConfig.Level = .honest) -> String {
        block(aboutMe: usable(profile.facts), aboutApplication: usable(applicationFacts),
              honesty: honesty)
    }
}
