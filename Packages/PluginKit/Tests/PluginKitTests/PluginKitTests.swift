import Foundation
import NotchKit
import Testing
@testable import PluginKit

// MARK: - Manifest

struct ManifestTests {
    private func decode(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    @Test func decodesWithDefaults() throws {
        let m = try decode(#"{"id":"com.x.clock","name":"Clock","executable":"run.sh"}"#)
        #expect(m.symbol == "puzzlepiece.extension")
        #expect(m.order == 200)
        #expect(m.arguments.isEmpty)
        #expect(m.name.resolve(for: "zh-Hant-TW") == "Clock")
    }

    @Test func localizedNameFallsBackThroughScriptAndRegion() throws {
        let m = try decode(#"{"id":"a","name":{"default":"Clock","zh-Hant":"時鐘","zh":"时钟"},"executable":"r"}"#)
        #expect(m.name.resolve(for: "zh-Hant-TW") == "時鐘")
        #expect(m.name.resolve(for: "zh-Hans-CN") == "时钟")
        #expect(m.name.resolve(for: "fr") == "Clock")
    }

    @Test func rejectsBadIDAndEscapingExecutable() {
        #expect(throws: (any Error).self) { try decode(#"{"id":"a b","name":"x","executable":"r"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"id":"a","name":"x","executable":"/bin/sh"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"id":"a","name":"x","executable":"../evil"}"#) }
    }
}

// MARK: - Protocol

struct ProtocolTests {
    @Test func parsesRenderTree() throws {
        let line = #"{"type":"render","root":{"type":"vstack","children":[{"type":"text","text":"Hi","style":"title","color":"green"},{"type":"button","id":"go","title":"Go"},{"type":"progress","value":2}]}}"#
        let message = PluginMessage.parse(line: Data(line.utf8))
        guard case .render(.vstack(_, let children)) = message else { Issue.record("not a render"); return }
        #expect(children.count == 3)
        #expect(children[0] == .text("Hi", style: .title, tint: .green))
        #expect(children[2] == .progress(value: 1, label: nil)) // clamped
    }

    @Test func parsesAttentionAndAccessory() {
        #expect(PluginMessage.parse(line: Data(#"{"type":"attention","level":"needsInput"}"#.utf8)) == .attention(.needsInput))
        #expect(PluginMessage.parse(line: Data(#"{"type":"accessory","symbol":"bolt","text":"3"}"#.utf8)) == .accessory(symbol: "bolt", text: "3"))
    }

    @Test func ignoresGarbageAndUnknown() {
        #expect(PluginMessage.parse(line: Data("not json".utf8)) == nil)
        #expect(PluginMessage.parse(line: Data(#"{"type":"mystery"}"#.utf8)) == nil)
        #expect(PluginMessage.parse(line: Data(#"{"type":"attention","level":"loud"}"#.utf8)) == nil)
        #expect(PluginMessage.parse(line: Data(#"{"type":"render","root":{"type":"nope"}}"#.utf8)) == nil)
    }

    @Test func refusesAbsurdNesting() {
        var json = #"{"type":"spacer"}"#
        for _ in 0..<60 { json = #"{"type":"vstack","children":["# + json + "]}" }
        #expect(PluginMessage.parse(line: Data((#"{"type":"render","root":"# + json + "}").utf8)) == nil)
    }

    @Test func encodesHostMessages() {
        let hello = String(decoding: HostMessage.hello(locale: "zh-Hant").encoded(), as: UTF8.self)
        #expect(hello == #"{"locale":"zh-Hant","protocol":1,"type":"hello"}"# + "\n")
        #expect(String(decoding: HostMessage.action(id: "go").encoded(), as: UTF8.self) == #"{"id":"go","type":"action"}"# + "\n")
    }

    @Test func lineBufferSplitsAcrossChunksAndDropsOverlong() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("ab".utf8)).isEmpty)
        let lines = buffer.append(Data("c\nde\nf".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["abc", "de"])
        #expect(buffer.append(Data("g\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["fg"])

        var big = LineBuffer()
        let huge = Data(repeating: 0x61, count: PluginMessage.maxLineBytes + 10) + Data("\nok\n".utf8)
        #expect(big.append(huge).map { String(decoding: $0, as: UTF8.self) } == ["ok"])
    }
}

// MARK: - Discovery and process

@MainActor
struct ManagerTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pluginkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePlugin(_ root: URL, folder: String, id: String, script: String) throws {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"id":"\#(id)","name":{"default":"P \#(id)","zh-Hant":"外掛 \#(id)"},"symbol":"star","executable":"run.sh"}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let exe = dir.appendingPathComponent("run.sh")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }

    private func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @Test func installCopiesSwitchedOffAndRejectsBadOrDuplicate() throws {
        let plugins = try makeRoot(), incoming = try makeRoot()
        defer { try? FileManager.default.removeItem(at: plugins); try? FileManager.default.removeItem(at: incoming) }
        try writePlugin(incoming, folder: "fresh", id: "fresh", script: "#!/bin/sh\n")
        try FileManager.default.createDirectory(at: incoming.appendingPathComponent("nomanifest"), withIntermediateDirectories: true)
        let manager = PluginManager(directory: plugins, registry: ModuleRegistry(), defaults: UserDefaults(suiteName: "pk-\(UUID().uuidString)")!)
        manager.reload()

        let manifest = try manager.install(from: incoming.appendingPathComponent("fresh"))
        #expect(manifest.id == "fresh")
        #expect(manager.discovered.contains { $0.manifest?.id == "fresh" })
        #expect(!manager.isEnabled("fresh"))                    // installing is not consent to run it
        #expect(throws: PluginManager.InstallError.self) { try manager.install(from: incoming.appendingPathComponent("fresh")) }
        #expect(throws: PluginManager.InstallError.self) { try manager.install(from: incoming.appendingPathComponent("nomanifest")) }
    }

    @Test func discoversValidAndReportsBroken() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin(root, folder: "good", id: "good", script: "#!/bin/sh\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "pk-\(UUID().uuidString)")!
        let manager = PluginManager(directory: root, registry: ModuleRegistry(), defaults: defaults)
        manager.reload()
        #expect(manager.discovered.count == 2)
        #expect(manager.discovered.contains { $0.manifest?.id == "good" && $0.problem == nil })
        #expect(manager.discovered.contains { $0.manifest == nil && $0.problem == "manifest.json not found" })
    }

    @Test func nothingRunsUntilEnabled() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin(root, folder: "p", id: "p", script: "#!/bin/sh\nsleep 5\n")
        let registry = ModuleRegistry()
        let manager = PluginManager(directory: root, registry: registry, defaults: UserDefaults(suiteName: "pk-\(UUID().uuidString)")!)
        manager.reload()
        #expect(registry.modules.isEmpty)
    }

    @Test func enabledPluginRendersAndAnswersActions() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        // Greets on hello, then echoes every action id back as text; raises attention on activate.
        try writePlugin(root, folder: "echo", id: "echo", script: """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"type":"hello"'*) echo '{"type":"render","root":{"type":"text","text":"hello"}}' ;;
            *'"type":"activate"'*) echo '{"type":"attention","level":"needsInput"}' ;;
            *'"type":"action"'*) id=$(echo "$line" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/'); echo "{\\"type\\":\\"render\\",\\"root\\":{\\"type\\":\\"text\\",\\"text\\":\\"got $id\\"}}" ;;
          esac
        done
        """)
        let registry = ModuleRegistry()
        let manager = PluginManager(directory: root, registry: registry,
                                    defaults: UserDefaults(suiteName: "pk-\(UUID().uuidString)")!, language: "zh-Hant-TW")
        manager.reload()
        manager.setEnabled(true, id: "echo")
        #expect(registry.modules.count == 1)
        let module = try #require(registry.modules.first as? PluginModule)
        #expect(module.id == "plugin.echo")
        #expect(module.title == "外掛 echo")

        module.activate()
        #expect(await wait { module.attention == .needsInput })

        manager.setEnabled(false, id: "echo")
        #expect(registry.modules.isEmpty)
        manager.shutdown()
    }

    @Test func enabledStateSurvivesRestart() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin(root, folder: "p", id: "p", script: "#!/bin/sh\nsleep 5\n")
        let defaults = UserDefaults(suiteName: "pk-\(UUID().uuidString)")!
        let first = PluginManager(directory: root, registry: ModuleRegistry(), defaults: defaults)
        first.reload(); first.setEnabled(true, id: "p"); first.shutdown()

        let registry = ModuleRegistry()
        let second = PluginManager(directory: root, registry: registry, defaults: defaults)
        second.reload()
        #expect(registry.modules.map(\.id) == ["plugin.p"])
        second.shutdown()
    }

    @Test func refusesExecutableThatEscapesItsFolder() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin(root, folder: "p", id: "p", script: "#!/bin/sh\n")
        let outside = root.appendingPathComponent("outside.sh")
        try "#!/bin/sh\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        // A symlink inside the folder that points out of it must not be run.
        let link = root.appendingPathComponent("p/run.sh")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id":"p","name":"p","executable":"run.sh"}"#.utf8))
        let process = PluginProcess(manifest: manifest, directory: root.appendingPathComponent("p"))
        #expect(throws: PluginLaunchError.executableOutsideFolder) { try process.resolvedExecutable() }
    }
}
