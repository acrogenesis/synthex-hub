# Deploying Synthex Hub

Three opinions on how to expose your local Hub at a custom domain.
Pick one and follow that subdirectory's README end-to-end.

> Once the hub is reachable at `https://synthex.fit/`, friends donate
> compute with a single line:
>
> ```bash
> curl -fsSL https://synthex.fit/install | sh
> ```
>
> The installer is served from the hub itself
> ([`server/priv/static/install.sh`](../server/priv/static/install.sh)).
> By default it builds the worker image directly from the public
> GitHub repo (`docker build https://….git#main:worker`) — **no
> registry, no `docker login`, no separate publishing step**. If
> you'd rather pre-bake an image, [`./publish-worker.sh`](publish-worker.sh)
> builds + pushes a multi-arch one and friends pass `IMAGE=…` to skip
> the local build.

## What does the server actually need?

Honest sizing for a real Humanoid CEGAR run with 4 friends × 8
cores = 32 worker slots, sustained:

| Resource | Idle | Peak | Recommended |
|---|---|---|---|
| CPU | <1% | 5–10% of one shared vCPU | 1 shared vCPU |
| RAM | ~80 MB Elixir + ~100 MB pg | ~150 MB + ~200 MB | **512 MB** |
| Disk | tens of MB | ~50 MB / CEGAR round; pruned 7 days | 5–10 GB |
| Network | 0 | ~1 Mbps | trivial |

The actual work (rolling out Gymnasium / MuJoCo policies) happens
on workers; the server is just doing HTTP routing + Postgres
bookkeeping. **Any of the three options below has a comfortable
10× headroom on this workload.** The real question is *where* you
want the box to live, not how big it should be.

## Decision tree

```
                 ┌────────────────────────────────────────┐
                 │  Will your laptop stay reliably awake  │
                 │  for the duration of the experiment?   │
                 └─────────────────┬──────────────────────┘
                       yes         │      no
                ┌──────────────────┘      └────────────────┐
                ▼                                          ▼
   ┌────────────────────────┐                ┌──────────────────────────┐
   │ cloudflared/           │                │  Want $0 ops + native    │
   │   • free               │                │  Elixir support?         │
   │   • laptop-hosted      │                │     yes ──► fly/         │
   │   • outbound-only      │                │     more control ──►     │
   │   • 10 min setup       │                │       vps-caddy/         │
   │   • no third party in  │                └──────────────────────────┘
   │     TLS path? actually │
   │     Cloudflare is.     │
   └────────────────────────┘
```

## Side-by-side

| | **fly/** ⭐ | cloudflared/ | vps-caddy/ |
|---|---|---|---|
| Recurring cost | ~$0–10/mo | $0 | ~$4–6/mo VPS |
| Setup time | ~15 min | ~10 min | ~30 min |
| Always-on | ✓ | only while laptop is awake | ✓ |
| Custom domain | ✓ | ✓ | ✓ |
| TLS | Fly proxy | Cloudflare edge | Caddy / Let's Encrypt |
| Native Elixir tooling | first-class | n/a (just Docker) | manual |
| Survives ISP changes | n/a (cloud) | ✓ tunnel reconnects | n/a (VPS has static IP) |
| `fly logs` / `fly ssh` | ✓ | docker logs | journalctl + SSH |
| Multi-region if you want it | trivial | not really | manual |
| Cloudflare in TLS path | ✗ | ✓ (terminates at edge) | ✗ |
| You can `tcpdump` requests | yes | yes | yes |

## Which one am I running?

**`fly/`**, with Postgres on Neon's free tier. It's effectively
free, doesn't depend on my laptop, deploys with one command, and
gives me an IEx shell into production via `fly ssh console -C
"/app/bin/server remote"`.

`cloudflared/` is what I'd recommend if you genuinely have a Mac
mini sitting on your desk that's always on and you don't want any
recurring bills, however small.

`vps-caddy/` is for the small minority of people who want the most
control: BYO ingress, BYO TLS, BYO firewall rules.

## "I just want it on synthex.fit, right now"

```bash
# fly.toml lives at server/fly.toml (next to mix.exs, per Fly idiom).
cd server
fly launch --no-deploy --copy-config
fly secrets set DATABASE_URL=postgres://...neon.tech/neondb \
                API_TOKEN=$(openssl rand -hex 32)
fly deploy
fly certs create synthex.fit && fly certs show synthex.fit
# (set the DNS records that fly certs show prints)
```

Read [`fly/README.md`](fly/README.md) for the full walkthrough
including Neon setup.

## Other tools I considered and didn't pick

- **ngrok** — works fine, but custom domains are paid-only ($10+/mo),
  and rate-limits on the cheaper tiers. You already use it; the
  options here are just better-fit for "always on" hosting.
- **Tailscale Funnel** — free, no VPS, but you can't bring your own
  domain on the free tier (URLs are `*.ts.net`).
- **Render / Railway / Heroku** — all of these would also work, with
  similar economics to Fly. I picked Fly because of its exceptional
  Elixir tooling (release deploys, Distributed Erlang clustering,
  IEx console out of the box). Swap in any of them with a different
  Dockerfile invocation if you prefer.
- **frp / bore (self-hosted)** — open-source ngrok clones; only
  worth it if you already have a VPS, in which case `vps-caddy/` is
  strictly better.
- **Direct port-forward + DDNS** — exposes your home IP, no DDoS
  protection, often blocked by ISPs. Avoid.
