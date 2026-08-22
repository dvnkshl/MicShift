import ServiceManagement

@MainActor
struct LaunchAtLoginManager {
    enum State: Equatable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable
    }

    var state: State {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func toggle() throws {
        switch state {
        case .enabled, .requiresApproval:
            try SMAppService.mainApp.unregister()
        case .disabled, .unavailable:
            try SMAppService.mainApp.register()
        }
    }
}
