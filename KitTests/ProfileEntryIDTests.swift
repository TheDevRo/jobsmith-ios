import XCTest
@testable import JobsmithKit

/// The desktop app stores experience, education and reference entries without an
/// `id` (the sync schema makes it optional). The iPhone used to require one, so a
/// synced profile decoded with those lists silently emptied.
final class ProfileEntryIDTests: XCTestCase {
    /// A canonical profile shaped exactly like the desktop's: snake_case keys, no ids.
    private func desktopShapedCanonical() -> [String: JSONValue] {
        let experience: [[String: Any]] = [
            ["title": "Role A", "company": "Company A", "start_date": "2020",
             "end_date": "Present", "bullets": ["Did a thing"], "pinned": true],
            ["title": "Role B", "company": "Company B", "start_date": "2016",
             "end_date": "2020", "bullets": [String](), "pinned": false],
        ]
        let education: [[String: Any]] = [["degree": "B.A.", "school": "School A", "year": "2015"]]
        let references: [[String: Any]] = [["name": "Ref A", "position": "Manager",
                                            "email": "ref@example.com", "phone": "555-0100"]]
        let canonical: [String: Any] = [
            "full_name": "Test Person",
            "experience": experience,
            "education": education,
            "references": references,
        ]
        return JSONValue.from(canonical).objectValue ?? [:]
    }

    private func decodeSynced() -> Profile {
        SyncManager.dictToProfile(SyncEntities.profileCanonicalToIOS(desktopShapedCanonical()))
    }

    func testEntriesWithoutAnIdSurviveTheSync() {
        let p = decodeSynced()
        XCTAssertEqual(p.fullName, "Test Person")
        XCTAssertEqual(p.experience.map(\.title), ["Role A", "Role B"])
        XCTAssertEqual(p.experience[0].bullets, ["Did a thing"])
        XCTAssertTrue(p.experience[0].pinned)
        XCTAssertEqual(p.education.map(\.school), ["School A"])
        XCTAssertEqual(p.references.map(\.name), ["Ref A"])
    }

    /// Re-decoding the same entry must give the same id, or every sync would
    /// see a "changed" profile and send it back out.
    func testMissingIdsAreStableAcrossDecodes() {
        let a = decodeSynced(), b = decodeSynced()
        XCTAssertEqual(a.experience.map(\.id), b.experience.map(\.id))
        XCTAssertEqual(a.education.map(\.id), b.education.map(\.id))
        XCTAssertEqual(a.references.map(\.id), b.references.map(\.id))
        XCTAssertNotEqual(a.experience[0].id, a.experience[1].id)
    }

    func testAnExistingIdIsKept() throws {
        let id = UUID()
        let json = #"{"experience":[{"id":"\#(id.uuidString)","title":"Role A"}]}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(p.experience.first?.id, id)
        XCTAssertEqual(p.experience.first?.endDate, "Present")
    }

    /// One malformed field must not drop the entry, let alone the list.
    func testAMalformedFieldKeepsTheEntry() throws {
        let json = #"{"education":[{"degree":"B.A.","year":2015},{"degree":"M.S."}]}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(p.education.map(\.degree), ["B.A.", "M.S."])
    }

    func testIdsRoundTripThroughExport() {
        let p = decodeSynced()
        let back = SyncManager.dictToProfile(SyncManager.profileToDict(p))
        XCTAssertEqual(back.experience.map(\.id), p.experience.map(\.id))
        XCTAssertEqual(back, p)
    }
}
