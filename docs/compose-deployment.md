# Deploy with Docker Compose

Run Stoatchat without a Kubernetes cluster. The `generate-compose.sh` script
converts the same Helmfile charts into a `compose.yml` + `Caddyfile`, using
[helmfile2compose](https://github.com/baptisterajaut/helmfile2compose).

## What you need

- A Unix terminal (Linux, macOS, WSL)
- Docker or a compatible runtime (`nerdctl`, `podman`)
- [Helm](https://helm.sh/) v3 and [Helmfile](https://github.com/helmfile/helmfile) v0.169+
- Python 3 with `pyyaml` (`pip install pyyaml`)
- `openssl`
- No Kubernetes cluster, no Kubernetes knowledge

> **Windows note:** native Windows (PowerShell / cmd) is not supported.
> Use WSL 2 with Docker Desktop's WSL backend. Running the generation
> toolchain directly on Windows is possible in theory but fragile — shell
> scripts, `openssl`, Python, and Helm all need to be installed and
> behave identically to their Unix counterparts, which is rarely the case.

## Quick start

```bash
git clone git@github.com:baptisterajaut/stoatchat-platform.git && cd stoatchat-platform
./generate-compose.sh
docker compose up -d   # or: nerdctl compose up -d
```

On the first run, the script asks a few questions:

1. **Domain** (default: `stoatchat.local`)
2. **Voice/video** — enable LiveKit? (default: no)
3. **Data directory** — where to store persistent data (default: `~/stoat-data`)
4. **Let's Encrypt email** — only asked for non-`.local` domains

It then generates all secrets, renders Helmfile templates, and produces the
final `compose.yml` and `Caddyfile`.

Subsequent runs skip the interactive setup and just re-render — useful after
pulling chart updates or changing environment values.

## What gets generated

| File | Description |
|------|-------------|
| `environments/compose.yaml` | Helmfile environment values (domain, seed, toggles) |
| `environments/vapid.secret.yaml` | VAPID keypair for push notifications |
| `environments/files.secret.yaml` | File encryption key |
| `helmfile2compose.yaml` | Conversion config (volumes, overrides, custom services) |
| `compose.yml` | Docker Compose service definitions |
| `Caddyfile` | Reverse proxy config (TLS, path routing) |
| `configmaps/` | Generated config files (e.g. `Revolt.toml`) |
| `secrets/` | Generated secret files (e.g. MinIO credentials) |

All generated files are gitignored.

## DNS

Point your domain (and `livekit.<domain>` if voice is enabled) to the host
running compose. For real domains, Caddy obtains Let's Encrypt certificates
automatically.

For `.local` domains (local testing), add an `/etc/hosts` entry:

```
127.0.0.1  <domain> livekit.<domain>
```

Caddy uses its internal CA for `.local` domains. Accept the certificate
warning in the browser, or trust Caddy's root CA from `data/caddy/pki/`.

## Credentials

All infrastructure passwords are derived from `secretSeed` via
`sha256(seed:identifier)`. The script prints them at the end:

```
Credentials (derived from secretSeed):
  MongoDB:  stoatchat / <derived>
  RabbitMQ: stoatchat / <derived>
  MinIO:    <derived> / <derived>
```

To retrieve them later, re-run `./generate-compose.sh` (it prints them every
time without regenerating anything).

## It works — now what?

**Do not edit `compose.yml` or `Caddyfile` by hand.** They are generated
from the Helm charts and will be overwritten on the next run of
`generate-compose.sh`.

All configuration lives in `environments/compose.yaml` (domain, services,
SMTP, etc.) and `helmfile2compose.yaml` (volume paths, service overrides).
Edit those, then re-run the script:

```bash
$EDITOR environments/compose.yaml
./generate-compose.sh
docker compose up -d
```

**Pull regularly.** The Compose deployment piggybacks on the same Helm
charts and Helmfile used for Kubernetes. When charts are updated (version
bumps, config fixes, new features), a simple `git pull && ./generate-compose.sh`
picks them up — no manual compose.yml editing, no config to maintain in
two places.

## Configuration

### Data directory

The `volume_root` in `helmfile2compose.yaml` controls where all persistent
data is stored:

```yaml
volume_root: /home/user/stoat-data
```

Subdirectories are created automatically: `mongodb/`, `redis/`, `rabbitmq/`,
`minio/`.

### Disabling services

Toggle services in `environments/compose.yaml`:

```yaml
apps:
  gifbox:
    enabled: false
  voiceIngress:
    enabled: false

livekit:
  enabled: false
```

Then re-run `./generate-compose.sh && docker compose up -d`.

### SMTP

Without SMTP, email verification is skipped and accounts are immediately
usable. To enable it, edit `environments/compose.yaml`:

```yaml
smtp:
  host: "smtp.example.com"
  port: 587
  username: "user"
  password: "pass"
  fromAddress: "noreply@example.com"
  useTls: false
  useStarttls: true
```

## How it works

The script reuses the same Helm charts as the Kubernetes deployment. The
conversion pipeline:

```
Helm charts
    ↓  helmfile -e compose template
K8s manifests (Deployments, Services, ConfigMaps, Secrets, Ingress...)
    ↓  helmfile2compose.py
compose.yml + Caddyfile + configmaps/ + secrets/
```

The script auto-downloads
[helmfile2compose.py](https://github.com/baptisterajaut/helmfile2compose)
from a pinned release on first run.

A dedicated `compose` Helmfile environment disables K8s-only infrastructure
(cert-manager, ingress controller, reflector) and adjusts defaults for
compose (see [differences from Kubernetes](#differences-from-kubernetes)).

## Differences from Kubernetes

The compose deployment uses the same Helm charts but with some adaptations:

| Aspect | Kubernetes | Compose |
|--------|-----------|---------|
| Reverse proxy | HAProxy Ingress controller | Caddy (auto-TLS, path routing) |
| TLS | cert-manager (selfsigned or Let's Encrypt) | Caddy (internal CA or Let's Encrypt) |
| Redis image | bitnami/redis | redis:7-alpine |
| LiveKit UDP range | 50000–60000 | 50000–50100 |
| voice-ingress | Disabled by default (separate toggle) | Enabled automatically with LiveKit |
| Secret replication | Reflector (cross-namespace) | Not needed (single compose network) |
| Namespace isolation | Per-service namespaces | Single compose network |

### LiveKit port range

Kubernetes defaults to 50000–60000 (10,000 ports) for WebRTC media because
LiveKit uses host networking — ports are opened directly on the node without
any iptables overhead. Docker publishes ports via iptables rules, and
10,000 port mappings will bring iptables to its knees (extremely slow
`docker compose up`, high CPU on rule evaluation). The compose environment
defaults to 50000–50100 (100 ports) to avoid this.

Increase the range only if you actually need more concurrent media streams:

```yaml
livekit:
  rtcPortRangeStart: 50000
  rtcPortRangeEnd: 50500
```

### Voice

When LiveKit is enabled in compose, `voice-ingress` is also enabled by
default (both use the same toggle in `compose.yaml.example`). On Kubernetes,
`apps.voiceIngress.enabled` must be set separately.

Voice functionality may be incomplete upstream — `voice-ingress` is missing
from the official [stoatchat/self-hosted](https://github.com/stoatchat/self-hosted)
Docker Compose setup.

## Troubleshooting

### Services crash with "Revolt.toml not found"

The `configmaps/` directory must exist before starting compose. This happens
automatically when running `./generate-compose.sh`. If you ran
`docker compose up` without the script, the container runtime creates empty
directories instead of the expected files. Fix:

```bash
docker compose down
rm -rf configmaps/ secrets/
./generate-compose.sh
docker compose up -d
```

### Re-generating from scratch

Delete the generated files and start over:

```bash
docker compose down -v
rm -f compose.yml Caddyfile helmfile2compose.yaml helmfile2compose.py
rm -rf configmaps/ secrets/ generated-platform/
# Optionally reset environment too:
# rm -f environments/compose.yaml environments/vapid.secret.yaml environments/files.secret.yaml
./generate-compose.sh
docker compose up -d
```
