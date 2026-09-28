import Foundation

/// The two versions of XEP-0384 spoken over the same ratchet core. They share
/// this device's identity, id and pre-keys, and differ in their KDF labels,
/// wire formats and payload encryption.
public enum OMEMOVersion: String, Sendable, Hashable, Codable, CaseIterable {
    /// OMEMO 0.3 (`eu.siacs.conversations.axolotl`): Signal's version-3
    /// messages, the body alone encrypted with AES-128-GCM.
    case legacy = "0.3"
    /// OMEMO 2 (`urn:xmpp:omemo:2`, XEP-0384 0.8): its own protobufs, Ed25519
    /// identity keys, and an XEP-0420 envelope encrypted with AES-256-CBC and
    /// HMAC-SHA-256.
    case v2 = "2"

    var labels: RatchetLabels {
        switch self {
        case .legacy: .legacy
        case .v2: .omemo2
        }
    }
}
