import Foundation

/// A link session to a Mac helper, shared by every App Mode window of that Mac. The real implementation arrives with the
/// link transport; the registry only needs to know how to shut one down.
public protocol AppModeSession: AnyObject, Sendable {
    func close()
}
