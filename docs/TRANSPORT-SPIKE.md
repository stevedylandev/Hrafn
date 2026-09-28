# Transport spike: STARTTLS on Apple platforms

PLAN.md Phase 1 called for spiking both STARTTLS approaches and picking one
transport for both modes. Measured on Xcode 26.1 / iOS 26 SDK; the conclusion is
that **one transport cannot serve both modes well**, so Hrafn ships two behind
`StreamTransport`.

## The constraint

`NWConnection` takes its TLS configuration in `NWParameters` at construction.
There is no API to insert TLS into a running connection, so the RFC 6120 §5
sequence — plaintext stream, `<starttls/>`, `<proceed/>`, *then* handshake — is
not expressible. This is a framework limitation, not a configuration mistake.

## Options considered

| Option | Verdict |
| --- | --- |
| **swift-nio + NIOTransportServices**, TLS handler inserted after `<proceed/>` | Works, and is the only option with full control of the handshake. Costs two Apache-2.0 dependencies and a second TLS stack (BoringSSL via swift-nio-ssl) whose trust evaluation differs from the system's — meaning two certificate-validation code paths to keep correct, and a bigger security-review surface. Rejected for v1. |
| **`URLSessionStreamTask.startSecureConnection()`** | Works, no dependencies, system trust evaluation. Costs: no ALPN control, no TLS exporter (so no channel binding), and no connection-ready signal, so dial failures surface on the first read. **Chosen for the STARTTLS path.** |
| **`NWConnection`** | Cannot upgrade in place. **Chosen for the Direct TLS path**, where it is strictly better: ALPN `xmpp-client`, system trust, and `sec_protocol_metadata_create_secret` for the RFC 9266 exporter that SCRAM-*-PLUS needs in v1.1. |

## What Hrafn does

* `NetworkTransport` (`NWConnection`) — XEP-0368 Direct TLS. Preferred: the
  endpoint resolver returns `_xmpps-client._tcp` candidates first, so this is the
  path most connections take.
* `StreamTaskTransport` (`URLSessionStreamTask`) — RFC 6120 STARTTLS, for servers
  that offer no Direct TLS port.
* `TransportFactory.make(endpoint:policy:)` picks between them. Both implement
  `StreamTransport`, so `XMLStream` and everything above it is unaware of the
  split.

Consequence to keep in mind: **channel binding (v1.1) only works over Direct
TLS.** `channelBindingExporter()` returns `nil` on the STARTTLS path, so the
SASL2 code must treat SCRAM-*-PLUS as unavailable there rather than assuming it.

## Certificate identity

Both transports validate against the **XMPP domain**, never the host from DNS:
SRV answers are unauthenticated (RFC 6120 §13.7.2.1). `TLSPolicy.standard`
performs system trust evaluation with `SecPolicyCreateSSL(true, domain)`, then
falls back to a user-approved leaf fingerprint from a `TrustExceptionStore`.

Known gap: only the DNS-ID is checked. RFC 9525 §6.5 SRV-IDs and RFC 6120
§13.7.1.2 `id-on-xmppAddr` SANs need certificate parsing, which is not
implemented — a server presenting only those identities requires an explicit
user exception. Tracked for Phase 9 hardening.
