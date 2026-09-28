import Foundation
import OMEMOCrypto
import OMEMOProtocol
import HrafnStore
import XMPPCore
import XMPPIM

/// How far a device is trusted: OMEMOKit's `Trust`, for the app, which does
/// not link OMEMOKit (see `Trust` for what each means).
public enum DeviceTrust: String, Sendable, Hashable, CaseIterable {
    case blind, verified, undecided, untrusted

    init(_ trust: Trust) { self = DeviceTrust(rawValue: trust.rawValue) ?? .undecided }
    var omemo: Trust { Trust(rawValue: rawValue) ?? .undecided }
}

/// A device as the trust screens show it.
public struct OMEMODevice: Sendable, Hashable, Identifiable {
    public var jid: String
    public var deviceID: UInt32
    /// The serialized identity key the user decides about.
    public var key: Data
    public var trust: DeviceTrust
    public var isActive: Bool
    public var firstSeen: Date

    public var id: String { "\(jid)/\(deviceID)" }
    /// Eight groups of eight hex digits, as other clients show it.
    public var fingerprint: String { OMEMODevice.fingerprint(of: key) }

    static func fingerprint(of key: Data) -> String {
        (try? PublicKey(serialized: key))?.fingerprint ?? key.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex without spaces, as in `xmpp:` verification URIs.
    static func hex(of key: Data) -> String? {
        (try? PublicKey(serialized: key))?.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }
}

/// What scanning a verification code did.
public struct OMEMOVerification: Sendable, Equatable {
    /// Devices now verified.
    public var verified: [UInt32] = []
    /// Devices whose key is not the one in the code: not verified. Someone
    /// may be in the middle, or the code is old.
    public var mismatched: [UInt32] = []
    /// Devices in the code that have never been seen here.
    public var unknown: [UInt32] = []
}

extension AccountManager {

    /// `jid`'s devices, updated as they change: a contact's, or our own
    /// account's other devices.
    public func omemoDevices(accountID: String, jid: String) -> AsyncThrowingStream<[OMEMODevice], any Error> {
        guard let omemo else { return AsyncThrowingStream { $0.finish() } }
        let stream = omemo.observeIdentities(accountID: accountID, jid: jid)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await identities in stream { continuation.yield(identities.map(Self.device)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// This device: its id and fingerprint. `nil` until OMEMO is set up.
    public func ownOMEMODevice(accountID: String) -> (deviceID: UInt32, fingerprint: String)? {
        guard let own = try? omemo?.ownIdentity(accountID: accountID) else { return nil }
        return (own.deviceID, OMEMODevice.fingerprint(of: own.key))
    }

    /// An `xmpp:` URI for others to scan: our address with this device's
    /// fingerprint, and those of our other devices we have verified.
    public func verificationURI(accountID: String) -> XMPPURI? {
        guard let account = accounts.first(where: { $0.id == accountID }), let jid = try? JID(account.jid),
              let own = try? omemo?.ownIdentity(accountID: accountID), let ownHex = OMEMODevice.hex(of: own.key)
        else { return nil }
        var fingerprints = [own.deviceID: ownHex]
        for device in (try? omemo?.identities(accountID: accountID, jid: account.jid)) ?? []
        where device.trust == Trust.verified.rawValue && device.isActive {
            fingerprints[device.deviceID] = OMEMODevice.hex(of: device.key)
        }
        return XMPPURI(jid: jid.bare, action: nil, omemoFingerprints: fingerprints)
    }

    /// The user's decision about a device, for the key they were shown.
    public func setTrust(_ trust: DeviceTrust, of device: OMEMODevice, accountID: String) throws {
        guard let omemo else { return }
        try omemo.setTrust(trust.omemo.rawValue, accountID: accountID, jid: device.jid, deviceID: device.deviceID,
                           key: device.key)
    }

    /// Verifies the devices a scanned code names, where the keys match what
    /// is known for them. A mismatch changes nothing.
    public func verify(_ uri: XMPPURI, accountID: String) throws -> OMEMOVerification {
        var result = OMEMOVerification()
        guard let omemo else { return result }
        let jid = uri.jid.bare.description
        let known = Dictionary(uniqueKeysWithValues: try omemo.identities(accountID: accountID, jid: jid)
            .map { ($0.deviceID, $0) })
        for (id, fingerprint) in uri.omemoFingerprints.sorted(by: { $0.key < $1.key }) {
            guard let device = known[id] else {
                result.unknown.append(id)
                continue
            }
            if OMEMODevice.hex(of: device.key) == fingerprint {
                try omemo.setTrust(Trust.verified.rawValue, accountID: accountID, jid: jid, deviceID: id, key: device.key)
                result.verified.append(id)
            } else {
                result.mismatched.append(id)
            }
        }
        return result
    }

    nonisolated static func device(_ identity: OMEMODeviceIdentity) -> OMEMODevice {
        OMEMODevice(jid: identity.jid, deviceID: identity.deviceID, key: identity.key,
                    trust: DeviceTrust(Trust(rawValue: identity.trust) ?? .undecided), isActive: identity.isActive,
                    firstSeen: identity.firstSeen)
    }
}
