# Licence policy

Hrafn implements XMPP from the specifications. The protocol code is original
work, and it must stay that way: most mature XMPP clients are GPL or AGPL, and
copying or closely porting from them would force Hrafn to adopt their licence.

## Clean-room rules

1. **Sources of truth are specifications and captures.** RFCs, XEPs, the
   `docs.modernxmpp.org` UX conventions, and packet captures taken from our own
   test servers (`docker/`).
2. **Do not read copyleft client source while implementing the same feature.**
   Notably Conversations, Siskin, Monal's GPL parts, Dino, Gajim, Profanity and
   libsignal. Consulting them to *diagnose a server's behaviour* is fine;
   consulting them for *how to write the feature* is not.
3. **Permissive code may be used with attribution.** MIT, BSD-2/3, Apache-2.0,
   ISC, zlib. Record the source and licence in a comment at the point of use and
   add the package to the allowlist in `scripts/license-audit.sh`.
4. **Every dependency is audited in CI.** `scripts/license-audit.sh` fails the
   build for an unapproved package, for copyleft licence text anywhere in the
   tree, and flags copyleft client names appearing in source files.
5. **Copyleft software may be run as a black box in tests**, through its
   documented interface, without reading its source. It is never vendored or
   committed, and neither is glue code that imports it. The OMEMO interop
   oracle (python-omemo with oldmemo and twomemo, AGPL-3.0, see docs/OMEMO.md)
   works this way.
6. **Write down where a non-obvious behaviour came from.** A comment citing
   "RFC 6120 §5.4.3.3" is the evidence that the behaviour was derived from the
   spec rather than from someone else's code.

## Dependencies

XMPPKit currently has **no external dependencies**. It uses:

| Component | Licence | Notes |
| --- | --- | --- |
| libxml2 | MIT | Ships in the Apple SDKs; used through `Sources/CLibXML2`. |
| Network.framework, Security, CryptoKit, Foundation | Apple SDK | Platform. |
| dns_sd (`DNSServiceQueryRecord`) | Apple SDK | SRV lookups. |

HrafnKit (persistence and services, `Packages/HrafnKit`) depends on:

| Component | Licence | Notes |
| --- | --- | --- |
| GRDB.swift | MIT | SQLite access and observation; the app database. |

OMEMOKit (end-to-end encryption, `Packages/OMEMOKit`) depends on:

| Component | Licence | Notes |
| --- | --- | --- |
| swift-sodium (`Clibsodium` only) | ISC | libsodium 1.0.22 as a prebuilt xcframework; the Edwards-curve operations for XEdDSA. The Swift wrapper is not used. |

Pre-approved if needed later: swift-nio and swift-nio-transport-services
(Apache-2.0). The licence audit checks every `Package.resolved` (both packages
and the app's) and fails if XMPPKit gains any dependency at all.

Explicitly rejected: **libsignal** (AGPL). OMEMO is implemented in OMEMOKit
from the X3DH, Double Ratchet and XEdDSA specifications, on CryptoKit,
CommonCrypto and libsodium.

## Hrafn's own licence

Still open (PLAN.md §6, question 1). Nothing in the tree depends on the answer:
the clean-room policy keeps every option available, including a closed-source
release.
