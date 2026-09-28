# Test servers

Two servers on two domains, so federation and implementation differences show up
during development: **Prosody** on `alpha.test` and **ejabberd** on `beta.test`.

## Start

```sh
./scripts/gen-certs.sh          # local CA + certificates (once)
docker compose -f docker/docker-compose.yml up -d
./scripts/dev-accounts.sh       # juliet, romeo and each test suite's own users, on both domains
```

Add the domains to your hosts file so the device or simulator can reach them
(optional for the simulator: debug builds send file transfers for `.test`
hosts to 127.0.0.1 by themselves, and the tests do the same):

```
127.0.0.1  alpha.test conference.alpha.test upload.alpha.test
127.0.0.1  beta.test  conference.beta.test  upload.beta.test
```

## Ports

| Purpose | alpha.test (Prosody) | beta.test (ejabberd) |
| --- | --- | --- |
| c2s STARTTLS | 5222 | 15222 |
| c2s Direct TLS (XEP-0368) | 5223 | 15223 |
| s2s | 5269 | 15269 |
| HTTP upload (XEP-0363, HTTPS) | 5281 (`upload.alpha.test`) | 5443 (`upload.beta.test`) |
| XEP-0114 components (push app server) | 5347 (`push.alpha.test`) | 15347 (`push.beta.test`) |

The upload services' URLs name the same ports on the host as in the
containers, so clients on the development machine can use them as they are.
Both route HTTP by the `Host` header.

The component secret is `pushsecret` on both. The push tests connect a
stand-in there; `docker/fpush` is the real app server.

## Certificates

`scripts/gen-certs.sh` issues from a local CA and includes an `id-on-xmppAddr`
SAN alongside the DNS-IDs, so certificate-identity handling gets exercised
(RFC 6120 §13.7.1.2). The CA is not in any system trust store — debug builds
accept it through the trust-exception store, which is also how the pinning UI
gets tested.

## Images

Prosody is **built locally** (`prosody/Dockerfile`) from Prosody's apt
repository: the `prosody/prosody` images on Docker Hub stopped at 0.11 (2021),
before `mod_http_file_share` and core stream management. The build also installs
`prosody-modules`, which supplies `mod_cloud_notify` for XEP-0357 in Phase 5 —
already enabled in the config.

ejabberd comes from `ghcr.io/processone/ejabberd`, not Docker Hub's
`ejabberd/ecs`: the Hub image publishes amd64 only, and under emulation its
fast_tls NIF fails to load, so every accepted connection dies with
`bad return value: :nif_not_loaded`.

## SASL mechanisms

| Server | Offers |
| --- | --- |
| Prosody 13.0.7 | SCRAM-SHA-1, SCRAM-SHA-1-PLUS, PLAIN, OAUTHBEARER |
| ejabberd 26.7 | SCRAM-SHA-256(-PLUS), SCRAM-SHA-1(-PLUS), PLAIN, X-OAUTH2 |

Prosody implements SCRAM-SHA-1 only, so ejabberd (`auth_scram_hash: sha256`) is
what proves the SCRAM-SHA-256 that v1 requires. Changing `auth_scram_hash`
invalidates stored hashes — recreate the volume and re-register:

```sh
docker rm -f hrafn-ejabberd && docker volume rm docker_ejabberd-data
docker compose -f docker/docker-compose.yml up -d ejabberd && ./scripts/dev-accounts.sh
```

Both servers advertise XEP-0440 channel binding with `tls-exporter`, which the
Direct TLS transport can already produce.

## Known gaps

* Federation relies on fixed container addresses and `extra_hosts` rather than
  SRV records. Network aliases alone are not enough: Prosody resolves with
  libunbound, whose built-in RFC 6761 zone answers every `.test` name with
  NXDOMAIN, so `prosody.cfg.lua` feeds it `/etc/hosts` instead. To test SRV
  resolution itself, point a real resolver at a zone with `_xmpps-client._tcp`
  and `_xmpp-client._tcp` records.
* s2s authenticates with dialback. ejabberd 26.07 crashes (`badarg`) handling
  Prosody's SASL EXTERNAL when it can verify the certificate, so it is not
  given the test CA (`ca_file`), and `mod_s2s_dialback` is enabled.
* Changing the network in `docker-compose.yml` needs the containers recreated:
  `docker compose -f docker/docker-compose.yml up -d` (volumes are kept).
