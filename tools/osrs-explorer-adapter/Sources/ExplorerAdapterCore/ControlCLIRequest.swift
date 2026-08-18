import Foundation

public enum ControlCLIRequestError: Error, CustomStringConvertible, Sendable {
    case usage

    public var description: String {
        "usage: osrs-explorerctl status|diagnostics"
    }
}

public enum ControlCLIRequestFactory {
    public static func make(arguments: [String]) throws -> AdapterRequest {
        guard let command = arguments.first else {
            return AdapterRequest(method: "status")
        }
        guard arguments.count == 1 else { throw ControlCLIRequestError.usage }
        switch command {
        case "status":
            return AdapterRequest(method: "status")
        case "diagnostics":
            return AdapterRequest(method: "diagnostics")
        default:
            throw ControlCLIRequestError.usage
        }
    }
}
