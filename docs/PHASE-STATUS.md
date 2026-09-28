# Phase status

Tracks PLAN.md. Update the exit criteria as they are met, rather than the prose.

## Phase 0 — Foundations · **done, with two carry-overs**

| Item | State |
| --- | --- |
| Xcode project, `XMPPKit` package | done — package linked into the app, Swift 6 language mode, iOS 17 floor |
| CI with licence audit | done — `.github/workflows/ci.yml`, `scripts/license-audit.sh` |
| Docker compose: Prosody + ejabberd on two domains | done — `docker/`, MAM/MUC/upload/SM/CSI enabled; federation only actually worked from Phase 4 (see there) |
| Licence policy documented | done — `docs/LICENSING.md` |
| App Group, keychain group, NSE, share-extension targets | done — NSE in Phase 5, share extension in Phase 7 |
| Notification filtering entitlement applied for | **carry-over** — account action, not a code change |

Both servers are up and proven: Prosody 13.0.7 (built from Prosody's own apt
repository — the `prosody/prosody` Hub images stopped at 0.11) and ejabberd 26.7
from ghcr (the Docker Hub `ejabberd/ecs` image is amd64-only and its fast_tls NIF
fails to load under emulation: `bad return value: :nif_not_loaded` on every
accepted connection). `scripts/check-servers.sh` passes on all four ports.

SASL note for Phase 2: Prosody 13 offers SCRAM-SHA-1 only, so ejabberd is
configured with `auth_scram_hash: sha256` and is the server that proves
SCRAM-SHA-256. Both advertise XEP-0440 channel binding with `tls-exporter`.

## Phase 1 — Transport & XML · **done**

| Item | State |
| --- | --- |
| dns_sd SRV resolver | done — `SRVResolver`, RFC 2782 priority/weight ordering, RDATA parsing with compression pointers rejected |
| Endpoint resolution | done — `EndpointResolver`, XEP-0368 ordering, `.` refusal, IP literals, A/AAAA fallback |
| Direct TLS | done — `NetworkTransport` (`NWConnection`), ALPN `xmpp-client`, SNI = domain |
| STARTTLS spike → chosen transport | done — `docs/TRANSPORT-SPIKE.md`; `StreamTaskTransport` for upgrades, `NetworkTransport` for Direct TLS |
| Certificate validation + exception store | done — `TLSPolicy.standard`, validated against the XMPP domain, fingerprint exceptions |
| libxml2 push parser, `Element`, serializer | done — `StreamParser`, `Element`, `Serializer` |
| Stream framing and restart | done — `XMLStream.open`/`negotiateTLS`/`restart` |
| XML console with credential redaction | done — `RedactingXMLConsole`, plus the in-app probe screen |
| Fuzz tests on the parser | done — random/mutation fuzzing, DTD, entity-bomb, depth, size, malformed input |
| **Exit: open a stream and complete TLS both ways against both servers** | **met** — Direct TLS and STARTTLS-with-restart verified against Prosody and ejabberd (`IntegrationTests.swift`, `HRAFN_INTEGRATION=1`); 97 tests pass |

Three hangs were found and fixed by running against live servers; each now has a
regression test in `StreamLivenessTests`:

1. `NWConnection` reports a rejected certificate as `.waiting(-9808)` and then
   never reaches `.failed` — it retries indefinitely. TLS errors seen in
   `.waiting` are now terminal.
2. `CheckedContinuation` ignores cancellation, so a timeout built on a task group
   could not return: the group waits for every child, and the child was parked on
   the continuation. `XMLStream.nextEvent()` and the connect path now resume their
   continuations on cancellation.
3. Closing a stream that never opened attempted the full `</stream:stream>`
   handshake against a dead transport and waited for a reply that could not come.

Known gaps carried forward deliberately:

* Certificate identity checks only the DNS-ID. SRV-IDs and `id-on-xmppAddr` SANs
  need certificate parsing (Phase 9 hardening).
* Channel binding material is exposed only on the Direct TLS path; the STARTTLS
  transport cannot produce a TLS exporter. SASL2 in v1.1 must treat
  SCRAM-*-PLUS as unavailable there.
* PRECIS does not enforce the Bidi Rule (RFC 5893) or contextual rules; the
  category checks cover everything a conforming server will send.

## Phase 2 — Session establishment · **done**

Two new targets: `XMPPStream` (SASL, negotiation, binding) and `XMPPClient`
(the per-account actor). The stanza and error model live in `XMPPCore`.

| Item | State |
| --- | --- |
| Stanza model | done — `IQ`, `Message`, `Presence` as typed views over `Element`; unguessable ids |
| Stanza/stream error model | done — `StanzaError` (all RFC 6120 §8.3.3 conditions, default types, app conditions); stream errors surface as `XMLStream.Failure.streamError` |
| SASL SCRAM-SHA-256 / -1 | done — `SCRAMMechanism`; RFC 5802 and RFC 7677 test vectors pass; server signature verified in constant time, unproven `<success/>` refused with `<abort/>`, nonce/iteration/extension checks, fuzzed |
| PLAIN fallback | done — only over TLS, only when nothing better is offered, can be disabled |
| Channel binding (pulled forward from v1.1) | done — SCRAM-*-PLUS with `tls-exporter` over Direct TLS when XEP-0440 advertises it; GS2 `y`/`n` flag chosen for downgrade detection; exporter now gated on TLS 1.3 (RFC 9266 §4.2) |
| Resource binding | done — server-generated by default; conflict/bad-request falls back to server-generated; mandatory RFC 3921 session sent, `<optional/>` skipped |
| Endpoint iteration | done — `SessionNegotiator` tries each endpoint; auth failures are fatal, transport failures fall through |
| IQ tracker | done — id→continuation, per-request timeout, cancellation, all fail with `.disconnected` on teardown; replies checked against the addressee (RFC 6120 §8.2.3) |
| Router | done — IQ get/set to registered handlers, `service-unavailable` for unknown, `bad-request` for payload-less; messages/presence on `events` in stream order |
| Serial writer | done — one `AsyncStream` outbox; `disconnect()` flushes it before `</stream:stream>` |
| XEP-0199 ping | done — responder + `ping(_:)` |
| XEP-0030 disco responder, XEP-0115 caps | done — `disco#info`/`#items` responder and queries; caps `ver` passes both XEP-0115 worked examples; §5.4 invalid inputs refused; XEP-0004 `DataForm` read/write subset |
| Auth state machine ready for SASL2/Bind2/FAST | done — `Authenticator` protocol; `AuthenticationOutcome.bound` lets SASL2 + Bind 2 skip the restart |
| **Exit: reliable login and graceful logout; unknown IQs answered with `service-unavailable`** | **met** — `ClientIntegrationTests` against Prosody and ejabberd, both transports: SCRAM-SHA-1-PLUS / SCRAM-SHA-256-PLUS over Direct TLS, SCRAM without binding over STARTTLS, wrong password rejected, peer-to-peer ping/disco/caps and `service-unavailable` through real routing, resource conflict survived; 159 tests pass |

`XMLStream` changes made along the way: restarts send `from` (the bare JID)
once encrypted (RFC 6120 §4.7.1); `nextNegotiationElement()` for bounded
negotiation reads; a second `nextEvent()` caller now supersedes the first rather
than leaking its continuation (`close()` during a session's read loop).

Carried forward:

* The caps node is configurable (`ClientIdentity.node`); the app needs a real
  URL for Hrafn before it sends caps in presence (Phase 4).
* The debug `StreamProbe` screen still stops at stream features; linking
  `XMPPClient` into the app target and adding a login button is an Xcode
  project change left for Phase 4's account setup.
* SASL2 / Bind 2 / FAST remain v1.1 (or a Phase 3 stretch).

## Phase 3 — Mobile resilience · **done**

| Item | State |
| --- | --- |
| XEP-0198 enable / ack | done — `<enable resume='true'/>` queued first on every fresh session; stanzas counted as they are *queued* (FIFO outbox, so same order as written), so anything still in the outbox at a drop is already held for replay; one `<r/>` in flight; server `<r/>` answered; counters wrap at 2^32; `handled-count-too-high` answered with the §4 stream error and a fresh session; final `<a/>` before a clean close |
| XEP-0198 resume | done — `SessionNegotiator.establish(resuming:)` sends `<resume/>` after the SASL restart instead of binding; `<enabled location=''/>` tried first; `max` honoured (no pointless resume after expiry); `<resumed h=''/>` replays exactly the unhandled stanzas |
| Outbound replay when resume fails | done — `<failed h=''/>` trims what was handled, the rest is re-sent on the fresh session; presence is not replayed (fresh session = fresh presence); pending IQs survive a resume and replayed ones survive a fresh session, the rest fail with `.disconnected` |
| Offline hold | done — while a SM session is being recovered, `send()` holds stanzas with the unacked ones; without SM it throws `notConnected` as before |
| XEP-0352 CSI | done — `setClientState(_:)`; only changes are sent, only when `<csi/>` is offered; re-sent on fresh sessions when inactive and always after a resume; becoming active also probes the connection |
| Reconnect with backoff + jitter | done — `ReconnectPolicy`: immediate first retry (fast resume), then exponential with equal jitter, capped; reset after a session stays up `stableAfter`; fatal errors (auth, certificate, `conflict`, …) stop retrying; `start()` for launch-while-offline |
| `NWPathMonitor` | done — `NetworkPathMonitor` / `SystemPathMonitor`; no attempts without a network (`.waitingForNetwork`), immediate retry when it returns or changes, and a probe when the interface changes under a live connection |
| Stale-connection detection | done — `LivenessPolicy`: after `idleInterval` of silence, `<r/>` (or a XEP-0199 ping without SM); no answer within `timeout` abandons the connection with `XMLStream.abort()` — never `</stream:stream>`, which would end the resumable session; `checkConnection()` for foreground/path changes |
| **Exit: chaos tests with zero lost/duplicated stanzas** | **met** — `ChaosIntegrationTests` through a TCP proxy (`ChaosProxy`) against Prosody and ejabberd: 40 messages each way with the link reset every 8 (all resumed, exact order, exactly once); resets during an in-flight resume (exactly once); a blackholed link (stale detected, resumed, messages sent into the void recovered once); server restart (`HRAFN_CHAOS=1`, restarts the containers: backoff, fresh session, an IQ issued during the outage answered). Scripted `StreamManagementServer` covers expiry after a long background, lost-in-transit stanzas, overclaimed counts, path changes, and CSI; 200 tests pass |

Found against the live servers:

* **Duplicates via offline storage.** Without a final `<a/>` before
  `</stream:stream>`, ejabberd treats handled stanzas as unacked and re-routes
  them to offline storage, so they come back on the next login. Fixed; a unit
  test pins the `<a/>` before the close.
* **ejabberd resumes slowly** (about a second from `<resume/>` to
  `<resumed/>`). A link cut during that window leaves the server mid-takeover.
  Nothing is lost or repeated, but ejabberd can then replay stanzas out of
  order. Prosody keeps the order. Phase 4 orders history by archive id and
  timestamp, not by arrival.

Carried forward:

* **Scene-phase wiring.** `setClientState(.inactive/.active)` is the API. It
  gets called from `scenePhase` once `XMPPClient` is linked into the app
  target (Phase 4 account setup).
* **"Handled" means handed to `events` or an IQ handler, not persisted.** A crash
  between the two loses the stanza as far as SM is concerned. Phase 4's MAM
  catch-up closes that gap. Persist before acking only if that turns out to
  matter.
* **SM state is per process.** The NSE resuming the app's session (Phase 5)
  needs `StreamManagement` exported as a Codable snapshot (id, `h`, unacked
  stanzas as XML) in the App Group.
* **The unacked queue is unbounded.** It is fine at chat rates. Cap it, or spill
  to the outbox table, when Phase 4 adds persistence.
* **Long background is scripted, not live.** Server hibernation lasts 300s
  (ejabberd) or 600s (Prosody). The expiry path is covered by the fake server,
  and live by the server-restart test.
* SASL2 / Bind 2 / FAST (the stretch goal) not started. They remain v1.1 unless
  NSE login time in Phase 5 says otherwise.

## Phase 4 — 1:1 messaging · **done, one exit check outstanding**

Three new pieces: the `XMPPIM` target in XMPPKit (the protocol), a second
package `Packages/HrafnKit` with `HrafnStore` (GRDB database) and
`HrafnServices` (one session per account, events in, database writes out), and
the SwiftUI app on top. The UI observes the database only; presence, typing and
connection state live in an `@Observable` `AccountStatus` because they do not
outlive a session.

| Item | State |
| --- | --- |
| Roster with versioning | done — `Roster.fetch(version:)` sends `ver` only when the stream offers it, handles the empty "unchanged" result; pushes accepted only from our own account (§2.1.6) and with exactly one item; set/remove never send `subscription`/`ask`; the store keeps the version with the roster |
| Presence | done — `PresenceBook` aggregates per resource (most reachable, then priority); fresh sessions reset it; own presence carries caps with the real node (`hrafnIdentity`) |
| Subscription flows | done — request, approve, deny, cancel; add-contact pre-approves (RFC 6121 §3.4); approving a request also asks for theirs; strangers' requests are kept as `pendingIn` contacts outside the roster |
| Add contact: JID, `xmpp:` URI, QR | done — `XMPPURI` (RFC 5122 + XEP-0147 message/roster/subscribe/join, percent-coding, authority refused); app handles `xmpp:` links (`Config/Hrafn-Info.plist`), shows and scans QR codes (VisionKit) |
| Blocking | done — XEP-0191 list, block, unblock, validated pushes; the list is fetched each fresh session (§3.3: pushes only reach resources that fetched it) |
| Stable ids | done — every message carries `origin-id` = `id`; `stanza-id` is only trusted when `by` is our own bare JID |
| Receipts, chat states, displayed markers | done — receipts answered for live messages from contacts who may see our presence (XEP-0184 §8); chat states sent only to peers that have sent them (XEP-0085 §5.1), transient (`no-store`); markers sent when a conversation is on screen, received markers advance every earlier message; markers from our own other devices mark messages read here |
| Carbons | done — enabled each fresh session; `InboundMessage` unwraps sent/received copies and refuses carbons not from our own bare JID (XEP-0280 §11) |
| MAM catch-up and paging | done — `MessageArchive` collects results through a new `XMPPClient` message interceptor (they never reach `events`), checks the result's `from`, pages with RSM `after`/`before`; catch-up from a per-archive cursor (fallback to time if the id expired), first login fetches the newest 100 stored as read; the cursor advances on live archive ids only after catch-up and after the write; "Load earlier" pages a conversation back |
| Dedup | done — one ingest path for live, carbon and archive copies: archive id, else sender id (origin-id/id) per peer and direction; echoes of our own messages merge into the row we wrote; receipts/markers never claim an archive id |
| Offline outbox | done — messages are stored first (`pending`), sent when a connection accepts them, flushed on the next session |
| Correction and retraction | done — XEP-0308 and XEP-0424 (with XEP-0428 fallback body); only same-direction edits apply; newer correction wins; edits whose target has not arrived yet wait in `messageEdit` and apply when it does |
| SwiftUI | done — onboarding/account setup (login verified before saving; untrusted certificate shown by fingerprint and pinned per account on consent), chats list (unread, previews, typing, drafts), chat view (states, edit, retract, copy, load earlier, day separators), contacts with requests, add contact, contact detail (rename, share QR, block, remove), settings (own status, accounts, blocked list, connection settings, remove); debug XML console and stream probe |
| Multi-account | done — `AccountManager` runs one `AccountSession` per enabled account; lists label rows with their account when there is more than one; exercised in code and unit tests, not yet by a UI test |
| Carried from Phases 2–3 | done — `XMPPClient` linked into the app; `scenePhase` drives XEP-0352 through `AccountManager.setActive`; caps node set; MAM catch-up closes the "handled but not persisted" gap |
| **Exit: daily-drivable foreground text client** | **met** — `SessionIntegrationTests` (HrafnKit, live): add contact → request → approve → mutual subscription, presence, message → receipt → displayed marker, unread counts, typing, correction, retraction, offline catch-up exactly once, outbox — on Prosody, on ejabberd, and **federated Prosody ↔ ejabberd**; `HrafnUITests` drives the real app in the simulator through onboarding, certificate trust, add contact and a chat with an echo bot |
| **Exit: history consistent with Conversations/Gajim on the same account** | **outstanding** — consistency across devices is proven between two Hrafn sessions (carbons both ways, the same archive paged both directions, `IMIntegrationTests`), but no third-party client was available here. Needs a manual pass with Conversations or Gajim logged in to the same Docker account |

Tests: XMPPKit 225 (22 new `XMPPIMTests` unit tests + live `IMIntegrationTests`),
HrafnKit 21 unit tests (ingest/dedup, roster, observation, WAL, event mapping)
plus the live session suite. All pass against both servers in repeated runs.

Found against the live servers:

* **Federation between the Docker servers never worked.** Prosody resolves with
  libunbound, whose built-in RFC 6761 zone answers every `.test` name NXDOMAIN
  regardless of Docker's DNS; and ejabberd 26.07 crashes on Prosody's s2s SASL
  EXTERNAL. Fixed in `docker/`: fixed addresses with `extra_hosts` fed to
  unbound, no test CA for ejabberd so both use dialback (`docker/README.md`).
* **ejabberd deletes a retracted message from the archive.** A client that only
  applies retractions to what it has would show the original again if it met it
  later; retractions are kept and applied on arrival.
* **Subscription requests reach only "interested" resources** (roster fetched,
  presence sent), and blocking pushes only resources that fetched the list —
  so a session must do both before it can see either.
* **Test hygiene.** Suites running in parallel under the same user received each
  other's messages, and sessions left open at process exit put their unacked
  stanzas in ejabberd offline storage for the next test. The IM suite has its
  own users (`benvolio`, `mercutio`), services tests log out before returning,
  and the Phase 3 chaos tests count only their own tagged messages (duplicates
  among them still fail).

Carried forward:

* **Interop exit check** above, with Conversations or Gajim.
* **Caps node** is `https://hrafn.stevedylandev.dev` (`hrafnIdentity`); swap in
  the project's real URL before release.
* **App Group** is still not configured (Phase 0 carry-over), so the database
  lives in the app container (`AppConfig.appGroup`). Phase 5's notification
  extension needs it moved.
* **Corrections and retractions need a connection** — they have no outbox; the
  UI reports the error.
* **The XEP-0198 unacked queue is still unbounded** (Phase 3 carry-over); spill
  to the outbox if it ever matters.
* **Group chat messages are ignored** by the store until Phase 6.
* Catch-up reads at most 20 pages of 100 per session and leaves the rest to the
  next; first-login history is the newest 100 messages across conversations.

## Phase 5 — Push & background · **code done; the device leg is untested**

| Item | State |
| --- | --- |
| XEP-0357 enable/disable with publish-options | done — `PushNotifications` (XMPPIM): support checked on the account's bare JID (§5), `<enable/>` with a `publish-options` form, `<disable/>` for one node or all; `PushNotification` parses a publish as the app server gets it |
| Re-enable on token change | done — `AccountManager.setPushToken` registers a new token with every live session right away; every fresh session registers again; removing or disabling an account unregisters first. Status shown per account in Settings ("Notifications") |
| Push app server | fpush (MIT, not Apache-2.0 as PLAN.md guessed) as a XEP-0114 component: `docker/fpush`, behind `--profile push`. It uses an APNs **.p12 certificate**, not a `.p8` key. Node = APNs token, `pushModule` = `sandbox`/`production`. Not run here (no certificate) |
| Component ports on the test servers | done — Prosody 5347 (`push.alpha.test`), ejabberd 15347 (`push.beta.test`), secret `pushsecret`; `PushComponent` (XMPPTestSupport) stands in for fpush in tests |
| App Group, keychain sharing, NSE target | done — `group.dev.stevedylandev.hrafn`; keychain group `$(AppIdentifierPrefix)dev.stevedylandev.hrafn.shared` (first in the list, so it is the default for new items); `HrafnNotificationService` target in the project, entitlements in `Config/`. The database moves from Application Support into the group container on first launch (`SharedContainer`) |
| Account lock | done — `AccountLock`: `flock` per account in the group container. The app holds it while a session runs; the extension waits up to 3 s and otherwise stands aside |
| Backgrounding | done — leaving the screen sends CSI inactive; after 20 s (or when iOS takes the background time back) the app logs out cleanly, releases the locks and suspends the database (GRDB suspension, against 0xdead10cc). Back on screen it logs in again. A clean logout means the server stores and pushes; no SM state crosses processes (the Phase 3 carry-over is not needed) |
| NSE: lock → login → MAM → persist → notify → logout | done — `BackgroundFetch`: one quiet session per account (no presence, so offline storage stays put; no carbons), catch-up from the shared cursor (same code as the app), 22 s budget. The push becomes the first message; the rest are added as separate notifications |
| Announce each message once | done — `message.notified` (migration v2). The app and the extension *claim* pending messages in one transaction. Foreground: claimed silently. Background but still connected: the app announces. Suspended: the extension does. Reading a conversation marks its messages as notified and removes its banners |
| Inline reply, mark read | done — `MESSAGE` category. A reply is stored first (outbox), so it is sent later if there is no connection. The app logs in for up to 10 s in the background to send it and the displayed marker |
| Badge | done — total unread, set by the app as it changes and by the extension on every push |
| Per-chat mute | done — `conversation.muted` (bell button in the chat). Muted messages are claimed without a banner and still count as unread |
| **Exit: reliable notifications with app force-quit on both servers** | **partly shown** — `PushPipelineTests` (live, Prosody, ejabberd, and ejabberd→Prosody federated) runs the whole chain except APNs: register, background logout, message, server publish to the app server with our options, `BackgroundFetch` finds exactly that message, a second run finds nothing, mute, lock contention, and app-side announcing. In the simulator the app got a real APNs token and Prosody published to it. **Still needed, on a device:** fpush with a certificate, real pushes, force-quit, and the NSE's time and memory limits |
| **Exit: no phantom alerts (entitlement) / sensible generic text (without)** | done in code — without the entitlement a push with nothing new shows "New message" plus the badge. `HrafnCanFilterNotifications` in the NSE's Info.plist switches to dropping it once Apple grants `com.apple.developer.usernotifications.filtering` |

Tests: XMPPKit adds `PushTests` (unit) and `PushIntegrationTests` (four
topologies, two of them federated s2s). HrafnKit adds `NotificationTests`
(claiming, read/retracted, mute, migration), `AccountLockTests`, and
`PushPipelineTests`. `HrafnPushUITests` + `PushSender` drive the simulator:
sign in, get the APNs token registered, background, and receive the server's
publish for that token, then send fpush's push with `simctl push`.

Found along the way:

* **`simctl push` does not start notification service extensions.** SpringBoard
  shows the payload as-is (`mutableContent: YES` in its log, no extension
  launch). The extension can only be exercised with real APNs.
* **Prosody's push summary** is a `form`, not a `submit`, and puts
  "New Message!" in `last-message-body`. ejabberd sends only the body field.
  Neither should be shown to the user, and Hrafn does not show it.
* **The external component namespace** (`jabber:component:accept`) has to be
  treated as `jabber:client` by the stand-in, or the stanza views reject it.
* **App-side claiming must pause while suspended.** Otherwise an in-process
  observer could take messages the extension wrote (the tests caught this;
  in production, separate processes cannot see each other's GRDB observation).

Carried forward:

* **Device QA** — fpush with an APNs certificate, pushes with the app
  force-quit on both servers, NSE time and memory, keychain sharing between app
  and extension on a real device.
* **Keychain items saved before Phase 5** stay in the app's own group, so the
  extension cannot read them. Re-enter the password (Settings → account → New
  password) or re-add the account.
* **Push service JID for release** — `AppConfig.push` points at
  `push.hrafn.stevedylandev.dev`, which does not exist yet.
* **Filtering entitlement** — still to apply for (Phase 0 carry-over).
* **In-app banners** — none in the foreground; the chat list is the
  indicator.
* **A retracted message's banner** is not withdrawn.
* **Flaky: `SessionIntegrationTests.dailyDrivable`** times out on "mutual
  subscription" in about half of full HrafnKit runs since Phase 5. It passes
  every time when run alone, so it is probably interference from the suites
  that now run beside it. Not diagnosed yet.
* SASL2/FAST was not needed to hit the time budget in tests (login + MAM takes
  about 1 s against the Docker servers); check again on a device.

## Phase 6 — Group chats · **done**

The protocol lives in `XMPPIM` (`MUC.swift`, `Bookmarks.swift`), the session
side in `AccountSession+Rooms.swift`, the store in `Rooms.swift` (migration
v3), and the UI in `RoomViews.swift` plus the chat list and chat view.

| Item | State |
| --- | --- |
| Join / leave / nick / subject | done — `MultiUserChat.join` waits for the self-presence (110) through a new `XMPPClient` presence interceptor, honours 210 (assigned nick) and 201 (created), throws the presence error (`conflict`, `registration-required`, `not-authorized`, `forbidden`, …); nick changes wait for the room's confirmation; subjects stored on the room |
| Occupants, roles, affiliations | done — `RoomOccupants` (value type) tracks presences: joins, 303 renames (ours too), kicks 307, bans 301, 321/322 removals, 332/333, and `<destroy/>` (ejabberd sends it without 110). Shown per room in `AccountStatus.rooms` |
| Room creation and configuration | done — `createRoom` finds the MUC service in disco, checks the address is free, joins (expects 201), fills the configuration form as a private group (members only, JIDs visible, invites allowed) or a public channel, archiving on (Prosody's and ejabberd's fields). `DataForm` gained options, `required`, `desc` and `submission()`; owners get a form renderer in the app |
| Invitations | done — mediated invitations for members-only rooms (the room grants membership), XEP-0249 otherwise; both parsed on receipt (rooms attach a XEP-0249 element to mediated ones, so mediated wins); stored as `roomInvite` rows, ignored from blocked JIDs, shown atop the chat list |
| Moderation | done — kick (role none), ban (outcast), membership; context menu on participants for moderators/admins; destroy for owners |
| Bookmarks 2 with autojoin | done — fetched on every fresh session (XEP-0048 private storage read when the node is empty and the server has no `#compat`), published with the whitelist/max-items publish-options, `<extensions/>` kept verbatim, `+notify` changes applied live: a new autojoin bookmark joins, a retraction leaves. Joining or creating bookmarks; leaving retracts |
| Rooms that vanished | done — a bookmarked room that disco says is gone (or whose join answers 201) is not recreated: the bookmark is dropped. Same on `<destroy/>` |
| Self-ping (XEP-0410) | done — every joined room after an SM resume, on return to the foreground, and when a room has been quiet for 15 minutes; `not-acceptable` on a groupchat send also triggers one. Not joined → rejoin and catch up |
| Occupant-id (XEP-0421) | done — trusted only from rooms that advertise it; our own is stored per room, so our messages are recognised in the archive whatever nick we used (then real JID, then nick) |
| MUC MAM | done — joins ask for no discussion history when the room archives, then read the room's archive from a per-room cursor (first join: newest page, stored as read); rooms without an archive get `history since` the newest stored message. Live `stanza-id`s move the cursor only after the join's catch-up. "Load earlier" pages the room archive |
| Messages in rooms | done — our message is stored pending, sent, and marked delivered by the room's reflection (which gives it the room's id); corrections by `id`, retractions by the room's `stanza-id` (XEP-0424 §4); only the same occupant may edit (occupant id, else nick); archive ids are unique per room (ejabberd hands out timestamps). `markSent` never moves a message back from delivered |
| Per-room notify level; mentions | done — always / mentions / never, defaulting to always for private groups and mentions for channels; mentions are the nick as a whole word, any case; the badge counts only what the level would announce; notifications carry the sender as subtitle |
| **Exit: rooms stay joined across days of backgrounding** | **met, as far as a logged-out app can be** — the app logs out 20 s after leaving the screen (Phase 5), which takes it out of every room; `RoomIntegrationTests.rejoinsAfterBackgroundAndCatchesUp` suspends and resumes twice: the room is rejoined from the bookmark, the three messages sent meanwhile arrive exactly once, unread is 3 and only the mention is announced. `selfPingRecoversASilentDrop` removes the session from the room behind its back: self-ping notices, rejoins and catches up. Both on Prosody and ejabberd |
| **Exit: correct per-room unread counts** | **met** — as above, plus `RoomIngestTests` (reflections, history read, retractions, notify levels and the badge) |

Tests: XMPPKit 250 (17 new unit tests in `MUCTests`; `MUCIntegrationTests`
live on both servers plus a federated room), HrafnKit 43 unit (room store and
mapping) plus `RoomIntegrationTests` live: private group round trip,
background rejoin, self-ping recovery, federated channel, bookmark sync
between two devices. `HrafnUITests.testCreateGroupAndChat` creates a group in
the simulator, sends, sees it delivered, opens its info and destroys it.
`scripts/dev-accounts.sh` adds rosaline/balthasar (XMPPIM) and
sampson/gregory (HrafnKit).

Found against the live servers:

* **Mediated invitations carry a XEP-0249 element too** (both servers), naming
  the room as the sender. Parsed as mediated first.
* **ejabberd's `<destroy/>` presence has no 110**, so "is this about us" also
  accepts our own nick with `<destroy/>`.
* **ejabberd PEP notifications to our own other resources are intermittent**
  (even with `+notify` in caps it has queried). Marked a known issue in
  `MUCIntegrationTests`; each fresh session fetches bookmarks anyway, and the
  two-device test runs on Prosody.
* **An empty room archive left no cursor**, so the next catch-up took new
  messages for old history (stored read). An empty cursor now means "from
  when we joined".
* **Prosody keeps tombstones** of destroyed rooms; disco on them answers
  item-not-found, which is what the vanished-room path relies on.

Carried forward:

* **No notifications for rooms while suspended.** The logged-out app is in no
  room, so nothing reaches the server's push. Needs server-side help (MucSub
  on ejabberd, `mod_muc_offline_delivery` on Prosody) or a different
  background model; room history is complete on the next foreground.
* **Private messages through a room** (type chat from an occupant JID) are
  dropped.
* **Invitations are not announced** with a notification; they appear in the
  chat list.
* **Displayed markers / XEP-0490 in rooms** — Phase 8.
* **Moderation (XEP-0425) and XEP-0372 references** — v1.1; mentions are by
  nick.
* **Members list** of a private group only shows who is online (no
  `list(.member)` in the UI yet).

## Phase 7 — Media & profiles · **done, one exit check outstanding**

The protocol is in `XMPPIM` (`HTTPUpload.swift`, `Avatars.swift`,
`ConsistentColor.swift`); the session side in `AccountSession+Media.swift`,
`FileUploader`, `HTTPTransfer`, `MediaStore` and `MediaPreparation`; the
store in `Media.swift` (migration v4: `message.attachment` as JSON, a
`profile` table); the UI in `MediaViews.swift`, the chat view and settings;
the share extension in `HrafnShare/` with `ShareDelivery`.

| Item | State |
| --- | --- |
| HTTP Upload (XEP-0363) | done — service found in disco (items, then the domain), `max-file-size` read from its form; slot request with name, size, type; slots refused unless both URLs are HTTPS; only `Authorization`, `Cookie`, `Expires` headers passed on, and none with line breaks (§4); `file-too-large` and `retry` errors parsed |
| PUT with progress | done — `HTTPTransfer` (URLSession): progress per message in `AccountStatus.transfers`; system trust, then the certificate the user pinned for the account |
| Send as OOB + URL body | done — XEP-0066 `<x><url/>` with the URL as the whole body, in chats and rooms; received the same way (a URL inside other text stays text); only `http(s)` OOB URLs are read |
| Outbox for files | done — stored first with the local copy; uploaded and sent when connected (files don't hold up the text queue); in rooms once joined; network trouble retries next session, refusals fail with the reason and can be retried |
| Downloads with policy | done — always / on Wi-Fi (no expensive networks) / never, up to 2–100 MB; size from HEAD, and a download that outgrows the limit is cancelled; files that arrive while suspended (stored by the notification extension) are considered on the next session; anything left waits for a tap |
| Previews, image viewer | done — thumbnails decoded off the main thread (ImageIO; a frame for videos), pinch/double-tap zoom, video player, QuickLook for other files, share and copy link from the context menu |
| Voice messages (m4a/AAC) | done in code — record from the composer's microphone, 64 kbit/s mono AAC, sent as `audio/mp4`; inline player, one sound at a time. **Not run**: the simulator here has no microphone access (see below) |
| Sending photos and videos | done — photos re-encoded as JPEG (≤ 2560 px) through ImageIO thumbnailing, which drops every metadata property including GPS; GIFs kept as they are; videos exported to MP4 at medium quality; files copied as they are |
| Share extension | done — `HrafnShare` target (App Group, keychain group): pick a conversation, add a message; files and text are stored as outgoing messages, then a quiet one-shot login (`ShareDelivery`) uploads and sends them; rooms, and whatever fails, wait in the outbox for the app |
| Avatars (PEP + vCard fallback) | done — XEP-0084 metadata/data (PNG preferred, hash checked), `+notify`, empty metadata = no avatar; XEP-0153 hashes in presence: a vCard photo for contacts without a PEP avatar, and for those with one a different hash means "look again" (ejabberd never notifies contacts of PEP changes, but passes presence on); contacts not checked for a day are refreshed on a fresh session (50 at most) |
| Own profile editing | done — avatar (square 192 px PNG) and XEP-0172 nickname in Settings → account; published to PEP, plus the vCard photo on servers without XEP-0398; presence re-sent afterwards so servers update the XEP-0153 hash. Nicknames name contacts the roster doesn't |
| XEP-0392 colours | done — SHA-1 angle and HSLuv (implemented from the colour-science definitions); matches the XEP's four test vectors; used for avatar placeholders (bare JID) and room nicknames |
| **Exit: media interop with Conversations, Monal, Gajim, Dino** | **outstanding** — files follow the convention those clients use (URL body + OOB) and go between Hrafn accounts on Prosody, ejabberd and federated Prosody → ejabberd; avatars between contacts on both. No third-party client was available here: needs a manual pass |

Tests: XMPPKit 263 (11 new unit tests in `MediaTests`; `MediaIntegrationTests`
live: slot, PUT and GET back on both servers, avatar and nickname between
contacts). HrafnKit 60 (12 new unit tests: attachment and profile store, file
mapping, preparation — GPS stripped, sizes, avatar, GIF, MP4) plus
`MediaIntegrationTests` live: a picture round trip including the outbox and a
"never" policy (Prosody, ejabberd, federated), a file in a room, the share
extension's delivery, avatars and nicknames, and certificate pinning for
HTTP. `HrafnUITests.testSendPhotoAndSetAvatar` picks a photo from the
simulator's library, sees it uploaded and reflected by a new group, and sets
and removes juliet's avatar. `testSendVoiceMessage` needs
`TEST_RUNNER_HRAFN_MICROPHONE=1`. `scripts/dev-accounts.sh` adds abram/peter
(XMPPIM) and friar/nurse (HrafnKit).

Found against the live servers:

* **ejabberd's upload listener had no TLS** while `put_url` said `https`, and
  its host port differed from the container's. It now listens with TLS on
  5443 on both sides; `scripts/check-servers.sh` checks both upload services.
* **Both servers route HTTP by `Host`.** Loopback requests (debug builds and
  tests, where `.test` does not resolve) keep the real `Host` header.
* **ejabberd does not send PEP notifications to contacts** (avatar, nickname),
  as with bookmarks to our own resources in Phase 6. Marked a known issue;
  the presence hash and the daily refresh cover avatars, nicknames change on
  the next refresh.
* **Prosody converts both ways** (XEP-0398: `vcard_legacy` mirrors the PEP
  avatar and nickname into the vCard); ejabberd does not, so Hrafn writes the
  vCard photo itself there.
* **The simulator's photo picker is in the app's accessibility tree**, but its
  cells are not hittable; the UI test taps their centres.
* **`AVAssetWriter.finishWriting()` (async) crashes** with a doubly resumed
  continuation on macOS; the test's movie writer uses the completion handler.

Carried forward:

* **Interop exit check** with Conversations, Monal, Gajim or Dino.
* **Device QA** — voice recording (the simulator here has no microphone
  access), the share extension from other apps, video export on iOS 17 (the
  pre-iOS 18 export path is untested), memory with large files.
* **Occupant avatars in rooms** (XEP-0153 hashes in MUC presence) are not
  fetched; participants show placeholders.
* **XEP-0447/0446/0264** (stateless file sharing, metadata, thumbnails) —
  v1.1; the size of others' files is only known from HEAD.
* **Captions**: a file and text go as two messages, as other clients do.
* **Share extension and a running app**: rows the extension stores while the
  app holds the account's lock (in its 20 s background grace) wait for the
  app's next session.
* **Files in encrypted chats** (`aesgcm://`) come with OMEMO in v2.

## Phase 8 — Modern UX extras · **done, one exit check outstanding**

The protocol is in `XMPPIM` (`Reactions.swift`, `Replies.swift`,
`MessageStyling.swift`, `DisplayedSync.swift`); the store in `Reactions.swift`
(migration v5: a `reaction` table, reply columns and `isUnstyled` on
`message`, the XEP-0490 position on `conversation`); the session side in
`AccountSession` and `EventMapping`; the UI in `MessageContent.swift` and the
chat view.

| Item | State |
| --- | --- |
| Reactions (XEP-0444) | done — each stanza is the sender's full set, `<store/>` hint, no body; one emoji per reaction on receipt (text, several emojis, duplicates dropped); chats refer to the sender's id, rooms to the room's `stanza-id`. Stored per sender (occupant id, else nick, in rooms); an older set arriving later (archive) is ignored, and an emptied set is kept so it cannot come back. Not unread, not announced |
| Replies + fallback (XEP-0461, XEP-0428) | done — sent with the original quoted as "> " lines and a code-point `<fallback><body start end/>` range; received with the range cut out (code points, per XEP-0426) and the quote kept for when the original is not stored. Rooms refer to the room's id and the occupant JID. Replies survive the outbox and are re-sent with corrections. A reply to our message in a room counts as a mention |
| Message styling (XEP-0393) | done — parser for `*strong*`, `_emphasis_`, `~strike~`, `` `code` ``, ```` ``` ```` blocks and nested `>` quotes, following §5's opening/closing rules; directives stay visible, dimmed; `<unstyled/>` honoured; fuzzed |
| Displayed sync (XEP-0490) | done — markers fetched each fresh session (after catch-up) and followed live (`+notify`); ids only trusted from our archive (chats) or the room (rooms); a marker for a message not stored yet waits and applies when it arrives (including when a live copy later gains its archive id). Reading here publishes, gathered over a second, whitelist/max-items options; never moves a marker behind one another device published. This is how rooms learn "read elsewhere" (the Phase 6 carry-over); chats also keep XEP-0333 |
| UI | done — context menu: three quick reactions, more, Reply; reaction chips under messages (tap to toggle, VoiceOver names who reacted in rooms); reply banner over the composer; quoted original in the bubble (tap scrolls to it); styled bodies |
| **Exit: graceful degradation to plain text for clients without support** | **outstanding (manual)** — by construction: a reply reads as a quote followed by the answer, styling is plain text with its markers, a reaction has no body (clients without reactions show nothing, as Conversations does). Checked between Hrafn sessions only; needs a pass with a client without these features, and with Conversations/Gajim for the ones with them |

Tests: XMPPKit 288 (25 new in `ModernUXTests`: reactions, replies and
fallback ranges, styling rules plus fuzzing, MDS parsing/validation/publish).
HrafnKit 80 (18 new: reaction and reply store, MDS apply/pending/candidate,
event mapping) plus `ModernUXIntegrationTests` live: reply and reactions on
Prosody, ejabberd and federated Prosody → ejabberd; in a room on both servers,
replies and reactions by room ids, and two devices of one account agreeing on
what is read — live and after the second device was offline.
`HrafnUITests.testReactReplyAndStyle` sends a styled message, reacts from
the context menu, replies, removes the reaction. `scripts/dev-accounts.sh`
adds escalus/potpan.

Found against the live servers:

* **ejabberd delivered the MDS notifications to our other resource** in every
  run, unlike bookmarks and avatars in Phases 6–7; the step is still marked a
  known intermittent issue there.

Carried forward:

* **Interop exit check** above.
* **Reactions and MDS in the notification extension** — `BackgroundFetch`
  stores reactions it meets but does not fetch MDS, so a room message read
  on another device may still be announced while suspended (rooms are not
  pushed anyway; see Phase 6).
* **Banners are not withdrawn** when another device reads a conversation
  (XEP-0333 or XEP-0490); the badge is correct from the next update.
* **Reactions are not announced**, including reactions to our own messages.
* **Mentions (XEP-0372), moderation (XEP-0425), room reaction restrictions**
  — v1.1.
* **Swipe to reply** — only the context menu.
* The styling parser keeps directives visible; hiding them would be a
  renderer choice.

## Phase 9 — Hardening & release · **code done; TestFlight and the compliance tester outstanding**

| Item | State |
| --- | --- |
| Security review: parser, TLS, auth | done — `docs/SECURITY-REVIEW.md`. Seven fixes: `&` in attributes came back as `&#38;` (an upload slot URL with two query parameters would PUT to the wrong place); XML-illegal characters in a message caused a stream error that XEP-0198 replayed on every reconnect; namespace declarations for prefixed attributes were lost; a per-stanza element cap (a 1 MiB stanza measured 16 MB of tree); the STARTTLS path had no TLS 1.2 floor; IDN domains were sent as U-labels in SNI and to the trust policy; certificates now match by SRV-ID and `id-on-xmppAddr` (Phase 1 carry-over), through a DER reader written for this |
| Fuzzing (parser, SCRAM, JID) in CI | done — every randomized test takes `HRAFN_FUZZ_SCALE` and prints a replayable `HRAFN_FUZZ_SEED`. New targets: serializer → parser round trip, JID fixed points, Punycode, `xmpp:` URIs, certificate DER. Nightly CI job `fuzz` runs them at 200×; clean at 30× locally |
| FTS5 search | done — migration v6: external-content FTS5 on `message.body` (unicode61, diacritics removed), kept in step by triggers through corrections and retractions, existing history indexed. `searchMessages` (every word as a prefix, newest first, no retracted messages or files). Chat list is `.searchable`: matching chats plus messages; a result opens the chat scrolled to the message and highlights it |
| iPad layout | done — Chats, Contacts and Settings are `NavigationSplitView`s in regular width (list beside the chat, contact or account) and stacks in compact width. Chats share `chatPath` between layouts, so `openChat` and links work in either; a removed account clears the Settings selection. UI tests find tabs in the bottom bar or iPadOS 18's top bar (`XCUIApplication.tab`); `testCreateGroupAndChat` and `testSearchMessages` pass on iPad Air 11-inch |
| Accessibility | done — a text message reads as one sentence (author, text, mention, edited, time, delivery state; `chat.message`) and offers Reply, three reactions, Copy, Edit and Retract in the actions rotor; messages with files, quotes or reactions keep their controls separate. Day separators are headers; unread badges read "3 unread", the room `@` "Mentions you"; avatars say only the presence the name doesn't; composer buttons follow Dynamic Type (`@ScaledMetric`); "Load earlier messages" has a 44 pt target. `testAccessibilityAudit` runs XCTest's audit on the chat, chats, contacts, settings, account and room screens: structural issues (labels, hit regions, traits) fail it; visual ones are attached as a report (see below) |
| Localisation | done (English source; no translations yet) — string catalogs in the app (`Localizable`, `InfoPlist`), both extensions, and `HrafnStore`/`HrafnServices` (`defaultLocalization: "en"`, `Bundle.module`: message previews, connection states, room errors, notification actions). Labels built in code use `String(localized:)`; plurals for participants and shared items. xcodebuild does not update catalogs, so `scripts/sync-strings.sh` builds and merges the `.stringsdata`; CI's app job runs it with `--check` |
| Privacy manifest, privacy labels, export compliance | done — `PrivacyInfo.xcprivacy` in the app and both extensions (file timestamps `C617.1`, app-group defaults `1C8F.1`); `ITSAppUsesNonExemptEncryption = NO`; reasoning and label answers in `docs/APP-STORE.md` |
| DOAP | done — `hrafn.doap` (RFCs and 46 XEPs, partial ones annotated). No compliance-suite claim until the tester has run |
| TestFlight across public servers; compliance tester | **not started** — needs a signed build and real accounts |

Tests: XMPPKit 306 (certificate identity + fixtures, parser/serializer hardening, JID/Punycode/URI fuzzers). HrafnKit 87 (7 new `SearchTests`, including the migration indexing old history). `HrafnUITests.testSearchMessages` searches from the chat list and lands on the message; `testAccessibilityAudit` audits six screens. The whole UI suite passes on iPhone 17 (the echo bot's 120 s lifetime needs `testSignInAddContactAndChat` run early or alone); plain messages are found by their VoiceOver sentence (`message(app, text, state:)`), since they are one element now.

Also: Swift 6.2 warns on an unused `try?` even with `@discardableResult`, which made CI's warnings-as-errors step fail for HrafnKit. Fixed at the five call sites.

Carried forward:

* **UI tests on iPad**: tabs are found in both layouts now, but the tests that go "back" with the navigation bar's first button (chat → list) are written for one column; only `testCreateGroupAndChat` and `testSearchMessages` are known to pass there. The audit skips on iPad (its steps assume one column, and auditing the split chat list outlasts XCTest's time limit).
* **Audit visual report** (iPhone 17, dark mode): contrast and Dynamic Type findings are almost all the iOS 26 glass bars, rows measured through them, and standard Form footers / `LabeledContent` reported as "partially unsupported". Ours: avatar initials on XEP-0392 colours "nearly pass" contrast (HSLuv lightness could be lowered for text), and the navigation-bar title/subtitle of a chat is fixed-size like any toolbar content.
* **Translations**: none yet; the catalogs are ready for them. Error text from the protocol layer (`String(describing: error)`) is English.
* **Search in scripts without spaces** (Chinese, Japanese, Thai) matches only from the start of a run. A trigram index would fix that at about three times the size.
* **SCRAM PBKDF2** costs 2.6 s at the 1,000,000-iteration ceiling (see the security review).
* UI tests leave their photo-test groups bookmarked on juliet's Docker account (they are never destroyed).

## Post-Phase 9 — carry-overs and v1.1 pulled forward · **in progress (paused)**

Work items 1–5 from the carry-over list. Code for all five is in the working
tree, uncommitted. XMPPKit 323 tests and HrafnKit 96 pass (unit + live, both
servers, repeated runs); the app and UI-test targets build; strings synced;
licence audit clean.

| Item | State |
| --- | --- |
| Flaky `SessionIntegrationTests.dailyDrivable` | **fixed** — cause: `XMPPClient.respond(to:)` ran each IQ handler in its own `Task`, so two quick roster pushes (`to`, then `both`) could apply out of order. Handlers are now chained in stream order (RFC 6120 §10.1). `handlesRequestsInStreamOrder` unit test; 0 failures in 20 full live runs (was ~1 in 5) |
| Occupant avatars in rooms | done — XEP-0153 hashes in room presence (both servers stamp them), vCard fetched through the occupant JID (both servers forward it), stored under `room@service/nick`; participants list shows them. Prosody sends `<photo>current</photo>` after an avatar is removed: new `VCardAvatars.Advertised.unverified` re-reads the vCard (at most daily) |
| Private messages through a room | done — XEP-0045 §7.5: conversation peer is the occupant JID (`RoomPrivate` in HrafnStore), live/carbon/archive copies routed there (`InboundMessage.counterpart`, `throughRoom()`), sent with `<x xmlns='muc#user'/>`; titles "nick in Room", "Message Privately" in the participant menu; excluded from XEP-0490 |
| Banner withdrawal | done — `Notifier.withdraw(keeping:)`: banners for messages no longer unread (read elsewhere, retracted) are removed; the app watches `unreadMessageIDs()`, the NSE checks after each fetch |
| XEP-0425 moderation | done — both `:0` (Prosody's `mod_muc_moderation`) and `:1` (ejabberd), announcements and archive tombstones; migration v7 (`moderatedBy`, `moderationReason`); "Remove…" for moderators in the chat menu |
| XEP-0372 mentions | done — sent for occupant nicks outside a reply's quote, read as mentions of our account or occupant JID |
| XEP-0447/0446/0264 | done — sent alongside OOB + URL body (marked fallback): name, type, size, dimensions, length, SHA-256, 64 px JPEG thumbnail as `data:` URI; received metadata fills the attachment, thumbnail shown (blurred) before download, digest checked after |
| SASL2 / Bind 2 / FAST | done — `SASL2Authenticator` (XEP-0388 + 0386, XEP-0198 enabled inside Bind 2), `HTMechanism` (HT-SHA-256-EXPR/NONE), tokens kept in the keychain beside the password (`AccountFASTTokens`), user-agent id from the account id so app and extensions share a token; a refused token is forgotten and a new connection uses the password. Initial stream header now carries `from` when already encrypted (Prosody needs it to offer FAST). Docker configs enable `sasl2*`, `muc_moderation` (Prosody) and `mod_auth_fast` (ejabberd) — restart the containers after pulling |

Decisions and findings:

* **Resumption stays on legacy SASL + `<resume/>`.** Inline XEP-0198 resume
  inside SASL2 lost a batch of stanzas on ejabberd (1 run in 8) when resume
  attempts were cut mid-authentication; the legacy path never lost one. SASL2
  and FAST are used for fresh sessions only (the NSE's cold logins benefit most).
* **ejabberd sends no stream features after SASL2**, so over SASL2 Hrafn does
  not know it supports roster versioning or CSI there (Prosody sends them and
  they are merged in). Optimisations only; roster is fetched in full.
* **ejabberd duplicates/reorders on resumption** (pre-existing, not caused by
  this work — the last commit fails the same way): it routes stanzas the old
  connection delivered, then answers `<resumed h=''/>` without counting them,
  so XEP-0198 makes us resend. Traced; same with SASL2 on or off. The two
  ejabberd chaos tests mark exactly-once/order as an intermittent known issue;
  "nothing lost" stays strict. The store dedups by origin-id.

**Where it stopped:** about to run the affected UI tests
(`TEST_RUNNER_HRAFN_INTEGRATION=1`, `testCreateGroupAndChat`,
`testSendPhotoAndSetAvatar`, `testReactReplyAndStyle`, `testSearchMessages`,
`testAccessibilityAudit`) — not yet run after these changes.

Next steps:

1. Run those UI tests; add UI coverage for moderation ("Remove…") and
   "Message Privately".
2. Update `hrafn.doap` (XEP-0388, 0386, 0484, 0425, 0372, 0447, 0446, 0264,
   0300) and `docs/SECURITY-REVIEW.md` (FAST token storage, HT mechanism,
   redaction of `initial-response`/`additional-data`/`token=`).
3. Commit (the tree also still holds the uncommitted Phase 9 work).

Still open from before: TestFlight + compliance tester, device QA, interop
passes with third-party clients, filtering entitlement, release caps node and
push JID, iPad UI-test navigation.

## v2 — OMEMO end-to-end encryption · **all 8 phases done; manual interop passes outstanding**

Design, storage, trust model and test notes are in [OMEMO.md](OMEMO.md);
this table tracks the phases. OMEMO 0.3 (`eu.siacs.conversations.axolotl`) and
OMEMO 2 (`urn:xmpp:omemo:2`) on the same ratchet core, 0.3 preferred.

| Phase | State |
| --- | --- |
| 1. Crypto core | done — `Packages/OMEMOKit` (`OMEMOCrypto`): XEdDSA (libsodium, via swift-sodium's `Clibsodium`, ISC), X3DH, Double Ratchet with skipped keys (MAX_SKIP 1000), the 0.3 Signal wire format with a hand-written protobuf codec, AES-128-GCM payloads. Every operation works on a copy, so a forged message leaves the session unchanged |
| 2. Protocol | done — `OMEMOProtocol`: device lists and bundles in PEP (open access model), `<encrypted/>`, key transport, `OMEMOEngine`. Interop checked against oldmemo as a black box (both sides initiating, key transport, several ratchet steps). Live tests: Prosody, ejabberd, federated |
| 3. Storage | done — `OMEMODatabase` (HrafnStore), a separate `OMEMO/` directory excluded from backups; identity private key in the keychain beside the password (`CredentialStore`); one commit per operation; a lost identity key starts a new device |
| 4. Services | done — `InboundStore` decrypts live, carbon, archive and notification-extension messages, storing each before its ratchet is committed; send path decides encryption per conversation (automatic / on / off, migration v8), never downgrades silently, refuses files in encrypted chats; lock menu in the chat |
| 5. Trust | done — Blind Trust Before Verification (`blind`, `verified`, `undecided`, `untrusted`); changed keys become undecided; fingerprints and `omemo-sid-` verification codes (`XMPPURI`); device lists in contact details and the account screen; new-device banner; messages from untrusted devices marked |
| 6. Group chats | done — private groups only (members only, non-anonymous): member lists plus presence, encrypted for every member's devices, sender found by occupant id / archive JID / device id; live and archive decryption; lock menu for private groups; member devices from the participants menu |
| 7. Files | done — XEP-0454: AES-256-GCM before upload, random upload name, `aesgcm://` link inside the OMEMO body (no OOB or metadata); received links downloaded and decrypted; also from the share extension, which now encrypts like the app |
| 8. OMEMO 2 | done — one device in both versions (one id, identity and pre-key pool; the identity published in Ed25519 form, XEdDSA-signed); each remote device in one version, 0.3 unless it lists only 2; a message to mixed devices carries both `<encrypted/>` elements; XEP-0420 envelope with `from`/`to` checked; bundles in one node with `max_items=max`; sessions and lists per version (OMEMO database v3). Oracle (twomemo) and live tests on Prosody, ejabberd, federated |

Tests: OMEMOKit 71 (plus the oracle suite in both versions and the live suite,
off by default), HrafnKit 135 (OMEMO 2: `OMEMOInboundTests.omemo2Contact`,
`omemo2ReplayIntoAnotherChat`, `OMEMOStoreTests` versions and migration, live
`OMEMOSessionIntegrationTests.omemo2OnlyContact`); before OMEMO 2, HrafnKit
130 (OMEMO: `OMEMOStoreTests`, `EncryptionStoreTests`, `OMEMOStorageTests`,
`OMEMOInboundTests`, `OMEMOTrustTests`, `FileEncryptionTests`, and the live
`OMEMOSessionIntegrationTests`: chats, `encryptedGroup`, `encryptedFiles`),
XMPPKit 324 (`XMPPURITests.omemoFingerprints`). All pass with warnings as errors;
the full live HrafnKit suite passed three runs in a row. The OMEMO live suite
uses its own accounts (montague, capulet; `scripts/dev-accounts.sh`).

Decisions and findings:

* **Deployed 0.3 signers set the Edwards sign bit in the signature** (the top
  bit of its last byte) instead of forcing it to 0 as XEdDSA does; about half
  of their signed pre-keys failed strict verification. Found by the interop
  oracle; `XEdDSA.verify` accepts that convention.
* **The interop oracle (oldmemo) is AGPL**, so it runs as a black box and is
  kept out of the tree (LICENSING.md rule 5). The driver script is not in the
  repository; its JSON-lines protocol is in OMEMO.md.
* **Ratchet state is never backed up.** A restored older copy would reuse
  message keys.
* **OMEMO needs the account lock.** If the app stops waiting for the
  notification extension (30 s), it connects without OMEMO.
* **Opening an `xmpp:` link never verifies a fingerprint**; only the scanner in a
  contact's Encryption section does.
* **Stale login notifications undid device-list changes.** Servers resend the
  last device list at login; re-adding ourselves to that old list restored
  removed devices. Now the current list is fetched first.
* **Cached device lists of non-contacts never refreshed** (no PEP pushes), so a
  new device was missed. Lists are now fetched once per session before use.
* **The share extension sent in the clear** into encrypted chats. It now
  encrypts, or leaves the message for the app.
* **Green shield** on encrypted messages; orange for untrusted devices; a
  crossed-out one and italic text for placeholders.
* **OMEMO 2 only where needed.** Nearly every deployed client speaks only
  0.3; Kaidan speaks only 2. A device listed in both gets 0.3 (or whichever
  version it already has a session in), so working chats never move to the
  less proven version.
* **An empty device list was trusted for the whole session.** Fetched at
  login (a room refreshing its members) before the contact published a
  device, it failed every message to them until the next session, and in
  automatic mode could have sent in the clear. Empty answers are now fetched
  again (`DeviceListFreshnessTests`). Found once the live OMEMO tests
  started from empty device lists: before, dozens of stale devices from
  earlier runs hid it, and made the first send fetch a bundle for each
  (133 on one run, past the tests' 10 s waits).
* **The oracle confirmed OMEMO 2's ambiguous points** on the first run: the
  associated data in Ed25519 form, initiator first; 32 zero bytes in an
  empty message; a 32-byte X3DH output as root key.

Outstanding:

* The encryption screens have no UI-test coverage, and have not been looked at
  in the simulator.
* A conversation with a real 0.3 client (Conversations, Dino, Gajim, Monal)
  against the Docker servers, and one with Kaidan (OMEMO 2).
* OMEMO 2-only contacts' fingerprints are shown in X25519 form; their own
  client shows Ed25519 (OMEMO.md, Trust).
* No OMEMO 2 heartbeat messages, no device labels.
* Bundles are fetched one at a time; an account with many stale devices
  makes the first message slow. Fetch in parallel, or prune (own devices
  can be removed by hand).
* Seen once in five full live HrafnKit runs:
  `PushPipelineTests.backgroundMessageIsPushedFetchedAndAnnouncedOnce`
  (Prosody) timed out. It passes alone every time and uses no OMEMO;
  probably interference from the suites beside it, as with
  `dailyDrivable` before.
* Export compliance: `ITSAppUsesNonExemptEncryption` is still `false` and must
  be settled before a build with OMEMO goes to TestFlight (APP-STORE.md).
* Our own stale devices can be removed by hand (account screen); nothing
  prunes them automatically. A changed key is shown as "New, not trusted yet"
  rather than as a key change.
* Group chats: no new-device banner in rooms (the failure names the member);
  the notification extension does not handle rooms (rooms are not pushed).
* The CI app job builds `-scheme Hrafn`, which is not a shared scheme in this
  checkout (only the two extension schemes are).
