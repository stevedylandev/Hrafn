# iOS XMPP Client (SwiftUI) — Standards & Phased Plan (v3) - Named Hrafn

*Updated September 2026: own protocol implementation, federated, v1 = text + push + group chats + media.*

## 0. Decisions

| Decision | Choice | Consequence |
| --- | --- | --- |
| Protocol layer | **Own implementation** (`XMPPKit` Swift package) | No copyleft constraints; full control over concurrency, memory, and extension behaviour. Adds roughly 3–4 months versus using a library. |
| Licence hygiene | **Clean-room from the specs** | Don't copy or closely port code from GPL/AGPL clients (Martin, Siskin, and any other copyleft client). Use RFCs/XEPs, packet captures from your own test servers, and permissively licensed code only. |
| Dependencies | Permissive only (MIT/BSD/Apache/zlib) | e.g. GRDB (MIT), swift-nio + swift-nio-transport-services (Apache-2.0) if needed, libxml2 (MIT, ships with the SDK). Audit every package in CI. |
| Servers | Any XMPP server (federated) | Feature-detect via disco; degrade gracefully; you run the push app server. |
| v1 scope | Text, push, group chats, media | OMEMO, calls, sign-up deferred to v2. |
| Platform | iOS 17+, Swift 6 strict concurrency, SwiftUI `@Observable` |  |

---

## 1. Standards to implement

Legend: **v1** required for launch · **v1.1** soon after · **v2** later

### 1.1 Core RFCs

| Spec | Scope | Notes |
| --- | --- | --- |
| RFC 6120 XMPP Core | v1 | Streams, STARTTLS, SASL, binding, stanza/stream errors. |
| RFC 6121 IM & Presence | v1 | Roster (with versioning), subscriptions, presence. |
| RFC 7622 Address Format + RFC 8264/8265 PRECIS | v1 | JID parsing, normalisation, comparison. |
| RFC 7590 TLS in XMPP, RFC 9525 service identity | v1 | TLS ≥1.2, hostname validation. |
| RFC 4422 SASL, RFC 5802 SCRAM-SHA-1, RFC 7677 SCRAM-SHA-256 | v1 | PLAIN only over TLS, as last resort. |
| RFC 9266 `tls-exporter` channel binding | v1.1 | Enables SCRAM-\*-PLUS on TLS 1.3. |
| RFC 2782 DNS SRV | v1 | `_xmpps-client._tcp` then `_xmpp-client._tcp`, then A/AAAA fallback. |
| RFC 5122 `xmpp:` URIs | v1 | Deep links, QR codes. |
| RFC 7395 WebSocket | skip | Not needed for native. |

### 1.2 XEPs

| Area | XEPs | Scope |
| --- | --- | --- |
| Connection | 0368 Direct TLS, 0199 Ping | v1 |
| Discovery | 0030 Disco, 0115 Caps, 0004 Data Forms, 0128 | v1 |
| PubSub/PEP | 0060 (subset), 0163 PEP | v1 |
| Resilience | **0198 Stream Management**, **0352 CSI** | v1 |
| Fast auth | 0388 SASL2, 0386 Bind 2, 0484 FAST, 0474, 0440 | v1.1 (design the auth state machine for it in v1) |
| Push | **0357 Push Notifications** | v1 |
| Multi-device/history | 0280 Carbons, 0313 MAM, 0059 RSM, 0359 Stable IDs, 0297 Forwarding, 0203 Delay | v1 |
| 1:1 UX | 0085 Chat States, 0184 Receipts, 0333 Displayed Markers, 0308 Correction, 0424 Retraction | v1 |
| Contacts/profile | 0191 Blocking, 0084 Avatars, 0153/0398 vCard avatar compat, 0054 vcard-temp (read), 0292 vCard4, 0092 Version (respond) | v1 |
| Group chat | 0045 MUC, 0249 Direct Invites, 0402 Bookmarks 2 (read 0048), **0410 Self-Ping**, 0421 Occupant ID | v1 |
| Media | 0363 HTTP Upload, 0066 OOB | v1 |
| Rich media | 0447 Stateless File Sharing, 0446 File Metadata, 0264 Thumbnails | v1.1 |
| Modern UX | 0444 Reactions, 0461 Replies + 0428 Fallback, 0393 Styling, 0490 Displayed Sync, 0372 Mentions, 0425 Moderation | v1 (reactions/replies/styling/0490), v1.1 (rest) |
| Polish | 0392 Consistent Colours, 0377 Spam Reporting, 0334 Hints | v1.1 |
| E2EE | 0384 OMEMO, 0420 SCE, 0454, 0450, 0380 | v2 |
| Calls | 0166/0167/0176/0320/0353/0215 | v2 |
| Onboarding | 0077 IBR, 0379/0401 invites | v2 (+ in-app account deletion) |

Skip: BOSH, MIX, OTR, OpenPGP, stream compression (0138).

References: XEP-0479 (Compliance Suites 2023) IM + Mobile categories as the checklist; docs.modernxmpp.org for UX conventions; compliance.conversations.im to check test servers.

---

## 2. Architecture

### 2.1 Package layout

```
XMPPKit (SPM, no UIKit/SwiftUI deps — unit-testable on macOS/Linux)
  ├─ XML        push parser wrapper, Element tree, serializer, namespace handling
  ├─ Transport  SRV resolver, TCP/TLS connection, STARTTLS upgrade, framing
  ├─ Stream     stream state machine, features negotiation, SASL, binding, SM
  ├─ Core       JID/PRECIS, Stanza types, IQ tracker, router, error model
  └─ Modules    Roster, Presence, Disco/Caps, Message, Carbons, MAM, MUC, PEP,
                Bookmarks, Avatar, Upload, Push, Blocking, Receipts, Markers,
                Reactions, Replies, Correction, Retraction, SelfPing, MDS…
App
  ├─ Persistence  GRDB/SQLite in App Group (single source of truth)
  ├─ Services     AccountManager, ChatService, RoomService, MediaService, NotificationService
  └─ UI           SwiftUI + @Observable view models
NotificationServiceExtension, ShareExtension — link XMPPKit + Persistence
```

### 2.2 Concurrency model

- `XMPPClient` is an **actor** per account; modules are registered handlers keyed by (element name, namespace, stanza type).
- IQs: `func send(_ iq: IQ, timeout: Duration) async throws -> IQ` backed by an id→continuation map; all pending continuations fail on disconnect.
- Events out: `AsyncStream<ClientEvent>`; services persist first, UI observes the DB (GRDB `ValueObservation`).
- Outgoing stanzas go through one serial writer; SM counters live in the actor.

### 2.3 Transport (the tricky iOS bits)

- **SRV:** Network.framework has no SRV API → wrap `DNSServiceQueryRecord` (dns_sd) in async; sort by priority/weight; cache per TTL.
- **Direct TLS (XEP-0368):** `NWConnection` with `NWProtocolTLS` (ALPN `xmpp-client`, SNI = domain).
- **STARTTLS:** `NWConnection` can't add TLS to an established plain connection. Options, in order of preference:
  1. **swift-nio + NIOTransportServices** — insert a TLS handler into the pipeline after `<proceed/>` (Apache-2.0).
  2. `URLSessionStreamTask.startSecureConnection()` — no extra deps, less control over cert evaluation/channel binding. Spike both in Phase 1; pick one transport for both modes to avoid two code paths.
- **Cert validation:** system trust + RFC 9525 hostname check against the XMPP domain (not the SRV target); user-pinnable exceptions stored per account.
- **Channel binding (v1.1):** TLS exporter via `sec_protocol_metadata_create_secret` (label `EXPORTER-Channel-Binding`) — confirm availability through your chosen transport.
- **Framing:** stream open/close are unbalanced XML; the parser must emit per-stanza events at depth 1 and handle the stream restart after TLS/SASL.

### 2.4 XML parsing

Use the **libxml2 SAX push parser** (`xmlCreatePushParserCtxt`) via a small C shim or Swift module map: incremental, namespace-aware, fast, and MIT-licensed. Guard against entity expansion/DTDs (reject any `<!DOCTYPE`), cap stanza size (e.g. 1 MB) and depth. Serializer must escape correctly and never emit XML declarations mid-stream.

### 2.5 Persistence & identity rules

- Dedup key: archive `stanza-id` (by archive JID) → `origin-id` → `id`.
- Last-seen MAM id per archive (account + each room) for catch-up.
- Cross-process: WAL, short write transactions, per-account file lock so the app and the NSE never hold a live session for the same account at once.

---

## 3. Phases


### Phase 0 — Foundations (S)

- Repo, Xcode project (app, NSE, share extension, App Group, keychain group), `XMPPKit` package, CI with licence audit.
- Docker compose: **Prosody** and **ejabberd** on two domains (federation), MAM/push/upload/MUC enabled, plus a debug account on a couple of public servers later.
- Apply for Apple's **notification filtering entitlement** now (lead time).
- **Exit:** CI green; servers up; licence policy documented (clean-room, permissive deps).

### Phase 1 — Transport & XML (M)

- dns_sd SRV resolver, Direct TLS, STARTTLS spike → chosen transport, cert validation + exception store.
- libxml2 push parser, `Element` model, serializer, stream framing & restart.
- XML console (debug builds) with credential redaction.
- **Exit:** open stream, complete TLS both ways against both servers; fuzz tests on the parser pass.

### Phase 2 — Session establishment (M)

- Stream features negotiation; SASL SCRAM-SHA-256/-1, PLAIN fallback; SCRAM test vectors from RFC 5802/7677.
- Resource binding; stream/stanza error model; IQ tracker; router; ping; disco responder (+ caps hash generation).
- Auth state machine designed so SASL2/Bind2/FAST can slot in (v1.1).
- **Exit:** reliable login and graceful logout; unknown IQs answered with `service-unavailable`.

### Phase 3 — Mobile resilience (M)

- XEP-0198 (enable/resume/ack, outbound queue replay), XEP-0352 CSI tied to scene phase.
- `NWPathMonitor` reconnect with backoff + jitter; stale-connection detection via ping/SM `<r/>`.
- **Stretch:** SASL2 + Bind 2 + FAST — worth pulling into v1 if the NSE login time is too slow.
- **Exit:** chaos tests (network flaps, server restart, long background) with zero lost/duplicated stanzas.

### Phase 4 — 1:1 messaging (M–L)

- Roster with versioning, presence, subscription flows, add contact (JID, `xmpp:` URI, QR), blocking.
- Messages with stable IDs, receipts, chat states, displayed markers, carbons, MAM catch-up + paging, dedup, offline outbox.
- Correction and retraction.
- SwiftUI: account setup, conversation list, chat view, contact list, contact detail, settings; multi-account.
- **Exit:** daily-drivable foreground text client; history consistent with Conversations/Gajim on the same account.

### Phase 5 — Push & background (M)

- APNs registration; XEP-0357 enable/disable with publish-options; re-enable on token change.
- Deploy push app server (fpush — Apache-2.0 — or another permissively licensed option; verify licence) as an XEP-0114 component with an APNs `.p8` key.
- NSE: acquire account lock → resume/login → MAM since last id → persist → notifications → disconnect, within memory/time limits.
- Inline reply, mark-read, badge counts, per-chat mute.
- **Exit:** reliable notifications with app force-quit on both servers; no phantom alerts (with entitlement) or sensible generic text (without).

### Phase 6 — Group chats (L)

- MUC join/leave/nick/subject, occupants with roles/affiliations, room creation & config (data forms), invites.
- Bookmarks 2 (PEP) with autojoin; self-ping; occupant-id; MUC MAM; per-room notify level; mentions.
- **Exit:** rooms stay joined across days of backgrounding; correct per-room unread counts.

### Phase 7 — Media & profiles (M)

- HTTP Upload (slot → PUT with progress), send as OOB + URL body; downloads with policy (size/Wi-Fi), previews, image viewer, voice messages (m4a/AAC).
- Share extension.
- Avatars (PEP + vCard fallback), own profile editing, 0392 placeholder colours.
- **Exit:** media interop with Conversations, Monal, Gajim, Dino.

### Phase 8 — Modern UX extras (S–M)

- Reactions, replies + fallback, message styling renderer, displayed sync (0490).
- **Exit:** graceful degradation to plain text for clients without support.

### Phase 9 — Hardening & release (M)

- Security review of parser/TLS/auth code; fuzzing (parser, SCRAM, JID) in CI.
- FTS5 search, accessibility, localisation, iPad layout.
- Privacy manifest, App Store privacy labels, export compliance (TLS-only v1 is typically exempt; re-check for OMEMO).
- TestFlight across popular public servers; compliance tester; DOAP file listing supported XEPs.

---

## 4. v1.1 / v2 roadmap

- **v1.1:** SASL2/Bind2/FAST (if not pulled into Phase 3), channel binding, stateless file sharing + thumbnails, moderation, mentions, spam reporting.
- **v2:** OMEMO (implement X3DH/Double Ratchet with CryptoKit + CommonCrypto, or a permissively licensed library — note libsignal is AGPL), sign-up + invites + account deletion, A/V calls (WebRTC is BSD-licensed) with CallKit/PushKit.

---

## 5. Risks

| Risk | Mitigation |
| --- | --- |
| Schedule: protocol core is the long pole | Ship a TestFlight after Phase 5 (text + push) to get real-world feedback early. |
| Accidental copyleft contamination | Clean-room policy; review contributions; licence scanner in CI; don't read GPL client code while implementing the same feature. |
| STARTTLS / channel binding on Apple transports | Spike in Phase 1; NIO fallback. |
| Parser security (XML bombs, huge stanzas) | Reject DTDs, cap size/depth, fuzz. |
| Server diversity | Disco-driven feature flags; capability screen; recommended provider list. |
| NSE limits with full login | Profile early; SM resume; FAST. |
| App/extension DB contention | Per-account lock, WAL, concurrent integration tests. |
| Filtering entitlement delayed | Apply in Phase 0; generic-notification fallback. |

---

## 6. Open questions

1. What licence will *your* app use (closed, MIT/Apache, or still open source)?
2. Solo or team, and a target date? (Decides whether SASL2/FAST lands in v1.)
3. Bundle a recommended default server for new users?
4. iPad/macOS in v1?
