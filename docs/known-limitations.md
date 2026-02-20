# Known Limitations

Current gotchas and limitations of the stoatchat-platform deployment.

## Client PWA service worker

The for-web client ships a service worker that precaches ~380 JS assets.
After rebuilding the client image, **hard refresh alone is not enough**.
Users must either:

- Unregister the service worker: DevTools → Application → Service Workers
  → Unregister
- Use private/incognito browsing
- Clear site data: DevTools → Application → Storage → Clear site data

This affects every client image rebuild, not just version bumps.

## Revolt API versioning

Auth routes (`/auth/*`) have no version prefix, but API routes use `/0.8/*`.
The client SDK handles this transparently. If you're making direct API calls,
be aware of the inconsistency.

## SMTP disabled = no email verification

When `smtp.host` is empty in the environment file, the `[api.smtp]` section is
omitted from `Revolt.toml` entirely. The API then skips email verification
and accounts are immediately usable after creation.

The client (`echohaus` branch) includes an email validation bypass flow that
improves the UX when email verification is disabled server-side - users are
not prompted for email verification when it's not required.

This is convenient for development but means anyone with network access to
the instance can create accounts without verification. Consider enabling
invite-only registration (see client features below) for private instances.

## Bitnami image removal from Docker Hub

Bitnami regularly removes specific image tags from Docker Hub with no
advance notice:

- **RabbitMQ:** all `bitnami/rabbitmq` tags removed. I switched to the
  official `rabbitmq:4-management` image deployed via the generic stoatchat-app
  chart.
- **MongoDB:** specific tags (`-debian-XX-rN` variants) removed. Only
  `latest` works reliably. The chart forces `image.tag: latest`.

Avoid adding new bitnami dependencies. Existing ones (MongoDB, Redis) should
be monitored and ideally migrated long-term.

## ConfigMap propagation requires pod restart

Changes to `Revolt.toml` (via Helmfile values) update the ConfigMap, but
running pods don't pick up the new configuration automatically. After any
configuration change:

```bash
# Re-deploy to update the ConfigMap
helmfile -e local sync

# Restart app pods to pick up the new Revolt.toml
kubectl rollout restart deployment -n stoatchat
```

## LiveKit host network

LiveKit requires host-network access for WebRTC media transport. The
following ports must be open on the node firewall:

| Port | Protocol | Purpose |
|------|----------|---------|
| 7881 | TCP | LiveKit signaling |
| 50000–60000 | UDP | WebRTC media (configurable via `livekit.rtcPortRangeStart` / `rtcPortRangeEnd`) |

In cloud environments, ensure security groups allow this traffic. On k3s
with a single node, this typically works out of the box.

## No admin panel

The `stoatchat/service-admin-panel` project exists but is not included in
this deployment. It requires Authentik for authentication and has private
submodule dependencies, making it impractical for self-hosting.

Administrative tasks (user management, instance configuration) must be done
directly via the API or MongoDB.

## Web client (`for-web`) upstream issues

These are upstream limitations in the `for-web` codebase, not deployment issues.

### Video/screen sharing (experimental)

Video and screen sharing are disabled in the upstream `for-web` client
(hardcoded `isDisabled` in `VoiceCallCardActions.tsx`). The default
`build.conf` uses a non-mainline patch (`Dadadah/stoat-for-web`,
branch `echohaus`) that re-enables these buttons and includes additional
features (see below). This is experimental and may break with upstream
updates (if it works at all).

**Additional features in `echohaus` branch:**
- **Email validation bypass** - improved UX when SMTP is disabled
- **Multi-region LiveKit** - voice server selection based on server description
- **Invite-only registration** - optional invite code requirement (config-driven)
- **Noise cancellation** - rnnoise-based audio processor via `@cc-livekit/denoise-plugin`
- **Legacy button removal** - UI cleanup

### GIF picker requires a Tenor API key

The `gifbox` service in the Stoatchat monorepo is a lightweight Tenor proxy
(Rust/Axum) — not a full GIF platform. It needs a Google Tenor API key to
function.

To enable GIF support, uncomment and fill in the gifbox section in your
environment file:

```yaml
apps:
  gifbox:
    enabled: true
    tenorKey: "<your-tenor-api-key>"
```

The setting is pre-configured (commented out) in `local.yaml.example`,
`compose.yaml.example`, and `remote.yaml.example`.

**Tenor API key caveat:** the gifbox service proxies requests to
`tenor.googleapis.com/v2` (hardcoded in upstream). As of January 2026,
Google [no longer accepts new Tenor API clients](https://developers.google.com/tenor/guides/quickstart).
If you already have a key it still works. Otherwise, gifbox is unusable
until upstream adds support for an alternative provider (e.g.
[Klipy](https://klipy.com), a drop-in Tenor replacement).

**What happens in each state:**

| gifbox   | Tenor key       | Result                                                                                                                                                                                                                                                |
|----------|-----------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| disabled | n/a             | GIF picker is visible but empty. Requests to `/gifbox` fall through to the client SPA, which returns HTML instead of JSON. The picker silently shows nothing — no console errors.                                                                     |
| enabled  | invalid/missing | gifbox panics on the unexpected Tenor API response (`unwrap()` on deserialization errors). The pod stays Running but stops handling requests, producing 502s. The picker retries aggressively, eventually triggering 429s from HAProxy rate limiting. |
| enabled  | valid           | Should work as expected? Idk i don't have a key to test                                                                                                                                                                                               |

**Do not enable gifbox without a valid Tenor key.** The retry storm from
the GIF picker is enough to hit HAProxy's rate limit for the entire domain,
which means 429s on all services (API, WebSocket, file uploads) — not just
gifbox. A bad key can degrade the whole platform.

### Image pull policy

The client image uses tag `dev` (mutable) and `imagePullPolicy: Always` to
ensure the latest build is always pulled. Other Stoatchat services use immutable
GHCR tags with `IfNotPresent`.

If you switch the client to an immutable tag, you can change the pull policy
to `IfNotPresent` to avoid unnecessary pulls.

## Voice upstream status

The `voice-ingress` daemon (LiveKit webhook → MongoDB/RabbitMQ bridge) is
included in this deployment but missing from the official
[stoatchat/self-hosted](https://github.com/stoatchat/self-hosted) Docker
Compose setup. Voice functionality may be incomplete or broken upstream.

`voice-ingress` is disabled by default (`apps.voiceIngress.enabled: false`).
See [Compose differences](compose-deployment.md#voice) for compose-specific
behavior.
