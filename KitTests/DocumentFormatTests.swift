import XCTest
@testable import JobsmithKit

/// The document format defaults to PDF; an explicit docx stays docx.
final class DocumentFormatDefaultTests: XCTestCase {
    private func decode(_ json: String) throws -> HonestyConfig {
        try JSONDecoder().decode(HonestyConfig.self, from: Data(json.utf8))
    }

    func testUnsetMeansPDF() throws {
        XCTAssertEqual(HonestyConfig().documentFormat, .pdf)
        XCTAssertEqual(try decode("{}").documentFormat, .pdf)
        XCTAssertEqual(AppConfig().honesty.documentFormat, .pdf)
    }

    func testExplicitDocxStaysDocx() throws {
        XCTAssertEqual(try decode(#"{"documentFormat": "docx"}"#).documentFormat, .docx)
        XCTAssertEqual(try decode(#"{"documentFormat": "DOCX"}"#).documentFormat, .docx)
        XCTAssertEqual(try decode(#"{"documentFormat": "pdf"}"#).documentFormat, .pdf)
    }

    func testUnknownValuesFallBackToPDFLikeTheDesktop() throws {
        XCTAssertEqual(try decode(#"{"documentFormat": "rtf"}"#).documentFormat, .pdf)
        XCTAssertEqual(try decode(#"{"documentFormat": 7}"#).documentFormat, .pdf)
        XCTAssertEqual(try decode(#"{"documentFormat": null}"#).documentFormat, .pdf)
    }

    func testRouterHandsOverWhatIsStoredWithTheMatchingNameAndType() async throws {
        let db = try AppDatabase.inMemory()
        let pdf = Data("%PDF-1.4 sample".utf8)
        let docx = Data("PK sample".utf8)
        for (bytes, ext, mime) in [(pdf, "pdf", "application/pdf"),
                                   (docx, "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")] {
            let router = NativeMessageRouter(db: db, engine: MockAIEngine(),
                                             config: { AppConfig() },
                                             activeJobStore: ActiveJobStore(fileURL: FileManager.default.temporaryDirectory
                                                .appendingPathComponent("aj_\(UUID().uuidString).json")),
                                             readDocument: { _, _ in bytes })
            let response = await router.handle(name: "getResumeFile", body: ["jobId": "j1"])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["filename"] as? String, "j1_resume.\(ext)")
            XCTAssertEqual(result["mime"] as? String, mime)
        }
    }
}
