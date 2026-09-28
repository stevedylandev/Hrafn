# App Store submission notes

## Privacy manifest

Each bundle ships a `PrivacyInfo.xcprivacy`: `Hrafn/`, `HrafnNotificationService/` and `HrafnShare/`. GRDB brings its own manifest.

| Entry | Why |
| --- | --- |
| Tracking: no, no tracking domains | Hrafn does no tracking. |
| Collected data: none | See "Privacy labels" below. |
| File timestamp, `C617.1` | `MediaStore` reads file attributes (the size) through `attributesOfItem`, for files in the app group container. Apple lists that API under file timestamps. |
| User defaults, `1C8F.1` (app only) | The media download policy, kept in the app group's defaults so the extensions can read it. |

Look at these again whenever a required-reason API is added, for example disk space or boot time.

## Privacy labels

The answer is **"Data Not Collected"**. Apple counts data as "collected" when it leaves the device in a form the developer or its partners can access beyond what is needed to service a request in real time.

* Messages, contacts, files and profiles go to the XMPP server **the user chose**, which the developer does not run. They stay on the device in the app group container.
* **Push:** the developer's app server (fpush) receives the APNs token and the XEP-0357 node. It forwards a content-free wake-up and keeps nothing else. This is there to deliver the service, not to be collected.
* No analytics, no crash reporter beyond Apple's own, no advertising.

If the developer ever operates a default XMPP server for new users (open question 3 in PLAN.md), these answers change for accounts on it: at least contact info, user content and identifiers, linked to the user and not used for tracking.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in `Config/Hrafn-Info.plist`. v1 uses only the operating system's TLS (Network.framework, URLSession), plus HMAC and SHA hashes for SCRAM authentication. Both fall under the exemption for authentication and for encryption provided by the OS. **OMEMO (v2)** adds end-to-end encryption in the app. At that point, re-check the classification (probably still mass-market 5A992, with a self-classification report) and update the key.

**Now pressing:** the `omemo` branch builds OMEMO into the app (AES-256-CBC, AES-128-GCM, X25519/XEdDSA, including libsodium). The key must be settled before any build from that branch goes to TestFlight. That decision is the developer's to make.

## Before TestFlight

* Filtering entitlement (`com.apple.developer.usernotifications.filtering`). It is still not applied for (Phase 0 carry-over).
* Production push: fpush with the production APNs certificate at `push.hrafn.stevedylandev.dev` (`AppConfig.push`).
* Caps node URL (`hrafnIdentity`) and the DOAP file (`hrafn.doap`) point at the project's real home page.
* In-app account deletion is not required: Hrafn does not create accounts (sign-up comes in v2, and so does deletion).
