import XCTest
@testable import AgentHub

final class HookConfigBackupTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "agenthub-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func cli(_ source: String, path: String) -> CLIConfig {
        CLIConfig(name: source, source: source, configPath: path, configKey: "hooks", format: .claude, events: [])
    }

    private func write(_ relative: String, _ text: String) throws -> String {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testCopiesExistingConfigsAndLeavesOriginalsUntouched() throws {
        let claude = try write(".claude/settings.json", #"{"model":"opus","hooks":{}}"#)
        let codex = try write(".codex/hooks.json", #"{"hooks":{"x":1}}"#)
        let clis = [cli("claude", path: claude), cli("codex", path: codex), cli("gemini", path: home + "/.gemini/settings.json")]

        let dest = try XCTUnwrap(HookConfigBackup.backupAll(clis: clis, home: home))

        XCTAssertEqual(try String(contentsOfFile: dest + "/.claude/settings.json"), #"{"model":"opus","hooks":{}}"#)
        XCTAssertEqual(try String(contentsOfFile: dest + "/.codex/hooks.json"), #"{"hooks":{"x":1}}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest + "/.gemini/settings.json"), "missing configs are skipped")
        XCTAssertEqual(try String(contentsOfFile: claude), #"{"model":"opus","hooks":{}}"#, "original must not change")
    }

    func testBackupFilesArePrivate() throws {
        let claude = try write(".claude/settings.json", "{}")
        let dest = try XCTUnwrap(HookConfigBackup.backupAll(clis: [cli("claude", path: claude)], home: home))
        let attrs = try FileManager.default.attributesOfItem(atPath: dest + "/.claude/settings.json")
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNothingToBackUpReturnsNil() {
        XCTAssertNil(HookConfigBackup.backupAll(clis: [cli("claude", path: home + "/.claude/settings.json")], home: home))
    }

    func testSameFileListedTwiceIsCopiedOnce() throws {
        let claude = try write(".claude/settings.json", "{}")
        let dest = try XCTUnwrap(HookConfigBackup.backupAll(clis: [cli("a", path: claude), cli("b", path: claude)], home: home))
        let entries = try FileManager.default.contentsOfDirectory(atPath: dest + "/.claude")
        XCTAssertEqual(entries, ["settings.json"])
    }

    func testEachRunGetsItsOwnFolder() throws {
        let claude = try write(".claude/settings.json", "{}")
        let clis = [cli("claude", path: claude)]
        let first = HookConfigBackup.backupAll(clis: clis, home: home, now: Date(timeIntervalSince1970: 1_000_000))
        let second = HookConfigBackup.backupAll(clis: clis, home: home, now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotEqual(first, second)
    }
}
