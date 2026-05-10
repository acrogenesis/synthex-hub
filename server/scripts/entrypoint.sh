#!/bin/sh
set -e

# Wait for Postgres if WAIT_FOR_DB is set (host:port).
if [ -n "$WAIT_FOR_DB" ]; then
  HOST=$(echo "$WAIT_FOR_DB" | cut -d: -f1)
  PORT=$(echo "$WAIT_FOR_DB" | cut -d: -f2)
  echo "[entrypoint] waiting for postgres at $HOST:$PORT…"
  until nc -z "$HOST" "$PORT" 2>/dev/null; do
    sleep 1
  done
  echo "[entrypoint] postgres is up"
fi

# Decide what to run:
#   • Fly's release_command sends the absolute binary path as $1
#     (e.g. `/app/bin/server eval Server.Release.migrate`); just exec.
#   • docker compose's CMD sends `start`/`start_iex` — run migrations
#     first, then start.
#   • Anything else (`eval`, `remote`, `pid`, …) we pass straight
#     through to the binary.
case "$1" in
  /app/bin/server)
    exec "$@"
    ;;
  start|start_iex)
    echo "[entrypoint] running migrations…"
    /app/bin/server eval "Server.Release.migrate()"
    exec /app/bin/server "$@"
    ;;
  *)
    exec /app/bin/server "$@"
    ;;
esac
