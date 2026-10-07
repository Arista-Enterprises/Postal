# Postal on Fly.io — Deployment & Operations Notes

App: **`beatai-dev-postal`** (Fly.io, region `iad`)
Web UI: https://beatai-dev-postal.fly.dev

This document captures how this Postal instance is deployed, the fixes applied to
get it running, and — importantly — the **outbound deliverability problem** and the
options to solve it.

---

## 1. Architecture

Postal runs as **three processes**, all sharing one MariaDB:

| Process | Command | Role |
|---|---|---|
| Web | `postal web-server` | Puma — UI + HTTP send API, binds `0.0.0.0:5000` |
| SMTP | `postal smtp-server` | Accepts inbound/outbound SMTP, binds `0.0.0.0:25` |
| Worker | `postal worker` | Delivers queued mail, fires webhooks, runs scheduled tasks |

On this deployment all three run in **one machine** via `docker/run-all.sh`
(all-in-one model). For production scale they'd be split into Fly process groups.

**Message flow:** API/SMTP accepts a message → row written to message DB + a
`queued_message` created → worker polls (~5s) → delivers outbound direct-to-MX
(this is the deliverability problem — see §5) or routes inbound to endpoints.

Data model: `Organization → Server → {Credentials, Domains, Routes, Webhooks}`.
Each Server gets its **own** message database (`postal-server-<id>`).

---

## 2. Configuration (env vars / Fly secrets)

There is **no `/config/postal.yml`** — everything is configured via environment
variables / Fly secrets. Config keys map to env vars as `GROUP_KEY` (uppercased),
e.g. `main_db.host` → `MAIN_DB_HOST`, `postal.web_hostname` → `POSTAL_WEB_HOSTNAME`.

Key settings currently in use:

| Secret / env | Purpose |
|---|---|
| `MAIN_DB_HOST/PORT/USERNAME/PASSWORD/DATABASE` | Main DB (`beatai-dev-postal-mysql.internal`, user `root`, db `postal`) |
| `MESSAGE_DB_HOST/PORT/USERNAME/PASSWORD` + `MESSAGE_DB_DATABASE_NAME_PREFIX=postal` | Per-server message DBs (same MariaDB) |
| `POSTAL_WEB_HOSTNAME=beatai-dev-postal.fly.dev` | Rails host authorization — **wrong value = 403 "Blocked hosts"** |
| `RAILS_SECRET_KEY` | Signs session cookies — must be **stable** or logins don't persist |
| `POSTAL_SIGNING_KEY` | RSA private key for DKIM signing (see §4) |

`fly.toml` also sets `BIND_ADDRESS=0.0.0.0`, `PORT=5000`, `RAILS_ENV=production`,
`POSTAL_CONFIG_FILE_PATH=/config/postal.yml`, and mounts the `postal_config`
volume at `/config`.

### Database
Postal requires **MySQL/MariaDB** (adapter `mysql2`). It does **NOT** work with
PostgreSQL — Neon, Supabase, etc. are incompatible. One MariaDB server is enough;
`main_db` and `message_db` point at the same server. The DB user needs
`CREATE DATABASE` (root has it). Postal auto-creates each server's message
database — no manual migration needed. Main DB schema is loaded by
`postal initialize` / first `make-user`.

---

## 3. First-time setup / common commands

The `postal` CLI is at `/opt/postal/app/bin/postal`. In an interactive SSH session
it is **not on PATH** — call it by path: `bin/postal <cmd>`.

```bash
fly ssh console -a beatai-dev-postal

bin/postal make-user      # create a global admin (login)
bin/postal initialize     # create + load main DB schema (first time only)
bin/postal upgrade        # migrate main DB after a version bump
bin/postal console        # Rails console
```

Login at https://beatai-dev-postal.fly.dev/login with the `make-user` admin.
There is no separate admin panel — global admins (the `admin` flag) see extra
top-level Users / Organizations / IP Pools management in the same UI.

Deploy:
```bash
fly deploy -a beatai-dev-postal          # manual
# or push to main -> .github/workflows/fly-deploy.yml deploys automatically
```

---

## 4. Signing key (DKIM) — stored as a Fly secret

Postal needs an RSA key at `/config/signing.key` (default
`postal.signing_key_path`). It is the basis of DKIM signing.

**It is stored as the `POSTAL_SIGNING_KEY` secret** (source of truth), and
`docker/run-all.sh` writes it to `/config/signing.key` on every boot. This makes
it consistent across machines and resilient to volume loss.

Generate / rotate:
```bash
openssl genrsa -out signing.key 2048
fly secrets set POSTAL_SIGNING_KEY="$(cat signing.key)" -a beatai-dev-postal
# back up signing.key somewhere safe (password manager). Rotating it invalidates
# previously published DKIM records.
```

---

## 5. ⚠️ Outbound deliverability — the main open issue

**The server works end-to-end.** A test send was DKIM-signed, processed by the
worker, and delivered to Gmail's MX. Gmail then **hard-rejected** it:

```
550-5.7.1 ... does not meet IPv6 sending guidelines regarding
PTR records and authentication
```

### Why
Postal sends **direct-to-MX**. Gmail's rejection has two parts:

1. **Authentication** (SPF/DKIM/DMARC) — fixable via your domain's DNS. ✅
2. **PTR / rDNS** on the *sending IP* — **NOT fixable.** PTR can only be set by
   the IP's owner (Fly), and **Fly does not give customers rDNS control**, even on
   dedicated IPs. Over IPv6, Gmail *hard-requires* a valid PTR. Fly's egress IP
   has none matching the domain → permanent reject.

**Conclusion: Postal-on-Fly cannot deliver direct-to-MX to Gmail.** This is a
platform limitation, not a missing config.

### Additional constraint in this build
This Postal fork's relay feature **does not support SMTP authentication**:
- `app/senders/smtp_sender.rb` / `app/lib/smtp_client/endpoint.rb` call
  `smtp_client.start(helo)` with no credentials.
- `lib/postal/config_schema.rb` relay transform only parses `host`/`port`/`ssl_mode`.

So pointing `POSTAL_SMTP_RELAYS` at SES/SendGrid/Mailgun (which require auth) will
**not work without a code patch**.

---

## 6. Options to fix deliverability

### Option A — Patch Postal for authenticated relay, then relay via a provider (recommended)
Route outbound through SES / SendGrid / Mailgun / Postmark / Resend. Their IPs have
correct PTR + reputation, so the PTR problem disappears (you never set PTR).

**Patched 2026-09-30 (uncommitted):** relay URIs now accept `user:pass@`
(percent-decoded) and Postal authenticates with AUTH LOGIN
(`config_schema.rb`, `smtp_client/server.rb`, `smtp_client/endpoint.rb`,
`smtp_sender.rb`). It refuses to authenticate unless TLS is enforced, so
`ssl_mode` must be `TLS` (port 465) or `STARTLS` (port 587). Note the upstream
spelling: `SSLModes::STARTTLS == "STARTLS"`, so `ssl_mode=STARTTLS` falls through
to *no TLS at all*.

SendGrid (username is literally `apikey`):
```bash
fly secrets set \
  POSTAL_SMTP_RELAYS="smtp://apikey:SG.xxxxx@smtp.sendgrid.net:465?ssl_mode=TLS" \
  -a beatai-dev-postal
fly deploy -a beatai-dev-postal
```
Most reliable; keeps Postal as the API/queue/dashboard/tracking layer.

### Option B — Use a provider's API directly
Skip Postal for sending; call SES/SendGrid/etc. from the app. Simplest
deliverability, but you stop using Postal for outbound.

### Option C — Set DNS only, accept the limits
Configure SPF/DKIM/DMARC and accept that Gmail/Microsoft will often reject or
spam-folder mail sent direct from Fly. **Testing only.**

> **Provider:** SendGrid (2026-09-30), relayed per Option A.

---

## 7. DNS records to set regardless (per sending domain)

Add the domain to the Server in the UI; Postal generates the exact records. You'll
set, at your domain's DNS host:
- **SPF** `TXT` (authorize the sender)
- **DKIM** `TXT` (public key derived from `POSTAL_SIGNING_KEY`)
- **DMARC** `TXT`
- **Return-path** `CNAME`
- **Verification** `TXT`, and tracking/MX records if using those features

These fix the *authentication* half of Gmail's complaint but **do not** fix PTR.
Also set `POSTAL_SMTP_HOSTNAME` and the return-path/DNS config (currently default
`postal.example.com`, visible in message IDs like `...@rp.postal.example.com`).

---

## 8. Fixes already applied this session

For history — these got the server from crash-looping to fully functional:

1. **Exec bits** — `docker/wait-for.sh` and all `bin/*` had lost their executable
   bit (caused entrypoint spawn failure / exit code 126). Restored, and hardened
   the Dockerfile (`COPY --chmod=0755`, `chmod +x ./bin/*`).
2. **All-in-one runner** — added `docker/run-all.sh` running web + worker + smtp
   with signal handling; Dockerfile `CMD` points at it (was `web-server` only).
3. **Port collision** — global `PORT=5000` made the SMTP server bind 5000 and
   fight puma. `run-all.sh` does `unset PORT` so each service uses its default
   (web 5000, smtp 25).
4. **fly.toml ports** — external 587 and 2525 now map to internal **25** (the
   single smtp-server port).
5. **`POSTAL_WEB_HOSTNAME`** set (was defaulting to `postal.example.com` → 403).
6. **`RAILS_SECRET_KEY`** set to a stable value (was ephemeral per-boot).
7. **`MESSAGE_DB_*`** pointed at the same MariaDB (fixed 500 on server creation).
8. **Signing key** generated and stored as `POSTAL_SIGNING_KEY` secret.

---

## 9. Runbook / useful commands

```bash
fly status -a beatai-dev-postal
fly logs -a beatai-dev-postal
fly ssh console -a beatai-dev-postal

# what's listening (expect :5000 and :25)
fly ssh console -a beatai-dev-postal -C "ss -tlnp"

# DB env in use
fly ssh console -a beatai-dev-postal -C "env | grep -i DB"

# send a test via API (needs an API-type credential)
curl -X POST https://beatai-dev-postal.fly.dev/api/v1/send/message \
  -H "X-Server-API-Key: <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"to":["you@example.com"],"from":"test@yourdomain.com","subject":"t","plain_body":"hi"}'
```

Check message status in the UI under **Server → Messages → Outgoing / Held**, or in
`fly logs`. "Held" usually = sender domain not verified; "Hard fail 550 ... PTR" =
the deliverability issue in §5.

---

## 10. Inbound (email agent — aios-platform/spec/20)

Inbound mail for `*@arista.zagreusos.com` flows: sender → MX → this Postal →
HTTP endpoint on arista-aios. **Never put an MX on `zagreusos.com` itself** —
its mail lives on Outlook (`include:spf.protection.outlook.com`).

### 10.1 Networking — dedicated IPv4 required

The shared Fly IPv4 cannot route plain SMTP (no SNI/Host to route on), so
inbound port 25 needs a **dedicated IPv4** (paid):

```bash
fly ips allocate-v4 -a beatai-dev-postal          # JACL gate — costs money
fly ips list -a beatai-dev-postal
```

fly.toml already maps external 25/587/2525 → internal 25.

### 10.2 DNS (GoDaddy, zone zagreusos.com)

| Record | Name | Value |
|---|---|---|
| A | `mx` | the dedicated IPv4 from 10.1 |
| MX | `arista` | `mx.zagreusos.com` (priority 10) |
| A/CNAME | `postal`, `rp`, `routes` | per the hostname secrets below |

### 10.3 Hostname secrets (replace the `postal.example.com` placeholders)

```bash
fly secrets set \
  POSTAL_SMTP_HOSTNAME=postal.zagreusos.com \
  DNS_MX_RECORDS=mx.zagreusos.com \
  DNS_RETURN_PATH_DOMAIN=rp.zagreusos.com \
  DNS_ROUTE_DOMAIN=routes.zagreusos.com \
  -a beatai-dev-postal
```

### 10.4 Server / route / endpoint (Postal UI)

* Server **`arista-mail-agent`** (own API key for later replies), not the
  `arista-crm` sending server.
* Domain `arista.zagreusos.com` (admin add = auto-verified).
* HTTP endpoint `https://arista-aios.fly.dev/webhooks/email/postal/<route_key>`
  — format **Hash**, encoding **BodyAsJSON**, include attachments **off**,
  timeout **15 s**. Generate the route key:
  `python3 -c 'import secrets;print(secrets.token_urlsafe(24))'`
* Route `support@arista.zagreusos.com` → that endpoint.

The endpoint answers per aios `ingress.py`: 200 accepted/duplicate · 404
unknown route (bounce, correct) · 401 bad signature (bounce, forged only) ·
**503 unknown KID (retried — fix `POSTAL_JWKS` on arista-aios)** · 429
oversize/rate-limited (no bounce) · 503 DB down (retried).

### 10.5 Endpoint signing + JWKS pinning + key rotation

Postal signs every endpoint POST: `X-Postal-Signature-256` =
base64(RSA-SHA256 PKCS#1 v1.5 over the exact raw body), KID in
`X-Postal-Signature-KID`. Public keys: `GET /.well-known/jwks.json` (no auth).

arista-aios verifies against the **pinned** `POSTAL_JWKS` secret — it never
fetches the URL at runtime. Rotation procedure (also fixes the committed-key
incident — the repo-root `signing.key` of commit 5399d72 WAS the live key):

```bash
# 1. new key (do NOT write it into the repo)
openssl genrsa -out /tmp/postal-signing.key 2048
fly secrets set POSTAL_SIGNING_KEY="$(cat /tmp/postal-signing.key)" -a beatai-dev-postal
fly deploy  # or let the release restart pick it up

# 2. fetch the NEW jwks and pin OLD+NEW on arista-aios (zero-downtime overlap)
curl -s https://beatai-dev-postal.fly.dev/.well-known/jwks.json
fly secrets set POSTAL_JWKS='{"keys":[<old-key>,<new-key>]}' -a arista-aios

# 3. once no unknown_kid 503s remain in arista-aios logs, drop the old key
fly secrets set POSTAL_JWKS='{"keys":[<new-key>]}' -a arista-aios
```

The same key signs the return-path DKIM fallback; per-domain DKIM keys are
separate, so rotating it does not break the per-domain DKIM records.
`signing.key` must never be committed again (`.gitignore`d; `git rm --cached`).
