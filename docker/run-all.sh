#!/bin/bash
# Run all Postal services (web, worker, smtp) inside a single container.
# Used as the container CMD for all-in-one deployments (e.g. Fly.io).

set -uo pipefail

POSTAL=/opt/postal/app/bin/postal

# A global PORT env (set for the web server) would otherwise hijack the SMTP
# server, making it bind the web port and collide with puma. Each service
# falls back to its own default port when PORT is unset (web=5000, smtp=25).
unset PORT

# Ensure the mounted config volume is writable by the postal user.
chown -R postal:postal /config 2>/dev/null || true
chmod -R 755 /config 2>/dev/null || true

# Materialise the DKIM/signing key from a secret (the source of truth) so it is
# identical across machines and survives volume loss. If the secret isn't set,
# fall back to whatever key already exists on the volume.
if [ -n "${POSTAL_SIGNING_KEY:-}" ]; then
  printf '%s\n' "$POSTAL_SIGNING_KEY" > /config/signing.key
  chown postal:postal /config/signing.key
  chmod 600 /config/signing.key
fi

# Start background services.
"$POSTAL" worker &
WORKER_PID=$!

"$POSTAL" smtp-server &
SMTP_PID=$!

# Start the web server (Fly health-checks 0.0.0.0:5000).
"$POSTAL" web-server &
WEB_PID=$!

# Forward termination signals to every child for a graceful shutdown.
trap 'kill "$WORKER_PID" "$SMTP_PID" "$WEB_PID" 2>/dev/null' TERM INT

# If any service exits, tear the rest down so Fly restarts the machine.
wait -n
EXIT_CODE=$?
echo "A Postal service exited (code $EXIT_CODE); shutting down the rest."
kill "$WORKER_PID" "$SMTP_PID" "$WEB_PID" 2>/dev/null || true
wait
exit "$EXIT_CODE"
