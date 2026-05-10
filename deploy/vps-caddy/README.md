# Synthex Hub at synthex.fit via VPS + Caddy + WireGuard

The "professional" alternative to Cloudflare Tunnel: a tiny VPS owns
the public IP and TLS, your laptop owns the data and compute, and a
WireGuard tunnel is the only thing between them.

Pick this over `../cloudflared/` if any of these matter to you:

- You want **full control** over routing (no Cloudflare in the path).
- You need **arbitrary protocols** later (gRPC, websockets with very
  long timeouts, raw TCP).
- You want **arbitrary edge logic** (mTLS, geo-allowlists, custom
  headers).
- You're OK paying ~$5/mo and doing 30 min of one-time setup.

## Architecture

```
                              public internet
   workers worldwide ─────HTTPS:443──► VPS (synthex.fit, A record)
                                          │
                                          │  Caddy
                                          │  • ACME / Let's Encrypt
                                          │  • reverse_proxy 10.7.0.2:4000
                                          │
                                          ▼
                                  WireGuard interface (10.7.0.1)
                                          │  encrypted UDP
                                          │
   home box / laptop ◄───WireGuard────────┘
   (10.7.0.2)
   ↳ docker compose up
     postgres + server (bound to 10.7.0.2:4000)
```

The server listens *only* on the WireGuard IP — port 4000 is never
exposed to the internet directly.

## 1. Get a VPS

Anything cheap works (Hetzner CX11 €4/mo, OVHcloud, Vultr, DO, …).
I'll use Ubuntu 24.04 in this guide. Open ports 22, 80, 443, and
51820/udp in the provider's firewall.

## 2. Point synthex.fit at the VPS

In your DNS provider, set an A record:

```
synthex.fit    A    <vps_public_ip>
```

(For Cloudflare DNS specifically, set proxy status to "DNS only" —
the orange cloud — so Caddy can fetch certs directly.)

## 3. WireGuard between VPS and home box

There are a hundred guides for this. I like
[wg-easy](https://github.com/wg-easy/wg-easy) for the lazy path:

```bash
# On the VPS:
docker run -d --name wg-easy --restart unless-stopped \
  -e LANG=en \
  -e WG_HOST=synthex.fit \
  -e PASSWORD=<some-admin-password> \
  -e WG_DEFAULT_ADDRESS=10.7.0.x \
  -e WG_DEFAULT_DNS=1.1.1.1 \
  -p 51820:51820/udp -p 51821:51821/tcp \
  -v ~/.wg-easy:/etc/wireguard \
  --cap-add NET_ADMIN --cap-add SYS_MODULE \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv4.ip_forward=1 \
  ghcr.io/wg-easy/wg-easy
```

Open `http://<vps_ip>:51821` (over an SSH tunnel ideally), log in
with the password, click "New Client" → name it "home-box". Download
the config and apply it on your home box (macOS: WireGuard.app, free
on the App Store; Linux: `sudo wg-quick up <config>`).

Once connected, from the home box:

```bash
ping 10.7.0.1     # VPS WireGuard IP
ip a | grep 10.7  # confirm your local WG IP, e.g. 10.7.0.2
```

## 4. Run Caddy on the VPS

```bash
# On the VPS:
sudo apt install -y caddy
sudo cp deploy/vps-caddy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo journalctl -u caddy -f
```

You should see Caddy issue a Let's Encrypt cert for synthex.fit
within seconds. `https://synthex.fit/health` will 502 until step 5.

## 5. Run the Hub on the home box

```bash
cd deploy/vps-caddy
cp ../cloudflared/.env.example .env
${EDITOR:-vim} .env       # set API_TOKEN, POSTGRES_PASSWORD
```

Edit `docker-compose.yml` and replace `10.7.0.2` with whatever the
home box's WireGuard IP is. Then:

```bash
docker compose up -d --build
curl -s http://10.7.0.2:4000/health      # local-WG check
```

Now from a laptop *anywhere on the internet*:

```bash
curl -s https://synthex.fit/health
curl -s https://synthex.fit/api/status -H "Authorization: Bearer $TOKEN"
```

Friends connect their workers as in `../cloudflared/README.md`.

## Pros and cons vs. Cloudflare Tunnel

| | VPS+Caddy | Cloudflare Tunnel |
|---|---|---|
| Monthly cost | ~$5 VPS | $0 |
| Setup time | ~30 min | ~10 min |
| Public IP under your control | yes | no |
| TLS termination | on your VPS | Cloudflare |
| DDoS protection | Caddy only | full Cloudflare |
| Long-lived requests | unbounded | 100s on Free |
| You can `tcpdump` requests | yes | no |
| Cloudflare can read API payloads | no | yes (TLS terminates there) |

The "Cloudflare can read payloads" point is more philosophical than
practical for this workload (the data is JSON predicates and reward
scalars, nothing sensitive), but if it bothers you, this path
removes them from the trust chain.
