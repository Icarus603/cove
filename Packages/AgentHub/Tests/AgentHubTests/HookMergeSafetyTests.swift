import XCTest
@testable import AgentHub

/// Hooks are written into other tools' config files, so installing must never lose what was already there.
/// These run against files in a temporary folder (absolute config paths), never the real home directory.
final class HookMergeSafetyTests: XCTestCase {
    private var dir: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "hook-merge-\(UUID().uuidString)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(atPath: dir) }

    private func cli(path: String) -> CLIConfig {
        CLIConfig(name: "Test CLI", source: "gemini", configPath: path, configKey: "hooks", format: .nested,
                  events: [("SessionStart", 5, false), ("Stop", 5, false)])
    }

    private func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstallKeepsEverythingAlreadyInTheConfig() throws {
        let path = dir + "/settings.json"
        let original = #"{"model":"pro","theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}],"Custom":[{"x":1}]},"mcpServers":{"a":{"command":"x"}}}"#
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli(path: path), fm: fm))

        let result = try json(path)
        XCTAssertEqual(result["model"] as? String, "pro")
        XCTAssertEqual(result["theme"] as? String, "dark")
        XCTAssertNotNil((result["mcpServers"] as? [String: Any])?["a"])
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Custom"], "the user's own hook event survives")
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertTrue(String(describing: sessionStart).contains("echo mine"), "the user's own hook on the same event survives")
        XCTAssertEqual(sessionStart.count, 2, "ours is added beside theirs")
        XCTAssertTrue(ConfigInstaller.isHooksInstalled(for: cli(path: path), fm: fm))
    }

    func testInstallingTwiceDoesNotDuplicateHooks() throws {
        let path = dir + "/settings.json"
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli(path: path), fm: fm))
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli(path: path), fm: fm))
        let hooks = try XCTUnwrap(try json(path)["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["SessionStart"] as? [Any])?.count, 1)
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 1)
    }

    func testUninstallRemovesOnlyOurHooks() throws {
        let path = dir + "/settings.json"
        try #"{"keep":true,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli(path: path), fm: fm))
        ConfigInstaller.uninstallHooks(cli: cli(path: path), fm: fm)

        let result = try json(path)
        XCTAssertEqual(result["keep"] as? Bool, true)
        let text = String(describing: result)
        XCTAssertTrue(text.contains("echo mine"), "the user's hook is still there")
        XCTAssertFalse(ConfigInstaller.isHooksInstalled(for: cli(path: path), fm: fm))
    }
}
