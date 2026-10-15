import RFBKit

/// Security reminders shown while connecting, kept separate from the UI so they can be tested.
///
/// RFB does not encrypt the data stream: the screen, keystrokes and clipboard travel in the clear. Apple's login (type 30) only
/// protects the username and password. The other two authentication methods are weaker still, so they are flagged all session.
public enum ConnectionSecurityNotice {
    /// Shown in the login dialog, before the user sends a password.
    public static var loginFooter: String {
        tr("Screen images, keystrokes and the clipboard are not encrypted in transit. Use only on a trusted network, or through a VPN or SSH.")
    }

    /// Warning shown all session, or `nil` if the authentication method needs no extra caution.
    public static func sessionWarning(for type: RFBSecurityType?) -> String? {
        switch type {
        case .vncAuthentication?:
            return tr("Signed in with a VNC password (weak). Use only on a trusted network.")
        case .noAuthentication?:
            return tr("This computer does not require a login. Anyone on the network can view it.")
        default:
            return nil
        }
    }
}
