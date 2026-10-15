import Foundation
import Network
import RFBKit

/// Explains to the user why a connection failed, and what to do about it.
///
/// Kept separate from the UI so it can be tested: this is where a technical error becomes guidance, and where a vague message
/// ("The server only allows an authentication method the app does not support") once left people unsure what they got wrong.
public enum ConnectionFailureMessage {
    /// - Parameter hasUsername: whether the user entered a username. A Mac needs a macOS account name; when it is empty the app
    ///   only tries the VNC password, which a Mac accepts only if the user enabled it separately in System Settings.
    public static func text(for error: Error, hasUsername: Bool) -> String {
        if let networkError = error as? NWError { return text(for: networkError) }
        guard let error = error as? RFBError else { return tr("Couldn't connect: %@", error.localizedDescription) }
        switch error {
        case .authenticationFailed, .serverRejected:
            return hasUsername
                ? tr("Wrong username or password. Use the macOS account of that Mac, and the account must be allowed to share the screen (System Settings › General › Sharing › Screen Sharing › Allow access for).")
                : tr("The password was not accepted. If this is a Mac, enter the macOS account name as well, not just the password.")
        case .timedOut:
            return tr("Timed out. Check the address, and that the Mac is on and not asleep.")
        case .connectionClosed:
            return tr("The server closed the connection.")
        case .noCompatibleSecurityType(let offered):
            if !hasUsername, offered.contains(.appleRemoteDesktop) {
                return tr("This computer signs in with a macOS username and password. Enter the username.")
            }
            if hasUsername, !offered.contains(.appleRemoteDesktop),
               offered.contains(.vncAuthentication) || offered.contains(.noAuthentication) {
                return tr("This server does not support account sign-in, only a VNC password (weak, unencrypted). For safety the app does not switch to that automatically. If you still want to use it, leave the username empty.")
            }
            return tr("The server only allows an authentication method the app does not support.")
        case .credentialTooLong:
            return tr("The username or password is too long (63 bytes at most).")
        default:
            return tr("Protocol error: %@", "\(error)")
        }
    }

    /// Why reconnecting was abandoned after a session that had been running.
    public static func giveUp(
        _ reason: ReconnectPolicy.GiveUpReason, error: Error, name: String, attempts: Int, hasUsername: Bool
    ) -> String {
        let detail = text(for: error, hasUsername: hasUsername)
        switch reason {
        case .authenticationFailed:
            return tr("Couldn't reconnect to %@: the username or password is no longer accepted.", name)
        case .incompatible:
            return tr("Couldn't reconnect to %@: the server is not compatible. (%@)", name, detail)
        case .attemptsExhausted:
            return tr("Lost connection to %@ and couldn't reconnect after %lld attempts. Check that the Mac is on, awake and on the same network. (%@)", name, attempts, detail)
        }
    }

    /// A short code the user can read back when reporting a problem, instead of Swift's long description.
    private static func code(of error: NWError) -> String {
        switch error {
        case .posix(let code): "POSIX \(code.rawValue)"
        case .dns(let code): "DNS \(code)"
        case .tls(let status): "TLS \(status)"
        default: "\(error)"
        }
    }

    /// Network errors with what to do next. The original code is kept at the end of the sentence for diagnosis.
    static func text(for error: NWError) -> String {
        switch error {
        case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EHOSTUNREACH), .dns(-65570):
            return tr("This device has no network route to that address. Check that Wi-Fi is on and on the same network as the Mac, and that Settings › RemoteScreen › Local Network is on. (code %@)", code(of: error))
        case .posix(.ECONNREFUSED):
            return tr("The Mac refused the connection. Turn on Screen Sharing: System Settings › General › Sharing. (code %@)", code(of: error))
        case .posix(.ETIMEDOUT):
            return tr("The Mac did not answer. Check the address, and that the Mac is on and not asleep. (code %@)", code(of: error))
        default:
            return tr("Couldn't connect: %@", "\(error)")
        }
    }
}
