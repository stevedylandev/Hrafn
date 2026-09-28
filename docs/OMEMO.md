# OMEMO

End-to-end encryption (XEP-0384), v2 in PLAN.md §4. Both protocol versions
run over one ratchet core:

* **OMEMO 0.3** (`eu.siacs.conversations.axolotl`). Nearly every deployed
  client speaks only this: Conversations and its forks, Monal, Dino, Gajim,
  Profanity, Movim.
* **OMEMO 2** (`urn:xmpp:omemo:2`, with XEP-0420 SCE). Kaidan speaks only
  this; python-omemo based clients speak both. Hrafn uses it only for devices
  that do not list themselves in 0.3 (see "OMEMO 2" below).

## Package

`Packages/OMEMOKit`, separate so XMPPKit stays dependency-free. The one
dependency is libsodium (ISC, via swift-sodium's `Clibsodium`), used for the
Edwards-curve operations CryptoKit does not expose. Everything else is
CryptoKit (X25519, HKDF, HMAC, AES-GCM, SHA-512) and CommonCrypto (AES-CBC).

| File | Spec |
| --- | --- |
| `XEdDSA.swift`, `Field25519.swift` | XEdDSA (Perrin 2016) §2–4; RFC 7748 §4.1 for u → y |
| `Keys.swift`, `Device.swift` | Key pairs, signed pre-keys, pre-keys, bundles (XEP-0384 0.3 §4.2–4.3) |
| `Ratchet.swift` | X3DH §3.3–3.4, Double Ratchet §3.5 and §5.2 |
| `Session.swift` | Sessions per remote device, pre-key messages, older states kept for messages in flight |
| `LegacyWireFormat.swift`, `Protobuf.swift` | The 0.3 `<key/>` contents: version 3 Signal messages |
| `LegacyPayload.swift` | 0.3 payload: AES-128-GCM, key plus tag through the ratchet (§4.5) |
| `Version.swift` | `OMEMOVersion`: `.legacy` (0.3) and `.v2` |
| `OMEMO2WireFormat.swift` | OMEMO 2's `OMEMOMessage`, `OMEMOAuthenticatedMessage`, `OMEMOKeyExchange` (0.8 §7) |
| `OMEMO2Payload.swift` | OMEMO 2 payload: HKDF "OMEMO Payload", AES-256-CBC, 16-byte HMAC (0.8 §6.1) |

`OMEMOProtocol` sits on top of it and depends on XMPPKit:

| File | What |
| --- | --- |
| `LegacyXML.swift` | Device lists and 0.3 `<bundle/>` (§4.2–4.3) |
| `OMEMO2XML.swift` | OMEMO 2's nodes, `<bundle/>` (0.8 §5.3), and `SCEEnvelope` (XEP-0420) |
| `EncryptedXML.swift` | `<encrypted/>` of either version; `EncryptedMessage` (one element per version); `Message.omemo(…)` with an XEP-0380 marker, a `<store/>` hint and a fallback body |
| `Directory.swift` | `OMEMODirectory` and `PEPDirectory`: lists and bundles in PEP with `access_model=open`, falling back to a plain publish on `<conflict/>`; parses device list notifications |
| `Store.swift` | `OMEMOStore`, synchronous, with an in-memory implementation (GRDB comes in phase 3) |
| `Engine.swift` | `OMEMOEngine`, one actor per account (details below) |

`OMEMOEngine`:

* Publishes this device.
* Encrypts for every device of the recipients and of our own account.
* Decrypts, consuming the used pre-key and republishing the bundle.
* Sends key transport acknowledgements.
* Records the identity key first seen for each device and refuses a changed
  one.
* Fetches everything first, then encrypts and writes without suspending, so
  two operations never interleave on one session.

Guarantees tested in `Tests/OMEMOCryptoTests`:

* XEdDSA signatures verify under libsodium's and CryptoKit's Ed25519.
* Out-of-order delivery across ratchet steps, with MAX_SKIP = 1000 per chain
  and 2000 stored keys.
* The same for OMEMO 2 sessions (`OMEMO2Tests`), whose MAC also binds the
  identities, and which never accept a pre-key message of the other version.
* Replays are refused.
* A forged or corrupt message leaves the session unchanged, because every
  operation runs on a copy.
* Simultaneous initiation works.
* Signed pre-key rotation works.
* Sessions survive `Codable` round trips.

## OMEMO 2

**One device, both versions.** This device has one id, one identity and one
pool of pre-keys. It publishes an OMEMO 0.3 bundle and an OMEMO 2 bundle and
puts itself in both device lists. The identity is an X25519 key. OMEMO 2
publishes it in its Ed25519 form (the Edwards point for u, sign bit 0), and
signs the signed pre-key with XEdDSA, which verifies as Ed25519 under that
form. Each signed pre-key carries two signatures: 0.3's over the 33-byte
serialized key, 2's over the bare 32 bytes. A device stored before OMEMO 2
gains the second when it is loaded. Using a pre-key in either version
removes it from both bundles.

**Which version for which device.** Each remote device is encrypted for in
one version:

1. One it already has a session in, 0.3 first.
2. Otherwise 0.3 if it is in the contact's 0.3 list, and 2 only if it is not.
3. If that bundle cannot be fetched, the other version, if listed.

Almost every device therefore stays on 0.3, which is proven against another
implementation and deployed everywhere. OMEMO 2 reaches the devices that
have nothing else.

**One stanza, both elements.** A message to a mix of devices carries an
`<encrypted/>` of each version, each with the keys of its own devices. The
fallback body and the XEP-0380 marker (0.3's namespace when present) are
shared. A device finds its key in one of them; a client that knows only one
namespace ignores the other. On receipt the engine tries each element that
has a key for this device, 0.3 first; one that fails commits nothing.

**The envelope.** OMEMO 2 encrypts an XEP-0420 `<envelope/>`: `<content/>`
with the body, 0–200 characters of `<rpad/>`, `<from/>` (our bare JID) and
`<to/>` (the contact, or the room). On receipt `from` must be the sender and
`to` one of the conversations the caller names: us or the contact in a chat
(a carbon of our own message names the contact), the room in a group. A
mismatch refuses the message (`envelopeMismatch`), as if it could not be
decrypted. Everything in `<content/>` replaces the elements of the same name
outside (`Message.decrypted(content:)`). Hrafn sends only the body inside,
as with 0.3.

**Differences from 0.3 in the ratchet.** X3DH's output is 32 bytes and is
the root key (Double Ratchet §3.3), not 64 split into root and chain. Labels
are "OMEMO X3DH", "OMEMO Root Chain" and "OMEMO Message Key Material". The
MAC is 16 bytes over X3DH's associated data (both identities in Ed25519
form, the initiator's first) and the `OMEMOMessage`. Keys are the bare 32
bytes, and there is no version byte. A one-time pre-key is required. The
key transport message is an empty message whose ratchet encrypts 32 zero
bytes.

**PEP.** The device list is `urn:xmpp:omemo:2:devices` (item `current`,
`<devices/>`). Every device's bundle is an item of one node,
`urn:xmpp:omemo:2:bundles`, with the device id as item id, published with
`pubsub#max_items` = `max` so devices do not evict each other (checked live
on both servers). OMEMO 0.3 is set up first: a server that refuses OMEMO 2's
nodes still gets 0.3.

**Trust.** One record per device, whichever version, with the key in its
X25519 form: python-omemo based clients use one identity for both, so their
0.3 and 2 keys are the same key and trust carries across.

**Storage.** Sessions and cached device lists are per version
(`OMEMODatabase` migration v3; rows from before are 0.3's).

**Tests.** `OMEMO2EngineTests` (both-version set-up, an OMEMO 2-only
conversation, mixed devices in one stanza, keeping an existing session, the
envelope checks, a server without OMEMO 2, the XML), `OMEMOInboundTests`
(`omemo2Contact`, `omemo2ReplayIntoAnotherChat`), `OMEMOStoreTests`
(versions, migration). Live: `LiveIntegrationTests` in both versions,
including two devices' bundles in one node, and
`OMEMOSessionIntegrationTests.omemo2OnlyContact`: the app and a bare client
with OMEMO 2 only, both ways, on Prosody and ejabberd.

## Interoperability assumptions

XEP-0384 0.3 does not restate the Signal message format, so the following
values come from the published version-3 format and not from the XEP:

* Version byte `0x33`.
* Protobuf field numbers.
* 8-byte truncated MAC over the sender identity, then the receiver identity,
  then the message.
* KDF labels `WhisperText`, `WhisperRatchet` and `WhisperMessageKeys`.
* X3DH's 64 bytes split into a root key and a chain key.
* The signed pre-key signature covering the 33-byte serialized key.

Round trips between two Hrafn devices cannot catch a mistake in any of these,
so `OracleInteropTests` checks them against another 0.3 implementation:

* Both sides initiate.
* Key transport.
* Several rounds of chain and DH ratchet steps.
* The other side's automatic messages.

All of the assumptions above held.

OMEMO 2 is specified by XEP-0384 0.8, but a few points could be read more
than one way. The oracle's twomemo backend confirmed our reading:

* The associated data is both identity keys in their Ed25519 form, the
  initiator's first.
* The empty (key transport) message encrypts 32 zero bytes.
* HKDF salts are 32 zero bytes. The X3DH output is 32 bytes and is the root
  key.
* Protobuf field numbers and the 16-byte MAC.

The oracle found one bug. Deployed 0.3 signers do not always force the
Edwards sign bit to 0 as XEdDSA does. Instead they send it in the top bit of
the signature's last byte, and about half of their signatures set it. Strict
XEdDSA verification rejected those bundles. `XEdDSA.verify` now accepts that
convention. Signing still produces the strict form, which both kinds of
verifier accept.

### Running the interop test

The oracle is python-omemo's `SessionManager` with the oldmemo and twomemo
backends, driven through its documented API. They are **AGPL-3.0**, so, per
docs/LICENSING.md:

* The oracle is used only as a black box.
* Its source is never read.
* Neither it nor the driver script is kept in this repository.

```sh
python3 -m venv omemo-venv && omemo-venv/bin/pip install "oldmemo[xml]" "twomemo[xml]"
HRAFN_OMEMO_ORACLE="omemo-venv/bin/python /path/to/oracle.py" \
  swift test --package-path Packages/OMEMOKit --filter OracleInteropTests
```

The driver speaks one JSON object per line. XML travels as strings; the
version of a list, bundle or message is its namespace.

| Request | Reply |
| --- | --- |
| `init {jid}` | `{device_id, devicelists: {namespace: xml}, bundles: {namespace: xml}}` |
| `put_devicelist {jid, xml}` | `{}` (and refreshes the list in the session manager) |
| `put_bundle {jid, device_id, xml}` | `{}` |
| `encrypt {to, plaintext, namespace}` | `{xml, errors}` |
| `decrypt {from, xml}` | `{plaintext, device_id}` |
| `sent` | `{messages: [{to, xml}]}` (its automatic messages) |

Any failure replies `{error}` instead. For OMEMO 2 the plaintext is the
envelope's XML both ways: the library leaves XEP-0420 to the client, so the
test builds and checks it.

Each test runs in both versions: the oracle is given our device in one
version's list only, and we get its device in that version only.

`LiveIntegrationTests` (`HRAFN_INTEGRATION=1`) runs OMEMO over the Docker
servers:

* Publishing and fetching without a subscription.
* An encrypted message on Prosody, on ejabberd, and federated between them,
  in each version.
* The used pre-key replaced in the published bundle.
* Our own device list notifications, in each version.
* Two devices' OMEMO 2 bundles side by side in one node.

Servers send the last published list when a client comes online with
`+notify`. The app must treat that as an ordinary update, and it may be old.

## Storage

What goes where:

* **Keychain.** The identity's private key, beside the account's password and
  FAST token (`CredentialStore.omemoIdentityKey`), stored
  `AfterFirstUnlockThisDeviceOnly`. It is removed with the account.
* **`OMEMODatabase`** (HrafnStore), in the App Group under `OMEMO/`. It holds
  everything else, as opaque blobs:
  * `LocalDevice.encodedWithoutIdentity()`.
  * The sessions.
  * The identity key first seen for each device.
  * Cached device lists.

  `DatabaseOMEMOStore` (HrafnServices) adapts it to OMEMOKit.

**Why a separate file, excluded from backups.** Ratchet state must never be
restored. A restored copy would have an older sending chain, and would
encrypt new messages with message keys it had already used. The exclusion is
on the directory, so SQLite's `-wal` and `-shm` files are covered too. After
a restore the file is simply gone, and the device starts over with a new
identity and a new device id. The old id stays in our PEP list until another
device or the user prunes it.

**A missing identity key.** The stored device is forgotten, with its
sessions, and a new one is made. The identities already seen are kept. A
keychain that cannot be read (before first unlock) throws instead, and
nothing is reset.

**Commits.** Each engine operation commits its changes once: the keychain
first, then one transaction. `OMEMOEngine.decrypt(_:from:persist:)` runs
`persist` (store the message there) before it commits the advanced session:

* If `persist` fails, nothing changes, and the message can be decrypted
  again.
* If the process dies between the two, the redelivered message decrypts
  again, and the message store deduplicates it.
* `encrypt` commits before it returns, so a message key is never used twice.

**The app and the extension.** Only one of them runs a session for an
account at a time (`AccountLock`). The engine reloads the device state for
every operation, because the other process may have used a pre-key in
between.

## In the app

**When a message is encrypted.** Each conversation has a setting, in the
chat's lock menu:

* **Automatic** (the default). A message is encrypted when the contact has
  OMEMO devices.
* **Encrypted.**
* **Not encrypted.**

The first encrypted message either side sends settles an automatic
conversation as encrypted, and it never falls back to plain text by itself.
The decision is made when the message is sent, including from the outbox:

* A device list that cannot be fetched keeps the message pending. It is never
  sent in the clear instead.
* A contact with no usable devices fails the message, with the reason shown.

**What is encrypted.** OMEMO 0.3 encrypts the body only, so these are
encrypted:

* Messages.
* Replies. The quote is part of the body.
* Corrections.

These still go in the clear, as with other 0.3 clients:

* Reactions.
* Retractions.
* Receipts, markers and chat states.
* Reply references.

**Files.** See "Files" below: encrypted with XEP-0454 in encrypted
conversations, never sent in the clear.

**Receiving.** `InboundStore` stores every one-to-one message: live, carbon,
archive, and in the notification extension. It decrypts first, and stores
inside `persist`, before the ratchet is committed.

* A message not encrypted for this device, or not decryptable, is stored as a
  placeholder (`encryption = undecryptable`), never as its fallback text.
* A decryptable copy that arrives later replaces the placeholder.
* An archive copy of a message already read matches the stored one and is
  dropped. Its keys are gone, so it cannot be decrypted again.
* A key transport message not meant for this device is ignored.

The app answers a device that started a session with a key transport
message. The extension does not answer, and the app does it next time. Each
message records how it travelled (`message.encryption`), and each
conversation its choice (`conversation.encryption`).

**Locking.** OMEMO runs in a session only while that session holds the
account's lock. If the app gives up waiting for the extension (30 seconds),
it connects without OMEMO rather than share the ratchets.

**Tests.**

* `OMEMOInboundTests`: decrypting, placeholders, replays, carbons, page
  order.
* `EncryptionStoreTests`.
* `OMEMOSessionIntegrationTests` (`HRAFN_INTEGRATION=1`): two apps over the
  Docker servers, alone and federated.
  * Automatic encryption.
  * A reply and a correction.
  * The extension decrypting from the archive while the app is suspended.
  * Resuming afterwards.
  * Turning encryption off.

**Device lists.** A cached list is used only after it was fetched or
pushed during the current session: changes are pushed only for contacts, so
anyone else's cached list could be arbitrarily old. When fetching fails, the
cache is used. A cached answer of no devices in either version is fetched
again before every use: fetched moments before the contact set OMEMO up
(when a room refreshes its members at login, say), it would otherwise fail
the message, or let an automatic conversation go out in the clear.

A device list notification without this device is not answered by
re-publishing *that* list plus us: servers resend the last list on login,
which may predate changes made since (devices removed). The current list is
fetched first, and we are added only if still missing.

**Our other devices** can be removed from the account's list (account screen,
"Remove from Account…"), for an uninstalled app or a restored phone that
others would go on encrypting for. This device is never removed, and a device
still in use adds itself back when it next connects.

**In the chat.** Each message shows how it travelled: a green shield for
OMEMO, an orange one from an untrusted device, a crossed-out one (and the
placeholder in italics) for a message that can't be decrypted here. The
same goes into its VoiceOver sentence.

**Share extension.** It decides encryption as the app does, with its own
engine under the account's lock. Without OMEMO storage it sends only to
conversations with encryption turned off; the rest waits for the app.

## Trust

The model is Blind Trust Before Verification (`Trust` in OMEMOKit):

| State | Meaning |
| --- | --- |
| `blind` | The device was trusted when it appeared, because the contact had no verified device yet. |
| `verified` | The user compared or scanned the fingerprint. |
| `undecided` | A new device of a contact who has a verified device, or any device whose key changed. |
| `untrusted` | The user said no. |

**Encrypting.** Messages are encrypted only for `blind` and `verified`
devices. A recipient whose devices are all undecided or untrusted fails the
message with `noTrustedDevices`, and the reason says to check the contact's
devices.

**Receiving.** Messages from the other two states are still read, and marked:

* `message.encryption = untrustedSender`.
* An orange shield on the message, and in its VoiceOver sentence.

A changed key no longer blocks anything. It replaces the old one as
`undecided`, until the user decides.

**Storage.** Trust is kept per device in `OMEMODatabase.identity.trust`.

* The engine writes an identity only when it is new or its key changed.
* The user's decisions go through `setTrust`, which names the key the user
  was shown. A screen showing an old key cannot approve a new one.

**Verifying.** Verification uses `xmpp:` URIs carrying
`omemo-sid-<device id>=<hex>` pairs, parsed and written by `XMPPURI`, as
other clients put in their QR codes.

* **Our code.** The account screen shows this device's fingerprint and a
  code. The code holds this device and our other devices we have verified.
* **Scanning.** The scanner is in the contact's Encryption section. It
  verifies the devices whose keys match what is stored. A mismatch verifies
  nothing, and says the code may be old or someone may be intercepting.
* **Links do not verify.** An `xmpp:` link opened from elsewhere never
  verifies. Otherwise anyone able to send a link could vouch for their own
  key.

**Screens.**

* **Contact details.** Their devices, with fingerprints, trust and actions:
  verify (with a confirmation), trust without verifying, don't trust.
* **Account screen.** This device's fingerprint and code, and our other
  devices.
* **Chat.** A banner when a contact has undecided devices.

**Tests.**

* `EngineTests`: Blind Trust Before Verification, key change.
* `OMEMOTrustTests`: scanning, mismatch, stale decisions, our own code.
* `OMEMOStoreTests.trustNamesTheKey`.
* `XMPPURITests.omemoFingerprints`.

**Not covered.** The screens are not exercised by the UI tests yet.

**OMEMO 2 fingerprints.** Fingerprints are shown, and `omemo-sid-` codes
written and checked, in the X25519 form, as 0.3 clients show them. A client
with OMEMO 2 only shows its devices' Ed25519 form, so comparing fingerprints
with such a contact by eye does not work yet, and its codes may use another
scheme. Showing the Ed25519 form for devices seen only in OMEMO 2 is left to
do.

## Phases

1. **Crypto core.** Done. See above.
2. **Protocol.** Done: the device list and bundles over PEP, `<encrypted/>`,
   key transport, the interop oracle and the live-server tests. Still manual:
   one conversation with a real 0.3 client (Conversations, Dino, Gajim or
   Monal) against the Docker servers, once the app can send (phase 4).
3. **Storage.** Done. See "Storage" above.
4. **Services.** Done. See "In the app" above.
5. **Trust.** Done. See "Trust" above.
6. **Group chats.** Done. See "Group chats" below.
7. **Files.** Done. See "Files" below.
8. **OMEMO 2.** Done. See "OMEMO 2" above. Still manual: a conversation with
   Kaidan, as with a 0.3 client in phase 2.

## Group chats

Only private groups (members only, real JIDs visible to all) can be
encrypted: OMEMO needs every member's real JID to find their devices.

**Members.** On joining a private group, the session reads the owner, admin
and member lists (members may read them in members-only rooms; what a server
refuses is covered by presence) and refreshes each member's device list. The
occupants' presence keeps the set current: members joining, 321 removals,
bans. Kept per session in `RoomRuntime.members`.

**When encrypted.** The room's lock menu (shown for private groups only) has
the same three choices as a chat. Automatic encrypts when every member has
devices. As in chats, the first encrypted message settles the room as
encrypted. Choosing "Encrypted" in a channel fails the message with a reason.

**Sending.** The body is encrypted for every device of every member and our
other devices, as a `groupchat` message. A member with no devices, or none
trusted, fails the message and names the member. XEP-0372 references are
left out of encrypted messages: they would say in the clear whom the message
is about. Corrections are encrypted; retractions, reactions and moderation go
in the clear, as in chats.

**Receiving.** The sender's real JID is worked out, in order, from: us
(occupant id, JID or nick), the occupant id's JID from presence, the
archive's `<item jid=''/>`, the sender device id among the members' cached
devices, and last the nick's current holder. A wrong guess only fails
decryption. Live and archive messages go through
`InboundStore.store(room:sender:me:)`, stored before the ratchet is
committed, as in chats. Our own reflection is not encrypted for this device:
its placeholder merges into the row already stored, marking it delivered.
Pre-key messages are answered with a key transport message to the sender's
bare JID.

**Trust.** Member devices follow the same Blind Trust Before Verification.
The participants' context menu in the group's details has "Encryption
Devices" for each member.

## Files

XEP-0454 (`FileEncryption`):

* **Sending.** In an encrypted conversation (chat or group), the file is
  encrypted with AES-256-GCM under a fresh key and a 12-byte IV, and the
  ciphertext plus tag is uploaded as `application/octet-stream` under a random
  name that keeps only the extension. The message body is the
  `aesgcm://host/path#<iv><key>` link alone, encrypted with OMEMO. No OOB,
  XEP-0447 metadata, digest or thumbnail: those would go in the clear.
* **Switching.** A file uploaded plain is uploaded again, encrypted, if the
  conversation became encrypted before it was sent, and the other way round.
* **Receiving.** A body that is exactly one `aesgcm://` link becomes an
  attachment with the key kept on it (`Attachment.encryptionKey`). IVs of 12
  or 16 bytes are accepted. The download is decrypted before it is stored; a
  bad tag fails it (`TransferError.decryptionFailed`).

**Tests.** `FileEncryptionTests` (round trip, tampering, 16-byte IV, links),
and `OMEMOSessionIntegrationTests`: `encryptedGroup` and `encryptedFiles`
(chat and group, the server holding ciphertext) on Prosody and ejabberd. The
suite uses its own accounts (montague, capulet).

Before release, update `ITSAppUsesNonExemptEncryption` and the export
classification (`docs/APP-STORE.md`).
