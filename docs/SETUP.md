# Setup

## Repository layout

```
Hrafn.xcodeproj          iOS app (Swift 6 language mode, iOS 17+)
Hrafn/                   SwiftUI app: App/ (model, routing, app delegate), Views/,
                         Debug/ (XML console, stream probe)
HrafnNotificationService/ notification service extension (fetch on push)
HrafnShare/              share extension (store what was shared, send it with a one-shot login)
Config/                  Info.plists and entitlements (App Group, keychain group, APNs)
Packages/XMPPKit/        the protocol implementation (no UIKit/SwiftUI, no dependencies)
  Sources/CLibXML2       module map over the SDK's libxml2
  Sources/XMPPXML        Element tree, serializer, push parser, framing, console
  Sources/XMPPCore       JID, PRECIS, Punycode, stanzas, stanza errors
  Sources/XMPPTransport  SRV, endpoints, TLS policy, transports, XMLStream
  Sources/XMPPStream     SASL, session negotiation, binding, SM resumption
  Sources/XMPPClient     the per-account actor: IQ tracker, router, SM, CSI, reconnect
  Sources/XMPPIM         roster, presence, messages + extensions, carbons, MAM, blocking, xmpp: URIs,
                         MUC, bookmarks, push, HTTP upload, avatars, nicknames, XEP-0392 colours
Packages/OMEMOKit/       end-to-end encryption (depends on XMPPKit, swift-sodium's Clibsodium)
  Sources/OMEMOCrypto    XEdDSA, X3DH, Double Ratchet, OMEMO 0.3 wire format and payloads
  Sources/OMEMOProtocol  XEP-0384 XML, PEP directory, trust, OMEMOEngine
Packages/HrafnKit/       what the app and its extensions share (depends on XMPPKit, OMEMOKit, GRDB)
  Sources/HrafnStore     GRDB database: accounts, roster, messages, rooms, attachments, profiles,
                         dedup/ingest, observation; OMEMODatabase (keys, sessions, trust)
  Sources/HrafnServices  AccountManager, AccountSession (events -> database), keychain, media store,
                         HTTP transfers, background fetch, share delivery, OMEMO storage and trust
docker/                  Prosody + ejabberd test servers
scripts/                 certificates, dev accounts, licence audit, server checks
docs/                    licensing policy, transport spike, phase status, OMEMO
```

## Build and test

```sh
swift test --package-path Packages/XMPPKit          # protocol unit tests
swift test --package-path Packages/HrafnKit         # store and services
swift test --package-path Packages/OMEMOKit         # end-to-end encryption
xcodebuild build -project Hrafn.xcodeproj -scheme Hrafn \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
./scripts/license-audit.sh
```

Integration tests need the Docker servers (see `docker/README.md`):

```sh
docker compose -f docker/docker-compose.yml up -d && ./scripts/dev-accounts.sh
HRAFN_INTEGRATION=1 swift test --package-path Packages/XMPPKit
HRAFN_INTEGRATION=1 swift test --package-path Packages/HrafnKit
HRAFN_INTEGRATION=1 swift test --package-path Packages/OMEMOKit
```

OMEMO interop with another 0.3 implementation runs when `HRAFN_OMEMO_ORACLE`
names an oracle command; see [OMEMO.md](OMEMO.md#running-the-interop-test).

`HRAFN_XML=1` prints the (redacted) XML of every live session.

The app's UI test signs in to the Docker Prosody and chats with romeo, played
by an echo bot:

```sh
HRAFN_ECHO_BOT=1 swift test --package-path Packages/HrafnKit --filter EchoBot &
TEST_RUNNER_HRAFN_INTEGRATION=1 xcodebuild test -project Hrafn.xcodeproj -scheme Hrafn \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HrafnUITests/HrafnUITests
```

## Trying the app against the Docker servers

Sign in as `juliet@alpha.test` / `devpassword`, and under *Connection settings*
set host `127.0.0.1`, port `5223` (or `15223` with `@beta.test`). The test CA is
private, so the app shows the certificate's fingerprint and asks before
trusting it — the same flow a user of a self-signed server sees.

## Still to configure by hand

1. **Notification filtering entitlement** — apply
   (`com.apple.developer.usernotifications.filtering`), then add it to
   `Config/HrafnNotificationService.entitlements` and set
   `HrafnCanFilterNotifications` in `Config/HrafnNotificationService-Info.plist`.
2. **APNs certificate** for fpush (`docker/fpush/README.md`), and the release
   push service in `AppConfig.push`.

The App Group (`group.dev.stevedylandev.hrafn`), keychain sharing group and
Push Notifications entitlements are in `Config/*.entitlements`. Automatic
signing registers them on the first device build.

## Files in the simulator

Debug builds send HTTP for `.test` hosts to 127.0.0.1 with the real `Host`
header (`HTTPTransfer`'s loopback mode), so uploads and downloads work against
the Docker servers without editing `/etc/hosts`. Release builds never do.
Voice messages need the Mac's microphone: macOS asks once whether Simulator
may use it (`testSendVoiceMessage` runs only with
`TEST_RUNNER_HRAFN_MICROPHONE=1`).

## Push in the simulator

The simulator gets a real APNs token, and the app registers it with the
server. `xcrun simctl push` shows a banner but never starts the notification
service extension, so the extension can only be tested on a device with fpush
running. `HrafnPushUITests` covers everything short of that — see the file
for how to run it with `PushSender`.

## Local hostnames

Add to `/etc/hosts` so the simulator and devices on the same network can reach
the test servers by the names on their certificates:

```
127.0.0.1  alpha.test conference.alpha.test upload.alpha.test
127.0.0.1  beta.test  conference.beta.test  upload.beta.test
```
