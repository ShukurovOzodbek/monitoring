import Darwin
import Foundation

public enum ProcessActionError: Error, LocalizedError, Sendable, Equatable {
    case notFound
    /// Process belongs to root or another user; retry with `asAdministrator: true`.
    case permissionDenied
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "The process is no longer running."
        case .permissionDenied: "This process belongs to the system. Administrator rights are required."
        case .failed(let message): message
        }
    }
}

enum ProcessActions {
    /// Sends SIGTERM (polite quit) or SIGKILL (force quit).
    static func signal(pid: Int32, force: Bool, asAdministrator: Bool) async throws {
        guard pid > 1 else { throw ProcessActionError.permissionDenied }
        let sig = force ? SIGKILL : SIGTERM
        if asAdministrator {
            do {
                _ = try await Shell.runAsAdministrator("/bin/kill -\(sig) \(pid)")
            } catch AdminCommandError.cancelled {
                throw AdminCommandError.cancelled
            } catch {
                throw ProcessActionError.failed(error.localizedDescription)
            }
            return
        }
        guard kill(pid, sig) == 0 else {
            switch errno {
            case ESRCH: throw ProcessActionError.notFound
            case EPERM: throw ProcessActionError.permissionDenied
            default: throw ProcessActionError.failed(String(cString: strerror(errno)))
            }
        }
    }
}
