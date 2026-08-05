# Planelyx — VPS Deployment Runbook

Deploying Planelyx to a single VPS: images built in CI, pushed to GCP Artifact Registry,
pulled onto the VPS by a Compose stack sitting behind a host-installed nginx, all under one
hostname.

```
https://planelyx.com/      ->  302 to /ui/
https://planelyx.com/ui/   ->  Angular SPA
https://planelyx.com/api/  ->  Spring Boot
https://planelyx.com/auth/ ->  Keycloak
```

**Architecture decisions:** path-based routing on one hostname; nginx and Postgres installed
on the host; everything else in Compose bound to `127.0.0.1`; one Postgres server with two
databases (`planelyx`, `keycloak`); a custom Keycloak image in its own repo carrying the
realm export and login theme.

## Checklist

Phases 1–4 and 6–7 are **implemented and verified locally**. Phase 5 and the cutover are
yours to run on the VPS.

- [x] **Phase 1** — `planelyx-auth` (Keycloak image) — built, booted, realm imported
- [x] **Phase 2** — `planelyx-ui`: base-href-aware auth redirects, Dockerfile, nginx
- [x] **Phase 3** — `planelyx-api`: proxy headers, health endpoint, hardened prod image
- [x] **Phase 4** — CI workflows → Artifact Registry (needs GCP secrets set)
- [ ] **Phase 5** — VPS host setup (packages, firewall, Postgres, DNS, TLS)
- [x] **Phase 6** — nginx site config — `nginx -t` clean
- [x] **Phase 7** — `planelyx-infra` (`compose.prod.yaml`, `deploy.sh`)
- [ ] **Cutover** — in order; Keycloak's first boot is the one that imports the realm
- [ ] **Verify** — issuer string first, then browser end-to-end

Before the first deploy you must still: create the two new git repos and push, set the GCP
secrets (`GCP_SA_KEY`, `GCP_PROJECT_ID`) in all three repos, and
create the Artifact Registry repository itself.

---

## The central constraint — read this first

`src/main/resources/application.yaml` validates JWTs by `issuer-uri` alone. The `iss` claim
in every token must match `KEYCLOAK_ISSUER_URI` **character for character**, and the browser
and the API container must both use that same URL. Under path-based routing that URL is:

```
https://planelyx.com/auth/realms/planelyx
```

`KC_HTTP_RELATIVE_PATH`, `KC_HOSTNAME`, the nginx `location /auth/` block, and the
`extra_hosts` entry on the API container all exist to make that one string true from every
vantage point. Get it wrong and every authenticated request 401s.

---

## Repository layout

Two new repos join the existing two:

| Repo | Contains | Produces |
|---|---|---|
| `planelyx-api` (exists) | Spring Boot | image `api` |
| `planelyx-ui` (exists) | Angular | image `ui` (nginx + static) |
| `planelyx-auth` (**new**) | Keycloak Dockerfile, `realm-export.json`, `themes/planelyx/` | image `auth` |
| `planelyx-infra` (**new**) | `compose.prod.yaml`, nginx site config, `.env.example`, `deploy.sh` | nothing — cloned onto the VPS |

`planelyx-auth` takes over `planelyx-api/docker/keycloak/` (both the realm export and the
theme). The API repo's `docker/` directory keeps only `postgres/init-keycloak-db.sql` for
local dev, and the existing `compose.yaml` stays exactly as it is for local development —
this runbook does not touch it.

> Both git remotes still point at `fintrack-api` / `fintrack-ui`. Renaming is optional and
> orthogonal — but if you want it, do it *before* wiring CI, not after. (The env vars are
> already `PLANELYX_*` throughout; only the remotes lag.)

---

## Phase 1 — `planelyx-auth` (new repo)

### `planelyx-auth/Dockerfile`

Pinned to **26.0**, matching the version the local `compose.yaml` already runs, so
production is not simultaneously a version bump. See the file for the full contents.

`kc.sh build` bakes in the Postgres provider and the `/auth` relative path so runtime
startup is fast and `--optimized` is safe.

Production mode **caches themes**, unlike the `start-dev` used locally — theme edits now
require an image rebuild.

### ⚠️ Build-time options must be baked, not passed at runtime

`KC_DB`, `KC_HEALTH_ENABLED`, `KC_HTTP_RELATIVE_PATH` and
`KC_HTTP_MANAGEMENT_RELATIVE_PATH` are **build-time** options. With `start --optimized`,
supplying a *different* value at runtime does not override it — Keycloak prints

```
The following build time options have values that differ from what is persisted -
the new values will NOT be used until another build is run
```

and **exits 2**. It is a hard startup failure, not a warning. This was caught by booting
the image; the plan's original `compose.prod.yaml` set
`KC_HTTP_MANAGEMENT_RELATIVE_PATH` at runtime and would have failed on the very first
boot.

They therefore live in the builder stage `ENV` and are deliberately absent from
`compose.prod.yaml`. `KC_HTTP_MANAGEMENT_RELATIVE_PATH=/` is the one that matters: without
it the management interface inherits `/auth` and the health probe moves to
`:9000/auth/health/ready`.

### `planelyx-auth/realm/realm-export.json`

Derived from `planelyx-api/docker/keycloak/realm-export.json`, with three changes:

- `"sslRequired": "none"` → `"external"`
- the seeded `demo` / `Demo@Fintrack1` user is **removed** — otherwise it is a live
  credential on the public internet
- redirect URIs are driven by a **new** variable so one file serves both environments:

| Variable | Local | Production | Drives |
|---|---|---|---|
| `PLANELYX_UI_ORIGIN` | `http://localhost:4200` | `https://planelyx.com` | `webOrigins` — a CORS origin, rejects a path |
| `PLANELYX_UI_BASE_URL` | `http://localhost:4200` | `https://planelyx.com/ui` | `rootUrl`, `redirectUris`, post-logout — includes the base path |

The split exists because `webOrigins` must be a bare origin while redirect URIs must carry
the `/ui` prefix. Using one variable for both cannot express that.

Verified against a running Keycloak: `redirect_uri=https://planelyx.com/ui/` is
accepted, and `redirect_uri=https://planelyx.com/dashboard` is rejected with
`Invalid parameter: redirect_uri` — which is exactly the failure the Angular
`prepareExternalUrl` fix in Phase 2 prevents.

### ⚠️ Realm import is first-boot only

`--import-realm` is a **no-op if the realm already exists** in the `keycloak` database. The
env-var substitution above only ever happens on that first import. Every later realm change
must go through the admin console or `kcadm.sh` — from then on the JSON file is
documentation, not the source of truth.

Plan the first boot carefully. It is the one cheap chance to get the realm right.

### ⚠️ Registration must collect first and last name

Keycloak 26's declarative user profile marks `firstName` and `lastName` required. A user
missing them cannot obtain a token **at all** — the token endpoint returns
`{"error":"invalid_grant","error_description":"Account is not fully set up"}` while
`requiredActions` reads as an empty list, which makes it hard to diagnose from the admin
console.

The custom `register.ftl` must collect both fields. Confirm this by registering a genuinely
new user through the browser during verification, not by creating one via `kcadm`.

---

## Phase 2 — `planelyx-ui`

### Code changes: three hardcoded `window.location.origin` uses

Serving under `/ui/` breaks three call sites that assume the app is at the domain root.
`--base-href /ui/` rewrites `index.html`, but not TypeScript.

**`src/app/core/auth/keycloak.providers.ts:39`** — resolve against the document base rather
than the origin:

```ts
silentCheckSsoRedirectUri: new URL('silent-check-sso.html', document.baseURI).href,
```

`document.baseURI` reflects the `<base href>` the CLI stamps in, so this yields
`https://planelyx.com/ui/silent-check-sso.html` in prod and
`http://localhost:4200/silent-check-sso.html` in dev, with no environment flag.
(`public/silent-check-sso.html` is already copied by the existing `public/**/*` asset glob —
no build change needed.)

**`src/app/core/auth/auth.guard.ts:22`** and **`src/app/core/auth/auth.service.ts:50,54`** —
use Angular's `Location.prepareExternalUrl()`, which prefixes the base href:

```ts
// auth.guard.ts
import { Location } from '@angular/common';

export const authGuard: CanActivateFn = (_route, state) => {
  const keycloak = inject(Keycloak);
  const location = inject(Location);

  if (keycloak.authenticated) {
    return true;
  }

  void keycloak.login({
    redirectUri: `${window.location.origin}${location.prepareExternalUrl(state.url)}`,
  });
  return false;
};
```

Apply the same `inject(Location)` + `prepareExternalUrl` treatment to `AuthService.login()`
and `AuthService.logout()`.

Without this, a `state.url` of `/dashboard` produces a redirect to
`planelyx.com/dashboard` — which nginx doesn't route and Keycloak rejects as an
unregistered redirect URI.

### `src/environments/environment.production.ts`

```ts
export const environment: Environment = {
  production: true,
  apiUrl: 'https://planelyx.com/api',
  keycloak: {
    url: 'https://planelyx.com/auth',
    realm: 'planelyx',
    clientId: 'planelyx-api',
  },
  defaultCurrency: 'BRL',
  defaultLocale: 'pt-BR',
};
```

`apiUrl` also drives the bearer-token interceptor regex in `keycloak.providers.ts:24-27`
(`^<apiUrl>(/.*)?$`), so it must have **no trailing slash**.

Also add `primeUiLicense` here. It currently exists only in `environment.ts` (dev), so
production builds call `providePrimeNG({ license: undefined })`. Check what PrimeNG 22 does
with that before shipping — it may be benign, or it may log/degrade.

These values are **baked at build time**, so the `ui` image is environment-specific: a
staging deploy needs its own build, not just different env vars.

### `planelyx-ui/Dockerfile` (new)

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile
COPY . .
RUN yarn ng build --configuration production --base-href /ui/

FROM nginx:1.27-alpine
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/planelyx-ui/browser /usr/share/nginx/html/ui
```

`angular.json` sets no `outputPath`, so the default `dist/planelyx-ui/browser` applies.
Copying into `/usr/share/nginx/html/ui` means the container serves the same `/ui/` paths the
outer nginx forwards — no path rewriting at either layer.

### `planelyx-ui/docker/nginx.conf` (new — inside the container)

See the file for full contents. Three details are easy to get wrong and were all caught by
running the container:

**Quote regex `location` blocks.** nginx parses `{8}` as a block delimiter, so an unquoted
`location ~* ^/ui/.+\.[0-9a-f]{8}\.js$` fails to load with
`unknown directive "8}\.(?:js|css…"`. Wrap the whole pattern in double quotes.

**Angular's hash format is not a hex digest.** Files are named `main-2QIRCC62.js`,
`chunk-ByAJ-QBR.js`, `primeicons-Y4ZH4LAW.woff2` — an 8-character base64url hash after a
**hyphen**, not lowercase hex after a dot. A `[0-9a-f]{8,}` pattern silently matches
nothing, so every asset quietly loses its cache headers. The working pattern is
`.+-[A-Za-z0-9_-]{8}\.`; matching *exactly* 8 also keeps unhashed files copied from
`public/` (`apple-touch-icon.png`) out of the immutable bucket.

**`absolute_redirect off`.** Otherwise nginx builds the `Location` header from its own
listen port and `return 302 /ui/` sends clients to `http://host:8080/ui/`.

Verified in the built container: `/` → relative `Location: /ui/`; `main-*.js` and
`primeicons-*.woff2` → `max-age=31536000, immutable`; `apple-touch-icon.png` → no immutable
header; `/ui/` → `no-cache`; `/ui/transactions` → 200 via SPA fallback;
`/ui/silent-check-sso.html` → 200; container reports `healthy`.

Add a `.dockerignore`: `node_modules`, `dist`, `.git`, `.angular`.

---

## Phase 3 — `planelyx-api`

### `src/main/resources/application.yaml`

```yaml
server:
  port: ${SERVER_PORT:8080}
  forward-headers-strategy: framework

management:
  endpoints:
    web:
      exposure:
        include: health
  endpoint:
    health:
      probes:
        enabled: true
```

`forward-headers-strategy` makes Spring honour nginx's `X-Forwarded-*`, so generated URLs and
OAuth2 error handling see `https://planelyx.com` rather than `http://127.0.0.1:8082`.

### `src/main/java/com/planelyx/api/security/SecurityConfig.java`

`anyRequest().authenticated()` currently means **`/actuator/health` returns 401**, which
breaks the Compose healthcheck and any uptime probe. Add one matcher alongside the existing
Swagger permits:

```java
.requestMatchers("/actuator/health/**").permitAll()
```

The nginx config in Phase 6 returns 404 for `/actuator` from the outside, so this stays
internal-only.

### CORS

Under path-based routing the browser calls `https://planelyx.com/api` from an
`https://planelyx.com` page — **same origin, so CORS never fires**. This is a real
simplification the path-based layout buys you.

Still set `PLANELYX_CORS_ORIGINS=https://planelyx.com` as a correct default. Note
`setAllowedOrigins` takes exact origins only — no wildcards, scheme and port included.

### `Dockerfile` — harden the `prod` stage

The `build` and `dev` stages are fine as-is; only `prod` was reworked. See the file for full
contents.

`eclipse-temurin:21-jre` is **Ubuntu-based, not Alpine**, so user creation is
`groupadd`/`useradd`, not `addgroup -S`/`adduser -S`. The base image also ships **no curl or
wget**, so the healthcheck needs `curl` installed explicitly — otherwise the probe fails
forever and the container never reports healthy.

`MaxRAMPercentage` matters on a small VPS: the JVM sizes its heap against the container
limit, and the default is usually wrong.

The `HEALTHCHECK` lives in the image rather than in `compose.prod.yaml`, so `docker run`
gets it too. `start-period` is 60s because Flyway runs in-process during startup.

Verified in the built image: process runs as `app` (not root), a single `app.jar` with no
`-plain.jar`, `curl` present, `JAVA_OPTS` set, healthcheck registered.

Two build-hygiene items while you're here:

- `COPY /app/build/libs/*.jar` breaks the moment Gradle also emits `*-plain.jar`. Add
  `tasks.named('jar') { enabled = false }` to `build.gradle` to make the glob unambiguous.
- `spotlessCheck` is wired into `check`, so CI running `./gradlew build` **will fail on
  formatting**. Either run `spotlessApply` before committing, or have CI call
  `./gradlew bootJar -x test` directly.

---

## Phase 4 — CI: build and push to Artifact Registry

One workflow per repo — `.github/workflows/release.yml`, triggered on push to `master` and on
tags.

**Registry:** `southamerica-east1-docker.pkg.dev/<PROJECT_ID>/planelyx/{api,ui,auth}` — São
Paulo keeps pulls fast if the VPS is in Brazil.

**Auth:** a service-account JSON key in `GCP_SA_KEY` — `google-github-actions/auth` with
`credentials_json`, then `gcloud auth configure-docker southamerica-east1-docker.pkg.dev`.
Workload Identity Federation is the stronger option (no long-lived credential in GitHub) and
is worth migrating to later; the only workflow change is swapping `credentials_json` for
`workload_identity_provider` + `service_account`, plus `id-token: write` in `permissions`.

**Tagging:** tag every image with both `${{ github.sha }}` and `latest`. The VPS pins the
SHA; `latest` is for humans.

Per repo:

- **api** — build with `--target prod`. Tests use Testcontainers and need a Docker daemon; the
  Dockerfile already does `-x test`, so a separate `verify` job runs `./gradlew build`
  (which includes `spotlessCheck`) before the image is pushed.
- **ui** — the image is environment-specific (baked env file). `verify` runs `yarn test`
  (37 tests, all passing).
- **auth** — trivial build, plus a `jq empty` guard on the realm JSON. A malformed export
  would otherwise only fail at Keycloak's first boot, which is the worst possible moment.

> ⚠️ `yarn lint` and `yarn format:check` are currently **red on master** — 15 pre-existing
> eslint errors across 11 files and 2 unformatted files, none of them deployment-related.
> They run with `continue-on-error: true` so they do not block releases from day one. Clear
> that backlog and flip them to blocking; a gate that is red on arrival just trains people
> to ignore it.

Also create a **separate read-only service account** for the VPS with
`roles/artifactregistry.reader` and a JSON key. That key goes on the VPS only:

```bash
cat sa-key.json | docker login -u _json_key --password-stdin \
  https://southamerica-east1-docker.pkg.dev
```

---

## Phase 5 — VPS host setup

> 📘 **This section is a summary. `VPS_SETUP.md` is the executable version** — every command
> to take a bare Ubuntu 24.04 image to a running stack, with the ordering traps called out
> (Postgres refusing to start before the Compose network exists, certbot needing a
> certificate-free nginx to bootstrap against, Docker publishing past `ufw`), plus backups,
> rollback and a troubleshooting matrix. Work from that document on the box; keep this one
> for the design rationale.

### Packages and firewall

```
nginx, postgresql-17, certbot, python3-certbot-nginx, docker-ce, docker-compose-plugin
```

```bash
ufw allow 22
ufw allow 80
ufw allow 443
ufw enable
```

Postgres must **not** be reachable from the internet. Only the Docker bridge needs it.

### Postgres

```sql
CREATE ROLE planelyx_app LOGIN PASSWORD '<strong>';
CREATE DATABASE planelyx OWNER planelyx_app;

CREATE ROLE keycloak LOGIN PASSWORD '<different-strong>';
CREATE DATABASE keycloak OWNER keycloak;
```

Separate roles so a compromise of one service doesn't hand over the other's data.

⚠️ The API's multi-tenancy key is `owner_id`, populated from the Keycloak user's `sub` claim
(`src/main/java/com/planelyx/api/security/CurrentUser.java`). **The two databases are one
logical unit** — losing the realm orphans every row in `planelyx`. Back them up together,
restore them together.

Let the containers in:

```conf
# postgresql.conf
listen_addresses = 'localhost,172.20.0.1'
```

```conf
# pg_hba.conf — subnet must match compose.prod.yaml
host  planelyx  planelyx_app  172.20.0.0/16  scram-sha-256
host  keycloak  keycloak      172.20.0.0/16  scram-sha-256
```

Pinning the Compose network to a known subnet (rather than accepting Docker's default
`172.17.x`) is what makes these rules precise instead of a broad `172.16.0.0/12`.

### DNS and TLS

`A` records for `planelyx.com` and `www` → VPS IP, then:

```bash
certbot --nginx -d planelyx.com -d www.planelyx.com
certbot renew --dry-run
```

Certbot installs its own renewal timer.

---

## Phase 6 — nginx (host)

### `/etc/nginx/snippets/planelyx-proxy.conf`

```nginx
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Port  443;
```

### `/etc/nginx/sites-available/planelyx`

Both files live in `planelyx-infra/nginx/`. Install them with:

```bash
sudo cp nginx/planelyx.conf /etc/nginx/sites-available/planelyx
sudo cp nginx/snippets/planelyx-proxy.conf /etc/nginx/snippets/
sudo ln -sf /etc/nginx/sites-available/planelyx /etc/nginx/sites-enabled/planelyx
sudo nginx -t && sudo systemctl reload nginx
```

Both pass `nginx -t` (checked against nginx 1.27 with stub certificates in place). Note the
bootstrap ordering: certbot needs the `:80` server reachable before the `:443` servers can
reference certificates that do not exist yet.

The routing block, for reference:

```nginx
  location = / { return 302 /ui/; }

  location /ui/   { proxy_pass http://127.0.0.1:8081; include .../planelyx-proxy.conf; }
  location /api/  { proxy_pass http://127.0.0.1:8082; include .../planelyx-proxy.conf; }
  location /auth/ { proxy_pass http://127.0.0.1:8083; include .../planelyx-proxy.conf;
                    proxy_buffer_size 128k; proxy_buffers 4 256k; }

  location /actuator    { return 404; }
  location /v3/api-docs { return 404; }
  location /swagger-ui  { return 404; }
```

⚠️ **`proxy_pass` has no trailing slash and no URI part.** That preserves the full request
path — `/api/transactions` arrives at Spring as `/api/transactions`, `/auth/realms/...`
arrives at Keycloak as `/auth/realms/...`. Both services are configured to *own* their
prefix, so nothing is stripped or rewritten anywhere. Adding a trailing slash to any
`proxy_pass` here would silently break all three.

The API's controllers are all mapped under `/api/*` and no `context-path` is set, so `/api/`
needs no special handling. Swagger, however, lives at the root (`/v3/api-docs`,
`/swagger-ui.html`) and is `permitAll` — hence the explicit 404s. If you *want* public API
docs, drop those blocks and add the routes.

---

## Phase 7 — `planelyx-infra` (new repo)

### `compose.prod.yaml`

```yaml
name: planelyx

networks:
  planelyx:
    ipam:
      config:
        - subnet: 172.20.0.0/16   # must match pg_hba.conf

services:
  ui:
    image: ${REGISTRY}/ui:${UI_TAG}
    restart: unless-stopped
    ports: ['127.0.0.1:8081:8080']
    networks: [planelyx]

  api:
    image: ${REGISTRY}/api:${API_TAG}
    restart: unless-stopped
    ports: ['127.0.0.1:8082:8080']
    networks: [planelyx]
    extra_hosts:
      - 'host.docker.internal:host-gateway'
      - 'planelyx.com:host-gateway'
    environment:
      DB_HOST: host.docker.internal
      DB_PORT: '5432'
      POSTGRES_DB: planelyx
      POSTGRES_USER: planelyx_app
      POSTGRES_PASSWORD: ${APP_DB_PASSWORD}
      KEYCLOAK_ISSUER_URI: https://planelyx.com/auth/realms/planelyx
      PLANELYX_CORS_ORIGINS: https://planelyx.com
  # ... see planelyx-infra/compose.prod.yaml for the full file
```

Four things here are load-bearing and easy to get wrong:

**`planelyx.com:host-gateway` on the `api` service.** The API must fetch JWKS from the
*public* issuer URL, because that's the string in the token's `iss` claim. Without this entry
the container would resolve the domain to the public IP and hairpin back out through the
internet. With it, the name resolves to the Docker bridge gateway and hits host nginx
directly on 443 — and TLS still validates, because the SNI hostname is genuinely
`planelyx.com`.

**Build-time Keycloak options are *not* here.** `KC_DB`, `KC_HEALTH_ENABLED`,
`KC_HTTP_RELATIVE_PATH` and `KC_HTTP_MANAGEMENT_RELATIVE_PATH` are baked into the image (see
Phase 1). Setting a differing value here makes `start --optimized` exit 2 on boot.

**`KC_BOOTSTRAP_ADMIN_*`.** Keycloak 26 renamed `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`;
the old names in the local `compose.yaml` are deprecated. These apply on first boot only.

**The API healthcheck lives in the image**, not here, so `docker run` gets it too. Only
`auth` declares one in compose, and its probe greps for `200 OK` — a bare `/dev/tcp`
connection succeeds as soon as the port is open, which would mark Keycloak healthy well
before the realm is actually ready.

### `.env` on the VPS (chmod 600, never committed)

Keys: `REGISTRY`, `API_TAG`, `UI_TAG`, `AUTH_TAG` (pinned SHAs), `APP_DB_PASSWORD`,
`KC_DB_PASSWORD`, `KC_ADMIN`, `KC_ADMIN_PASSWORD`. Ship a `.env.example` with the keys and no
values.

⚠️ Every credential in the current `.env.example` (`planelyx`/`planelyx`, `admin`/`admin`)
must be regenerated. None of them may survive to production.

### `deploy.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
docker compose -f compose.prod.yaml pull
docker compose -f compose.prod.yaml up -d --remove-orphans
docker image prune -f
```

---

## Cutover order

Order matters — Keycloak's first boot is the one that imports the realm, and the API won't
start until the realm exists.

1. DNS `A` records; wait for propagation.
2. VPS: packages, ufw, Docker, Postgres roles/databases, `pg_hba`.
3. nginx site config with an HTTP-only stub → `certbot --nginx` → real certs.
4. `docker login` to Artifact Registry with the read-only SA key.
5. CI green in all three repos; note the image SHAs.
6. `.env` on the VPS with those SHAs; `./deploy.sh`.
7. **Watch `docker compose logs -f auth`** and confirm the realm import ran. If the realm is
   wrong, the cheapest fix *right now* is
   `DROP DATABASE keycloak; CREATE DATABASE keycloak OWNER keycloak;` and restart. Once real
   users exist, that door is closed.
8. Confirm `api` reaches `healthy`. Flyway runs in-process on startup and
   `ddl-auto: validate` will fail loudly on any schema mismatch.
9. Reload nginx and run the verification below.

---

## Verification

### Already verified locally

Before you touch the VPS, note that the whole auth chain has been exercised end to end on a
throwaway Compose stack (postgres + auth + api on one network, with `KC_HOSTNAME` pointed at
a service name so the issuer string was reachable from the API container — the same trick
`planelyx.com:host-gateway` performs in production):

| Check | Result |
|---|---|
| Keycloak boots with `start --optimized`, imports the realm | ready in ~9s |
| Realm served at `/auth/realms/planelyx`; root `/realms/...` | 200 / 404 |
| Discovery `issuer` carries the `/auth` prefix | ✅ matches `KEYCLOAK_ISSUER_URI` |
| Custom `planelyx` login theme renders | ✅ `planelyx.css` served |
| `redirect_uri=…/ui/` accepted, `…/dashboard` rejected | ✅ `Invalid parameter: redirect_uri` |
| Token `iss` claim matches the configured issuer | ✅ |
| `GET /api/bank-accounts` — no token / valid token / garbage token | 401 / **200** / 401 |
| `GET /actuator/health` unauthenticated | 200 `{"status":"UP"}` |
| Flyway applied all 10 migrations, 7 tables owned by `planelyx_app` | ✅ |
| UI container: base href, SPA fallback, cache headers, healthz | ✅ |
| Both nginx configs | `nginx -t` clean |

What that leaves genuinely unproven is everything the VPS supplies: real TLS, host nginx,
host Postgres, the `host-gateway` hairpin, and DNS. Those are what the checks below cover.

### Routing and TLS

```bash
curl -sI https://planelyx.com/                 # 302 -> /ui/
curl -s  https://planelyx.com/ui/ | head       # index.html, <base href="/ui/">
curl -sI https://planelyx.com/actuator/health  # 404 from nginx
curl -sI http://planelyx.com/                  # 301 -> https
```

### The issuer string — the single most important check

```bash
curl -s https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration \
  | jq -r .issuer
# MUST print exactly: https://planelyx.com/auth/realms/planelyx
```

If that string differs by so much as a trailing slash from `KEYCLOAK_ISSUER_URI`, every
authenticated request will 401.

### API rejects and accepts correctly

```bash
curl -sI https://planelyx.com/api/dashboard          # 401

docker compose -f compose.prod.yaml exec api \
  curl -fsS http://127.0.0.1:8080/actuator/health       # {"status":"UP"}
```

Confirm the API can actually reach the issuer through the host-gateway hairpin — this is the
one piece the local test could only simulate:

```bash
docker compose -f compose.prod.yaml exec api \
  curl -fsS https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration \
  | head -c 120
```

A TLS or DNS error here means `extra_hosts` or the certificate is wrong, and every
authenticated request will 401 until it is fixed.

Then a real token via direct access grant (the realm has `directAccessGrantsEnabled`):

```bash
TOKEN=$(curl -s -d 'client_id=planelyx-api' -d 'grant_type=password' \
  -d "username=$U" -d "password=$P" \
  https://planelyx.com/auth/realms/planelyx/protocol/openid-connect/token | jq -r .access_token)

echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .iss   # confirm issuer
curl -s -H "Authorization: Bearer $TOKEN" https://planelyx.com/api/dashboard
```

### Browser end-to-end — the part only a real browser exercises

1. Open `https://planelyx.com/ui/` → redirected to Keycloak at
   `/auth/realms/planelyx/protocol/openid-connect/auth`.
2. Register a new user → lands back on `/ui/...`, **not** `/...`. (This is the
   `prepareExternalUrl` fix.)
3. DevTools → Network: `silent-check-sso.html` loads from `/ui/silent-check-sso.html` with no
   404, and no CSP/frame errors.
4. Confirm the custom `planelyx` login theme renders. If it doesn't, the theme wasn't baked
   into the image.
5. Deep-link straight to an inner route — e.g. `https://planelyx.com/ui/transactions` — in
   a fresh tab. SPA fallback should serve it after login.
6. Reload while authenticated → session survives (silent SSO working).
7. Log out → returns to `/ui/`.
8. Idle 30 min → auto-logout fires (`withAutoRefreshToken`).

### Persistence

`docker compose down && ./deploy.sh`, then confirm your user and data are still there. Both
databases live on the host, so nothing should be lost.

---

## Follow-ups worth scheduling

- **Backups.** `pg_dump` both `planelyx` and `keycloak` **in the same job**, off-box. Test a
  restore. Because `owner_id` ties app rows to Keycloak `sub` values, a partial restore is a
  data-loss event.
- **Realm-change workflow.** Since `--import-realm` won't re-import, decide now: admin console
  by hand, or a `kcadm.sh` bootstrap script in `planelyx-auth`. Otherwise the export drifts
  from reality within weeks.
- **The duplicated Keycloak theme.** `planelyx-auth/themes/` is currently a *copy* of
  `planelyx-api/docker/keycloak/themes/`, so local dev keeps working unchanged. Two copies
  will drift — collapse them once local `compose.yaml` points at the built `auth` image.
- **The eslint / prettier backlog** (15 errors, 2 unformatted files) so the UI release gate
  can become blocking instead of `continue-on-error`.
- **Rename the git remotes** from `fintrack-*` to `planelyx-*`, if you want that finished.
- **Zero-downtime deploys** are out of scope: `up -d` restarts the API in place and Flyway
  runs on startup, so expect a few seconds of 502. Fine for now; revisit when it stops being
  fine.
