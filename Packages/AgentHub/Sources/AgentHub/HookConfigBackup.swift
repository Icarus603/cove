import Foundation

/// Copies every CLI config file hooks may touch into ~/.codeisland/backups/<timestamp>/
/// before hooks are installed, so enabling them is always reversible by hand.
enum HookConfigBackup {
    static func backupRoot(home: String = NSHomeDirectory()) -> String { home + "/.codeisland/backups" }

    /// Returns the backup folder, or nil when there was nothing to copy.
    @discardableResult
    static func backupAll(clis: [CLIConfig] = ConfigInstaller.allCLIs,
                          home: String = NSHomeDirectory(),
                          now: Date = Date(),
                          fm: FileManager = .default) -> String? {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let dest = backupRoot(home: home) + "/" + stamp
        var copied = 0
        var seen = Set<String>()
        for cli in clis {
            let src = cli.fullPath
            guard seen.insert(src).inserted, fm.fileExists(atPath: src) else { continue }
            let rel = src.hasPrefix(home) ? String(src.dropFirst(home.count)) : src
            let target = dest + rel
            do {
                try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard !fm.fileExists(atPath: target) else { continue }
                try fm.copyItem(atPath: src, toPath: target)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
                copied += 1
            } catch {
                continue
            }
        }
        return copied > 0 ? dest : nil
    }
}
