# syntax=docker/dockerfile:1.7

# ── Build stage ─────────────────────────────────────────────
# Debian-based to avoid Alpine/musl OpenSSL version skew between
# build and runtime layers (the Erlang crypto NIF gets linked at
# build-time and will fail to load if the runtime libssl is older).
FROM hexpm/elixir:1.18.4-erlang-27.3.4.3-debian-bookworm-20250908-slim AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY priv ./priv

RUN mix compile && mix release

# ── Runtime stage ───────────────────────────────────────────
# Same Debian release as the build image so libssl/libstdc++/erts
# native deps line up. ~80 MB final image.
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 libssl3 libncurses6 ca-certificates \
    bash netcat-openbsd locales tini \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    HOME=/app

WORKDIR /app

COPY --from=build /app/_build/prod/rel/server /app
COPY scripts/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
CMD ["start"]
