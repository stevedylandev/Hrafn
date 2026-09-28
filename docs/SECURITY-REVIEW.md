# Security review (Phase 9)

Scope: the code that handles bytes from the network before anything else
does: the XML parser and serializer, TLS and certificate identity, SASL, and
the addresses (JID, `xmpp:` URIs) that come from untrusted sources. This was
a read-through of the code against the specifications, backed by new tests.
No outside auditor has seen it.

## Fixed

| # | Area | Finding | Fix |
| --- | --- | --- | --- |
| 1 | Parser | **`&` in attribute values came back as `&#38;`.** libxml2 does not substitute entities in this setup, so it returns an escaped `&` in an attribute as a character reference. Any attribute with an ampersand was corrupted, including an HTTP upload slot URL with more than one query parameter (the PUT would go to the wrong URL) and bookmark names. The randomized round-trip test found it. | The reference is decoded at the byte level. A version that worked on `String` missed matches followed by a combining mark, because the `;` and the mark form one grapheme. The fuzzer found that too. |
| 2 | Serializer | **XML-illegal characters were sent as they were.** A U+0001 or U+FFFF pasted into a message produced XML the server rejects with a stream error. XEP-0198 then replays the stanza after the reconnect, so the account would loop through reconnects indefinitely. | Characters outside XML 1.0 `Char` are dropped from text and attribute values. |
| 3 | Serializer | Prefixed attributes other than `xml:` (for example `ext:hint`) were stored without their namespace declaration, so serializing them again produced XML that is not well formed. This matters because bookmark `<extensions/>` are republished verbatim. | The parser keeps an `xmlns:prefix` attribute next to any attribute that uses the prefix. |
| 4 | Parser | **Memory.** The 1 MiB stanza cap still allowed about 240,000 empty elements, which measured at 16 MB of tree. The notification extension has about 24 MB in total. | `maxElements` (65,536 per stanza, about 4 MB). |
| 5 | TLS | **The STARTTLS path had no TLS version floor.** `URLSessionStreamTask` used URLSession's default floor instead of the policy's TLS 1.2 (RFC 7590 §3.3). | `tlsMinimumSupportedProtocolVersion` is set from the policy. |
| 6 | TLS | **IDN domains were sent as U-labels** in SNI and in the hostname given to `SecPolicyCreateSSL`. SNI is ASCII only (RFC 6066 §3), and certificates carry A-labels. | Both now use the Punycode A-label. |
| 7 | TLS | Certificate identity only checked the DNS-ID (a Phase 1 carry-over). A server whose certificate names the domain only by SRV-ID or `id-on-xmppAddr` required a manual exception. | `CertificateIdentity` reads the subjectAltName with a minimal DER reader written from X.690. If the system trusts the chain and the leaf names the domain as `_xmpp-client.<domain>` / `_xmpps-client.<domain>` or as an xmppAddr, the certificate is accepted. The chain, validity dates and key usage are still checked by the system. |

## Checked, no change

* **DTDs and entities.** `<!DOCTYPE` stops the parser in the SAX callback,
  before any declaration is read. Entity substitution is off and network
  access is off (`XML_PARSE_NONET`). Processing instructions end the stream.
  Existing tests cover the billion-laughs payload and undeclared entities.
* **Limits.** Depth (64), children per element (8,192) and bytes per stanza
  (1 MiB) are each checked separately. Transport reads are at most 64 KiB,
  so the byte count can undercount a stanza by at most one read.
* **SCRAM.** The server signature is compared in constant time. A
  `<success/>` without the signature is refused with `<abort/>`. The client
  nonce comes from `SystemRandomNumberGenerator`. The server nonce must
  extend ours. `m=` is refused. The iteration count must be between 4,096
  and 1,000,000. The GS2 `y`/`n` flag is chosen so a stripped `-PLUS` offer
  is detected. PLAIN is used only over TLS and only as a last resort.
* **Downgrades.** STARTTLS is required. A `<failure/>` or a missing offer
  ends the attempt and never falls back to plaintext. The stream `from` is
  only sent once the stream is encrypted.
* **Trust exceptions.** Exceptions are stored per domain and per leaf
  SHA-256 fingerprint, and only after the user agrees. HTTP transfers accept
  the same pinned fingerprint and nothing broader. The loopback trust bypass
  (for the Docker servers) is compiled into debug builds only.
* **Credentials.** Passwords are stored in the keychain as
  `AfterFirstUnlockThisDeviceOnly` in the shared access group, which the
  notification extension needs. The XML console redacts SASL payloads.
* **Spoofing.** Checks on sender addresses were reviewed in earlier phases
  and are unchanged: IQ replies against the addressee, roster, blocking and
  PEP pushes from our own account, carbons from our own bare JID, archive
  results against the archive, and `stanza-id` only when `by` is us.

## Fuzzing

Every randomized test takes `HRAFN_FUZZ_SCALE` (a multiplier) and prints
its seed. `HRAFN_FUZZ_SEED` reruns the same inputs. Pull requests run them
at base counts. The nightly CI job (`fuzz`) runs them at 200 times those
counts in release mode.

| Target | Test | Checks |
| --- | --- | --- |
| Stream parser | `survivesRandomAndMutatedInput` | random and mutated bytes, fed in random slices: no trap, no hang |
| Serializer → parser | `serializedRandomTextAlwaysParsesBack` | any string, including control characters, markup and astral characters, parses back to itself minus the characters XML cannot carry |
| SCRAM | `fuzzedServerMessagesNeverCrash` | random server-first and server-final messages |
| JID / PRECIS | `parsedAddressesAreFixedPoints` | any address that parses prints as one that parses back to itself |
| Punycode | `punycodeDecodingNeverTraps` | random ACE labels, and re-encoding is stable |
| `xmpp:` URIs | `arbitraryLinksNeverTrap` | round trip through `description` |
| Certificate DER | `truncatedAndMutatedCertificatesNeverTrap` | truncated, mutated and random certificates |
| Message styling | `survivesArbitraryInput` | random directive soup |

## OMEMO (v2, branch `omemo`)

Written from the X3DH, Double Ratchet and XEdDSA specifications. Details are
in [OMEMO.md](OMEMO.md).

* **Secrets.**
  * The identity private key is in the keychain
    (`AfterFirstUnlockThisDeviceOnly`).
  * Pre-keys, sessions and message keys are in `OMEMO/OMEMO.sqlite`, excluded
    from backups, so an older ratchet can never be restored and reused.
  * `Field25519` does variable-time arithmetic, on public keys only.
  * XEdDSA signing zeroes its scalars.
* **Failure handling.**
  * Decryption works on a copy of the session and commits only after the
    message is stored. A forged, replayed or corrupt message changes nothing.
  * `encrypt` commits before the message is sent, so a message key is never
    used twice.
* **No silent downgrades.**
  * An encrypted conversation never sends plain text by itself.
  * A device list that cannot be fetched keeps the message pending.
  * Files are refused until XEP-0454.
* **Trust.**
  * The model is Blind Trust Before Verification.
  * A changed key is never trusted without the user.
  * A trust decision names the key it was made for.
  * Opened links never verify.
* **Two processes.** OMEMO runs only under the account lock.

Open for OMEMO:

* An external review of `OMEMOCrypto` (XEdDSA, ratchet, wire format) before
  release.
* Reactions, retractions, receipts and reply references go in the clear, as
  OMEMO 0.3 only encrypts the body.

## Open

* **SCRAM cost.** PBKDF2 goes through CryptoKit's HMAC one iteration at a
  time: 12 ms at 4,096 iterations and 2.6 s at the 1,000,000 ceiling (Mac,
  release build). CommonCrypto's `CCKeyDerivationPBKDF` would be faster, and
  caching the salted password would avoid the work on repeat logins. Worth
  doing if a real server uses high iteration counts, especially in the
  notification extension.
* **Hostnames in SRV-IDs** are compared as A-labels. An xmppAddr written as
  a U-label is converted with our Punycode, which has no IDNA2008 mapping
  step. Matching is exact after lowercasing ASCII.
* **Certificate Transparency and revocation** are left to the system
  defaults.
* **External review.** Get a second pair of eyes on `StreamParser`,
  `SCRAMMechanism`, `TLSPolicy`/`CertificateIdentity` and the notification
  extension's lock handling before a public release.
