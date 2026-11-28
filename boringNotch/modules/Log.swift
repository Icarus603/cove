import Foundation
import os

/// App logging on the unified log (`log stream --predicate 'subsystem == "app.cove.notch"'`, or Console.app).
/// `debug` and `info` are not kept in release builds; `notice` and `error` are. The category is the file the call is in.
enum Log {
    private static let subsystem = "app.cove.notch"

    private static func logger(_ fileID: String) -> os.Logger {
        let name = fileID.split(separator: "/").last.map { String($0.dropLast(".swift".count)) } ?? fileID
        return os.Logger(subsystem: subsystem, category: name)
    }

    static func debug(_ message: @autoclosure () -> String, fileID: String = #fileID) {
        let text = message()
        logger(fileID).debug("\(text)")
    }

    static func info(_ message: @autoclosure () -> String, fileID: String = #fileID) {
        let text = message()
        logger(fileID).info("\(text)")
    }

    static func notice(_ message: @autoclosure () -> String, fileID: String = #fileID) {
        let text = message()
        logger(fileID).notice("\(text, privacy: .public)")
    }

    static func error(_ message: @autoclosure () -> String, fileID: String = #fileID) {
        let text = message()
        logger(fileID).error("\(text, privacy: .public)")
    }
}
