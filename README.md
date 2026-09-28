# Hrafn

An XMPP client for iOS, with the protocol implemented from the specifications.

* **Setup:** [docs/SETUP.md](docs/SETUP.md)
* **Licence policy:** [docs/LICENSING.md](docs/LICENSING.md) — clean-room, permissive dependencies only
* **OMEMO:** [docs/OMEMO.md](docs/OMEMO.md) — end-to-end encryption, v2, phases 1–5 of 8 done

## Current state

Hrafn is a federated text client with push, group chats, file sharing (HTTP
upload, voice messages, share extension), avatars and nicknames, reactions,
replies, message styling and read positions synced across devices, on a
protocol stack written from the specifications.

Phases 0–8 are in, and Phase 9 (hardening and release) is under way (see
[PHASE-STATUS](docs/PHASE-STATUS.md), [SECURITY-REVIEW](docs/SECURITY-REVIEW.md),
[APP-STORE](docs/APP-STORE.md)). v2's OMEMO end-to-end encryption is in
progress on the `omemo` branch: one-to-one chats are encrypted by default, with
trust and verification ([OMEMO](docs/OMEMO.md)).

```sh
swift test --package-path Packages/XMPPKit      # protocol
swift test --package-path Packages/HrafnKit     # store and services
swift test --package-path Packages/OMEMOKit     # end-to-end encryption
docker compose -f docker/docker-compose.yml up -d && ./scripts/dev-accounts.sh
HRAFN_INTEGRATION=1 swift test --package-path Packages/XMPPKit   # + live servers
HRAFN_INTEGRATION=1 swift test --package-path Packages/HrafnKit
```
