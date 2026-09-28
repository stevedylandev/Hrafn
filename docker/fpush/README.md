# fpush — Hrafn's push app server

[fpush](https://github.com/monal-im/fpush) (MIT) is the XEP-0357 app server:
an XEP-0114 component that receives the user's server's publish and sends an
APNs push. Hrafn registers with `node` = the APNs device token (hex) and a
`pushModule` publish option naming the fpush module (`sandbox` for debug
builds, `production` for release — see `AppConfig.push`).

fpush sends a fixed alert ("New Message") with `mutable-content`, and carries
no message content; the notification service extension logs in and fetches
the real message.

## Run against the Docker Prosody

fpush authenticates to APNs with a **certificate (.p12)**, not a `.p8` key.
Create an "Apple Push Notification service SSL (Sandbox & Production)"
certificate for `com.stevedylandev.Hrafn` in the developer portal, export it
as .p12, then:

```sh
cp docker/fpush/settings.example.json docker/fpush/settings.json   # set certPassword
cp ~/Downloads/hrafn-push.p12 docker/fpush/apple-sandbox.p12
docker compose -f docker/docker-compose.yml --profile push up -d fpush
```

`settings.json` and `*.p12` are git-ignored. The integration tests use a
stand-in component (`PushComponent`) on the same JID, so stop fpush before
running them. The example's key names follow fpush's README at the time of
writing — check them against the fpush version you build.

Old p12 files may use ciphers OpenSSL 3 rejects; fpush's docker README
describes re-encoding them with the legacy provider.
