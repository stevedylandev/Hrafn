# Hrafn

![cover](https://hrafn.app/og.png)

An XMPP client for iOS, with the protocol implemented from the specifications.

* **Setup:** [docs/SETUP.md](docs/SETUP.md)
* **Licence policy:** [docs/LICENSING.md](docs/LICENSING.md) — clean-room, permissive dependencies only

## Current state

Hrafn is a federated text client with push, group chats, file sharing (HTTP
upload, voice messages, share extension), avatars and nicknames, reactions,
replies, message styling and read positions synced across devices, on a
protocol stack written from the specifications.

```sh
swift test --package-path Packages/XMPPKit      # protocol
swift test --package-path Packages/HrafnKit     # store and services
swift test --package-path Packages/OMEMOKit     # end-to-end encryption
docker compose -f docker/docker-compose.yml up -d && ./scripts/dev-accounts.sh
HRAFN_INTEGRATION=1 swift test --package-path Packages/XMPPKit   # + live servers
HRAFN_INTEGRATION=1 swift test --package-path Packages/HrafnKit
```

## Implemented XEPs

Machine-readable in [hrafn.doap](hrafn.doap); details and caveats in
[PHASE-STATUS](docs/PHASE-STATUS.md).

| XEP | Name | Notes |
| --- | --- | --- |
| [0004](https://xmpp.org/extensions/xep-0004.html) | Data Forms | Partial: the subset rooms and publish-options need |
| [0030](https://xmpp.org/extensions/xep-0030.html) | Service Discovery | |
| [0045](https://xmpp.org/extensions/xep-0045.html) | Multi-User Chat | Including private messages through a room |
| [0048](https://xmpp.org/extensions/xep-0048.html) | Bookmarks | Read only, when Bookmarks 2 is empty |
| [0054](https://xmpp.org/extensions/xep-0054.html) | vcard-temp | Partial: avatars |
| [0059](https://xmpp.org/extensions/xep-0059.html) | Result Set Management | |
| [0060](https://xmpp.org/extensions/xep-0060.html) | Publish-Subscribe | Partial: publish, retrieve, retract, notifications, publish-options |
| [0066](https://xmpp.org/extensions/xep-0066.html) | Out of Band Data | Partial: URLs in messages |
| [0084](https://xmpp.org/extensions/xep-0084.html) | User Avatar | |
| [0085](https://xmpp.org/extensions/xep-0085.html) | Chat State Notifications | |
| [0115](https://xmpp.org/extensions/xep-0115.html) | Entity Capabilities | |
| [0128](https://xmpp.org/extensions/xep-0128.html) | Service Discovery Extensions | |
| [0147](https://xmpp.org/extensions/xep-0147.html) | XMPP URI Query Components | |
| [0153](https://xmpp.org/extensions/xep-0153.html) | vCard-Based Avatars | |
| [0163](https://xmpp.org/extensions/xep-0163.html) | Personal Eventing Protocol | |
| [0172](https://xmpp.org/extensions/xep-0172.html) | User Nickname | |
| [0184](https://xmpp.org/extensions/xep-0184.html) | Message Delivery Receipts | |
| [0191](https://xmpp.org/extensions/xep-0191.html) | Blocking Command | |
| [0198](https://xmpp.org/extensions/xep-0198.html) | Stream Management | |
| [0199](https://xmpp.org/extensions/xep-0199.html) | XMPP Ping | |
| [0203](https://xmpp.org/extensions/xep-0203.html) | Delayed Delivery | |
| [0249](https://xmpp.org/extensions/xep-0249.html) | Direct MUC Invitations | |
| [0264](https://xmpp.org/extensions/xep-0264.html) | Jingle Content Thumbnails | Thumbnails for shared files |
| [0280](https://xmpp.org/extensions/xep-0280.html) | Message Carbons | |
| [0297](https://xmpp.org/extensions/xep-0297.html) | Stanza Forwarding | |
| [0300](https://xmpp.org/extensions/xep-0300.html) | Use of Cryptographic Hash Functions | SHA-256 of shared files |
| [0308](https://xmpp.org/extensions/xep-0308.html) | Last Message Correction | |
| [0313](https://xmpp.org/extensions/xep-0313.html) | Message Archive Management | |
| [0333](https://xmpp.org/extensions/xep-0333.html) | Displayed Markers | |
| [0334](https://xmpp.org/extensions/xep-0334.html) | Message Processing Hints | |
| [0352](https://xmpp.org/extensions/xep-0352.html) | Client State Indication | |
| [0357](https://xmpp.org/extensions/xep-0357.html) | Push Notifications | |
| [0359](https://xmpp.org/extensions/xep-0359.html) | Unique and Stable Stanza IDs | |
| [0363](https://xmpp.org/extensions/xep-0363.html) | HTTP File Upload | |
| [0368](https://xmpp.org/extensions/xep-0368.html) | SRV records for XMPP over TLS | |
| [0372](https://xmpp.org/extensions/xep-0372.html) | References | Mentions |
| [0380](https://xmpp.org/extensions/xep-0380.html) | Explicit Message Encryption | Partial: with OMEMO messages |
| [0384](https://xmpp.org/extensions/xep-0384.html) | OMEMO Encryption | Partial: 0.3 and OMEMO 2; see [OMEMO](docs/OMEMO.md) |
| [0386](https://xmpp.org/extensions/xep-0386.html) | Bind 2 | |
| [0388](https://xmpp.org/extensions/xep-0388.html) | Extensible SASL Profile (SASL2) | |
| [0392](https://xmpp.org/extensions/xep-0392.html) | Consistent Color Generation | |
| [0393](https://xmpp.org/extensions/xep-0393.html) | Message Styling | |
| [0398](https://xmpp.org/extensions/xep-0398.html) | User Avatar to vCard-Based Avatars Conversion | Partial: relies on the server's conversion |
| [0402](https://xmpp.org/extensions/xep-0402.html) | PEP Native Bookmarks | |
| [0410](https://xmpp.org/extensions/xep-0410.html) | MUC Self-Ping | |
| [0420](https://xmpp.org/extensions/xep-0420.html) | Stanza Content Encryption | Partial: OMEMO 2's profile |
| [0421](https://xmpp.org/extensions/xep-0421.html) | Occupant Identifiers | |
| [0424](https://xmpp.org/extensions/xep-0424.html) | Message Retraction | |
| [0425](https://xmpp.org/extensions/xep-0425.html) | Moderated Message Retraction | |
| [0426](https://xmpp.org/extensions/xep-0426.html) | Character Counting in Message Bodies | |
| [0428](https://xmpp.org/extensions/xep-0428.html) | Fallback Indication | |
| [0440](https://xmpp.org/extensions/xep-0440.html) | SASL Channel-Binding Type Capability | |
| [0444](https://xmpp.org/extensions/xep-0444.html) | Message Reactions | |
| [0446](https://xmpp.org/extensions/xep-0446.html) | File Metadata Element | |
| [0447](https://xmpp.org/extensions/xep-0447.html) | Stateless File Sharing | |
| [0454](https://xmpp.org/extensions/xep-0454.html) | OMEMO Media Sharing | |
| [0461](https://xmpp.org/extensions/xep-0461.html) | Message Replies | |
| [0484](https://xmpp.org/extensions/xep-0484.html) | Fast Authentication Streamlining Tokens | |
| [0490](https://xmpp.org/extensions/xep-0490.html) | Message Displayed Synchronization | |
