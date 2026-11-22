import Foundation
import os.log

enum PluginLaunchError: Error, Equatable {
    case executableMissing(String)
    case executableOutsideFolder
    case notExecutable(String)
}

/// Runs one plugin executable and speaks the line protocol with it.
/// Callbacks arrive on the main queue.
final class PluginProcess {
    private static let log = Logger(subsystem: "com.notchhub.pluginkit", category: "PluginProcess")

    let manifest: PluginManifest
    let directory: URL
    var onMessage: ((PluginMessage) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = LineBuffer()
    private let lock = NSLock()

    init(manifest: PluginManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// The plugin's executable, which must sit inside its own folder.
    func resolvedExecutable() throws -> URL {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(manifest.executable).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { throw PluginLaunchError.executableOutsideFolder }
        guard FileManager.default.fileExists(atPath: url.path) else { throw PluginLaunchError.executableMissing(manifest.executable) }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw PluginLaunchError.notExecutable(manifest.executable) }
        return url
    }

    func start() throws {
        let executable = try resolvedExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = manifest.arguments
        process.currentDirectoryURL = directory
        // A small, known environment: plugins do not inherit whatever the host was launched with.
        let home = NSHomeDirectory()
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "NOTCH_PLUGIN_ID": manifest.id,
            "NOTCH_PLUGIN_DIR": directory.path,
        ]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        stdin = input.fileHandleForWriting
        buffer = LineBuffer()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.lock()
            let lines = self.buffer.append(chunk)
            self.lock.unlock()
            let messages = lines.compactMap(PluginMessage.parse(line:))
            if !messages.isEmpty {
                DispatchQueue.main.async { messages.forEach { self.onMessage?($0) } }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [id = manifest.id] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: chunk.prefix(2000), encoding: .utf8) {
                Self.log.debug("[\(id, privacy: .public)] \(text, privacy: .public)")
            }
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.onExit?(status) }
        }
        try process.run()
        self.process = process
    }

    func send(_ message: HostMessage) {
        guard let stdin, isRunning else { return }
        // A plugin that stopped reading must not crash or block the host.
        try? stdin.write(contentsOf: message.encoded())
    }

    func stop() {
        process?.terminationHandler = nil
        stdin?.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdin = nil
    }
}
