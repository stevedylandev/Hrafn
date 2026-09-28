-- Prosody configuration for the Hrafn development server (alpha.test).
-- Enables every v1 XEP Hrafn depends on, so missing server support never
-- masquerades as a client bug.

admins = { "admin@alpha.test" }
pidfile = "/var/run/prosody/prosody.pid"

modules_enabled = {
  -- RFC 6120 / 6121 core
  "roster"; "saslauth"; "tls"; "dialback"; "disco"; "carbons"; "pep";
  "private"; "blocklist"; "vcard4"; "vcard_legacy"; "version"; "uptime";
  "time"; "ping"; "register"; "admin_adhoc"; "posix";
  "admin_shell";   -- prosodyctl shell: session listing for the push UI test

  -- Mobile resilience
  "smacks";        -- XEP-0198 stream management
  "csi_simple";    -- XEP-0352 client state indication

  -- History and multi-device
  "mam";           -- XEP-0313 message archive management

  -- Media
  "http_file_share";  -- XEP-0363 HTTP upload

  -- Bookmarks 2 (XEP-0402) is served by mod_pep with the right access model.
  "bookmarks";

  -- Push (XEP-0357), from prosody-modules; the image installs it.
  "cloud_notify";

  -- Fast reconnection (v1.1, pulled into v1): XEP-0388 SASL2, XEP-0386
  -- Bind 2, XEP-0198 inside SASL2, XEP-0484 FAST. All from prosody-modules.
  "sasl2"; "sasl2_bind2"; "sasl2_sm"; "sasl2_fast";
}

modules_disabled = {
  "s2s_bidi";  -- keeps s2s traffic easy to read in captures
}

-- TLS: RFC 7590 floor, and a certificate covering the domain plus its
-- subdomains for MUC and upload.
c2s_require_encryption = true
s2s_require_encryption = true
s2s_secure_auth = false          -- the test CA is not in any trust store
allow_unencrypted_plain_auth = false

ssl = {
  certificate = "/etc/prosody/certs/alpha.test.crt";
  key = "/etc/prosody/certs/alpha.test.key";
  protocol = "tlsv1_2+";
}

-- XEP-0368: Direct TLS on 5223 for c2s.
c2s_direct_tls_ports = { 5223 }
c2s_direct_tls_ssl = {
  certificate = "/etc/prosody/certs/alpha.test.crt";
  key = "/etc/prosody/certs/alpha.test.key";
}

authentication = "internal_hashed"   -- lets SCRAM-SHA-256 work without PLAIN
storage = "internal"

-- Federation between the containers. libunbound answers `.test` names from a
-- built-in RFC 6761 local zone (always NXDOMAIN), so Docker's DNS is never
-- asked; entries in /etc/hosts (docker-compose `extra_hosts`) are served.
unbound = { resolvconf = true; hoststxt = "/etc/hosts" }

-- XEP-0114 external components: the push app server (fpush in production,
-- a stand-in in the integration tests) connects here.
component_ports = { 5347 }
component_interfaces = { "*" }

archive_expires_after = "1w"
default_archive_policy = true
max_archive_query_results = 100

log = {
  { levels = { min = "debug" }, to = "console" };
}

VirtualHost "alpha.test"
  -- Accounts are created by scripts/dev-accounts.sh.

Component "conference.alpha.test" "muc"
  modules_enabled = { "muc_mam"; "muc_moderation" }  -- XEP-0425 from prosody-modules
  restrict_room_creation = false

Component "upload.alpha.test" "http_file_share"
  http_file_share_size_limit = 16 * 1024 * 1024
  http_file_share_expire_after = 60 * 60 * 24 * 7

-- XEP-0357 app server. Tests connect a stand-in (PushComponent); a real
-- deployment runs fpush here (docker/fpush).
Component "push.alpha.test"
  component_secret = "pushsecret"
