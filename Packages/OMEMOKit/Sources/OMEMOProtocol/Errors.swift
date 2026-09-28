import Foundation
import XMPPCore

public enum OMEMOProtocolError: Error, Sendable, Equatable {
    case malformedBundle
    /// The device has no bundle published.
    case bundleNotFound(JID, UInt32)
    /// The message has no `<key/>` for this device.
    case notEncryptedForThisDevice
    /// A ratchet message from a device we have no session with.
    case noSession(JID, UInt32)
    /// The device is not trusted (`Trust.undecided` or `.untrusted`): left
    /// out when encrypting.
    case notTrusted(JID, UInt32)
    /// None of a recipient's devices could be encrypted for.
    case noDevices(JID)
    /// A recipient has devices, but none is trusted: the user must decide
    /// about the new ones (or has distrusted them all).
    case noTrustedDevices(JID)
    /// An OMEMO 2 envelope names another sender or conversation than the
    /// stanza it came in (XEP-0420 §5).
    case envelopeMismatch
    /// `setUp()` has not run.
    case notSetUp
}
