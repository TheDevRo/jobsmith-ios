import Foundation
import CryptoKit

/// Candidate profile — the single source of truth the AI draws from.
/// Mirrors the `profile:` section of the desktop config.yaml.
public struct Profile: Codable, Equatable, Sendable {
    public var fullName: String
    public var middleName: String
    public var email: String
    public var phone: String
    public var location: String
    public var streetAddress: String
    public var streetAddress2: String
    public var city: String
    public var state: String
    public var zipCode: String
    /// Mirrors the desktop UserProfile.country default — deterministic
    /// country/phone-code answers read this instead of assuming the US.
    public var country: String
    public var linkedin: String
    public var github: String
    public var portfolio: String
    public var desiredSalary: String
    public var workAuthorization: String
    public var sponsorshipRequired: String
    /// Voluntary self-identification (EEO). Blank means "prefer not to answer";
    /// Apply Assist declines the question when these are empty.
    public var gender: String
    public var raceEthnicity: String
    public var veteranStatus: String
    public var disabilityStatus: String
    public var availableStart: String
    public var noticePeriod: String
    public var summary: String
    public var skills: [String]
    public var experience: [WorkExperience]
    public var education: [Education]
    public var certifications: [String]
    /// Appended verbatim to generated resumes — never sent to the AI.
    public var references: [Reference]
    /// "Facts about me": short true statements the AI may rely on in every
    /// writing prompt (desktop `profile.facts`). Kept on this device — the
    /// vendored profile sync contract doesn't carry it, so it is neither
    /// exported nor overwritten by an import. Capped by `CandidateFacts`.
    public var facts: [String]

    public init(
        fullName: String = "", middleName: String = "", email: String = "",
        phone: String = "", location: String = "", streetAddress: String = "",
        streetAddress2: String = "", city: String = "",
        state: String = "", zipCode: String = "",
        country: String = "United States", linkedin: String = "",
        github: String = "", portfolio: String = "", desiredSalary: String = "",
        workAuthorization: String = "", sponsorshipRequired: String = "",
        gender: String = "", raceEthnicity: String = "", veteranStatus: String = "",
        disabilityStatus: String = "",
        availableStart: String = "", noticePeriod: String = "",
        summary: String = "", skills: [String] = [],
        experience: [WorkExperience] = [], education: [Education] = [],
        certifications: [String] = [], references: [Reference] = [],
        facts: [String] = []
    ) {
        self.fullName = fullName; self.middleName = middleName; self.email = email
        self.phone = phone
        self.location = location; self.streetAddress = streetAddress
        self.streetAddress2 = streetAddress2
        self.city = city; self.state = state; self.zipCode = zipCode
        self.country = country
        self.linkedin = linkedin; self.github = github; self.portfolio = portfolio
        self.desiredSalary = desiredSalary
        self.workAuthorization = workAuthorization
        self.sponsorshipRequired = sponsorshipRequired
        self.gender = gender; self.raceEthnicity = raceEthnicity
        self.veteranStatus = veteranStatus; self.disabilityStatus = disabilityStatus
        self.availableStart = availableStart; self.noticePeriod = noticePeriod
        self.summary = summary; self.skills = skills
        self.experience = experience; self.education = education
        self.certifications = certifications; self.references = references
        self.facts = facts
    }

    // Tolerant decoding: a field added in a later build (or one whose payload
    // went bad) must not fail the whole Profile — that would reset the user's
    // resume data on upgrade. Missing/malformed fields fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = c.lenient(String.self, .fullName, "")
        middleName = c.lenient(String.self, .middleName, "")
        email = c.lenient(String.self, .email, "")
        phone = c.lenient(String.self, .phone, "")
        location = c.lenient(String.self, .location, "")
        streetAddress = c.lenient(String.self, .streetAddress, "")
        streetAddress2 = c.lenient(String.self, .streetAddress2, "")
        city = c.lenient(String.self, .city, "")
        state = c.lenient(String.self, .state, "")
        zipCode = c.lenient(String.self, .zipCode, "")
        country = c.lenient(String.self, .country, "United States")
        linkedin = c.lenient(String.self, .linkedin, "")
        github = c.lenient(String.self, .github, "")
        portfolio = c.lenient(String.self, .portfolio, "")
        desiredSalary = c.lenient(String.self, .desiredSalary, "")
        workAuthorization = c.lenient(String.self, .workAuthorization, "")
        sponsorshipRequired = c.lenient(String.self, .sponsorshipRequired, "")
        gender = c.lenient(String.self, .gender, "")
        raceEthnicity = c.lenient(String.self, .raceEthnicity, "")
        veteranStatus = c.lenient(String.self, .veteranStatus, "")
        disabilityStatus = c.lenient(String.self, .disabilityStatus, "")
        availableStart = c.lenient(String.self, .availableStart, "")
        noticePeriod = c.lenient(String.self, .noticePeriod, "")
        summary = c.lenient(String.self, .summary, "")
        skills = c.lenient([String].self, .skills, [])
        experience = c.lenient([WorkExperience].self, .experience, [])
        education = c.lenient([Education].self, .education, [])
        certifications = c.lenient([String].self, .certifications, [])
        references = c.lenient([Reference].self, .references, [])
        facts = c.lenient([String].self, .facts, [])
    }

    enum CodingKeys: String, CodingKey {
        case fullName, middleName, email, phone, location, streetAddress
        case streetAddress2, city, state, zipCode, country
        case linkedin, github, portfolio, desiredSalary, workAuthorization
        case sponsorshipRequired, gender, raceEthnicity, veteranStatus
        case disabilityStatus, availableStart, noticePeriod, summary, skills
        case experience, education, certifications, references, facts
    }

    public var isEmpty: Bool {
        fullName.isEmpty && summary.isEmpty && skills.isEmpty && experience.isEmpty
    }
}

public struct WorkExperience: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var company: String
    public var startDate: String
    public var endDate: String
    public var bullets: [String]
    /// Pinned roles are always included on tailored resumes regardless of
    /// the LLM's relevance ranking.
    public var pinned: Bool

    public init(id: UUID = UUID(), title: String = "", company: String = "",
                startDate: String = "", endDate: String = "Present",
                bullets: [String] = [], pinned: Bool = false) {
        self.id = id; self.title = title; self.company = company
        self.startDate = startDate; self.endDate = endDate
        self.bullets = bullets; self.pinned = pinned
    }

    enum CodingKeys: String, CodingKey { case id, title, company, startDate, endDate, bullets, pinned }

    // The desktop app doesn't store an `id` on entries (the sync schema makes it
    // optional), so a missing one must not fail the decode: that used to empty
    // the whole list. Every field is lenient for the same reason.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title = c.lenient(String.self, .title, "")
        let company = c.lenient(String.self, .company, "")
        let startDate = c.lenient(String.self, .startDate, "")
        let fallbackID = ProfileEntryID.derived("experience", title, company, startDate)
        self.id = c.lenient(UUID.self, .id, fallbackID)
        self.title = title
        self.company = company
        self.startDate = startDate
        self.endDate = c.lenient(String.self, .endDate, "Present")
        self.bullets = c.lenient([String].self, .bullets, [])
        self.pinned = c.lenient(Bool.self, .pinned, false)
    }
}

public struct Education: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var degree: String
    public var school: String
    public var year: String

    public init(id: UUID = UUID(), degree: String = "", school: String = "", year: String = "") {
        self.id = id; self.degree = degree; self.school = school; self.year = year
    }

    enum CodingKeys: String, CodingKey { case id, degree, school, year }

    /// Lenient for the same reason as `WorkExperience`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let degree = c.lenient(String.self, .degree, "")
        let school = c.lenient(String.self, .school, "")
        let year = c.lenient(String.self, .year, "")
        let fallbackID = ProfileEntryID.derived("education", degree, school, year)
        self.id = c.lenient(UUID.self, .id, fallbackID)
        self.degree = degree
        self.school = school
        self.year = year
    }
}

public struct Reference: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var position: String
    public var email: String
    public var phone: String

    public init(id: UUID = UUID(), name: String = "", position: String = "", email: String = "", phone: String = "") {
        self.id = id; self.name = name; self.position = position
        self.email = email; self.phone = phone
    }

    enum CodingKeys: String, CodingKey { case id, name, position, email, phone }

    /// Lenient for the same reason as `WorkExperience`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = c.lenient(String.self, .name, "")
        let email = c.lenient(String.self, .email, "")
        let phone = c.lenient(String.self, .phone, "")
        let fallbackID = ProfileEntryID.derived("reference", name, email, phone)
        self.id = c.lenient(UUID.self, .id, fallbackID)
        self.name = name
        self.position = c.lenient(String.self, .position, "")
        self.email = email
        self.phone = phone
    }
}

/// A stable id for a profile entry that arrived without one: the same content
/// always maps to the same UUID, so re-decoding (every sync) doesn't make the
/// profile look changed and get re-sent.
enum ProfileEntryID {
    static func derived(_ kind: String, _ parts: String...) -> UUID {
        let text = ([kind] + parts).joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5-style (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
