import Foundation

/// Errors thrown by the mcs tool
enum MCSError: Error, LocalizedError {
    case invalidConfiguration(String)
    case installationFailed(component: String, reason: String)
    case fileOperationFailed(path: String, reason: String)
    case dependencyMissing(String)
    case templateError(String)
    case configurationFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            "Invalid configuration: \(message)"
        case let .installationFailed(component, reason):
            "Failed to install \(component): \(reason)"
        case let .fileOperationFailed(path, reason):
            "File operation failed at \(path): \(reason)"
        case let .dependencyMissing(name):
            "Missing dependency: \(name)"
        case let .templateError(message):
            "Template error: \(message)"
        case let .configurationFailed(reason):
            "Configuration failed: \(reason)"
        }
    }
}
