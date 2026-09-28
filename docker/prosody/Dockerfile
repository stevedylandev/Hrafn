# The prosody/prosody images on Docker Hub stopped at 0.11 (2021), which predates
# mod_http_file_share and the core stream-management module Hrafn needs. Build
# from Prosody's own apt repository instead, which also carries
# prosody-modules for the community modules Phase 5 needs (mod_cloud_notify).
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
 && install -d /usr/share/keyrings \
 && curl -fsSL https://prosody.im/files/prosody-debian-packages.key \
      -o /usr/share/keyrings/prosody-debian-packages.key \
 && echo "deb [signed-by=/usr/share/keyrings/prosody-debian-packages.key] \
https://packages.prosody.im/debian bookworm main" > /etc/apt/sources.list.d/prosody.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      prosody \
      prosody-modules \
      lua-dbi-sqlite3 \
      lua-unbound \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# prosody-modules drops the community modules straight into the core plugin
# directory, so mod_cloud_notify (XEP-0357) is on the default search path.

RUN mkdir -p /var/run/prosody /var/lib/prosody \
 && chown -R prosody:prosody /var/run/prosody /var/lib/prosody

EXPOSE 5222 5223 5269 5280 5281
USER prosody
CMD ["prosody", "-F"]
