import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TerminalSelectionOpenResolverTests: XCTestCase {
    func testResolveRelativePathAgainstBaseDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("docs/plan.md")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))

        let target = TerminalSelectionOpenResolver.resolve(
            "docs/plan.md",
            baseDirectory: directory.path
        )

        XCTAssertEqual(target, .some(.external(fileURL.standardizedFileURL)))
    }

    func testResolveRelativePathWithLineSuffix() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("notes/todo.md")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))

        let target = TerminalSelectionOpenResolver.resolve(
            "notes/todo.md:12:4",
            baseDirectory: directory.path
        )

        XCTAssertEqual(target, .some(.external(fileURL.standardizedFileURL)))
    }

    func testResolveExistingRelativeFileBeforeBareHostFallback() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("README.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))

        let target = TerminalSelectionOpenResolver.resolve(
            "README.md",
            baseDirectory: directory.path
        )

        XCTAssertEqual(target, .some(.external(fileURL.standardizedFileURL)))
    }

    func testResolveHTTPSURLAsEmbeddedBrowser() {
        let target = TerminalSelectionOpenResolver.resolve(
            "https://example.com/docs",
            baseDirectory: nil
        )

        XCTAssertEqual(target, .some(.embeddedBrowser(URL(string: "https://example.com/docs")!)))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
