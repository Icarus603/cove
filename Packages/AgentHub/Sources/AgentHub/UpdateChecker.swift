import Foundation
import CodeIslandCore
import Combine

/// Simplified update state surfaced to the About page.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case failed(String)
}

/// Stub: in the notch host, updates are owned by the host app's updater, so the
/// embedded agent engine never checks for or installs updates itself.
@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var state: UpdateState = .idle
    let isHomebrewInstall = false
    let readOnlyInstallReason: AppInstallLocation.ReadOnlyReason? = nil

    func start() {}
    func checkForUpdates() {}
    func performUpdate() {}
}
