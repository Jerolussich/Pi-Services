# Caddy

Reverse proxy that routes all traffic to the correct container based on hostname. The single entry point for all Pi services — no container exposes host ports directly.

---

## Architecture

```
Browser → caddy:80
    homepage.pi     → homepage:3000     (+ Basic Auth)
    grafana.pi      → grafana:3000
    wallabag.pi     → wallabag:80
    freshrss.pi     → freshrss:80
    news.pi         → news-filter-ui:8084
    finance.pi      → finance-tracker-ui:8085
    prometheus.pi   → prometheus:9090   (+ Basic Auth)
    pihole.pi       → 192.168.68.66:8181
    <any IP access> → 403 Access denied
```

Caddy resolves container names via the shared `pi-services` Docker network. Pi-hole provides local DNS resolution for `*.pi` hostnames.

---

## Directory Structure

```
caddy/
├── docker-compose.yml
├── Caddyfile           ← Route rules and auth config
├── .env                ← gitignored (CADDY_USER, CADDY_PASSWORD_HASH)
└── .env.example
```

---

## Setup

### 1. Move Pi-hole off port 80

Caddy needs port 80. Pi-hole's built-in web server must be moved first.

Edit `/etc/pihole/pihole.toml` and find:

```
port = "80o,443os,[::]:80o,[::]:443os"
```

Change to:

```
port = "8181o,[::]:8181o"
```

Then restart:

```bash
sudo systemctl restart pihole-FTL
```

Pi-hole admin is now at `http://192.168.68.66:8181/admin`.

### 2. Add Pi-hole local DNS records

In Pi-hole admin → **Local DNS → DNS Records**, add all entries pointing to your Pi's IP:

| Domain | IP |
|---|---|
| `homepage.pi` | `your_pi_ip` |
| `grafana.pi` | `your_pi_ip` |
| `wallabag.pi` | `your_pi_ip` |
| `freshrss.pi` | `your_pi_ip` |
| `news.pi` | `your_pi_ip` |
| `finance.pi` | `your_pi_ip` |
| `prometheus.pi` | `your_pi_ip` |
| `pihole.pi` | `your_pi_ip` |

### 3. Generate password hash

```bash
docker run --rm caddy:2-alpine caddy hash-password --plaintext 'yourpassword'
```

Copy the output (starts with `$2a$`).

### 4. Configure .env

```bash
cp caddy/.env.example caddy/.env
```

Edit `caddy/.env` — escape every `$` in the hash as `$$`:

```
CADDY_USER=admin
CADDY_PASSWORD_HASH=$$2a$$14$$your_bcrypt_hash_here
```

The `$$` escaping is required because Docker Compose interpolates `$` as variable references. Each `$$` becomes a single `$` when passed to the container.

### 5. Start

```bash
cd ~/pi-services
docker compose up -d caddy
docker logs caddy
```

---

## How It Works

**Hostname-based routing** — when your browser connects to `grafana.pi` it sends `Host: grafana.pi` in the HTTP request. Caddy reads this header and matches it against Caddyfile rules to decide which container to forward to, all on port 80.

**Direct IP access blocked** — the catch-all rule `http:// { respond "Access denied" 403 }` blocks any request that doesn't match a hostname, preventing direct IP access to services.

**Basic Auth** — Homepage and Prometheus have no built-in auth so Caddy adds HTTP Basic Auth in front of them. Other services (Grafana, Wallabag, FreshRSS, Pi-hole, news-filter-ui, finance-tracker-ui) have their own login mechanisms — Caddy just proxies them.

**Shared Docker network** — all containers join the `pi-services` network. Caddy resolves service names (e.g. `grafana`, `freshrss`) as container hostnames — no IP addresses needed in the Caddyfile.

---

## Caddyfile Reference

```
http://service.pi {
    basic_auth {                              # optional
        {$CADDY_USER} {$CADDY_PASSWORD_HASH}
    }
    reverse_proxy container_name:port
}
```

`auto_https off` disables Let's Encrypt — `.pi` is not a public TLD so SSL certificates can't be issued for it.

---

## Adding a New Service

1. Add a block to `Caddyfile`
2. Add a DNS record in Pi-hole for the new hostname
3. Make sure the new container is on the `pi-services` network
4. `docker compose up -d --force-recreate caddy`

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `address already in use` on port 80 | Pi-hole still on port 80 — move to 8181 via `pihole.toml` |
| `dial tcp: lookup grafana: no such host` | Container not on `pi-services` network — add network block to its compose file |
| Caddy tries Let's Encrypt and fails | Ensure `auto_https off` is in the global Caddyfile block |
| Hash truncated in container | Escape all `$` as `$$` in `.env` |
| Auth prompt not appearing | Run `docker exec caddy env \| grep CADDY_PASSWORD` — verify hash is complete |
| `http://192.168.68.66` still works | Add catch-all: `http:// { respond "Access denied" 403 }` |
| `*.pi` not resolving | Add DNS records in Pi-hole → Local DNS → DNS Records |
