# planelyx-infra

Planelyx is a personal-finance application. It is split across four repositories — a Spring
Boot API, an Angular SPA, a statement ingestion service, and this one, which is the deployment
layer. Everything of Planelyx's that lives on the VPS is here: the production Compose stack and
the host nginx config. It builds nothing, and the VPS holds no checkout of it — the deploy
workflow ships `compose.prod.yaml` to the box from the commit being deployed.

The whole system runs on a single VPS. GitHub Actions builds each service and pushes it to
GCP Artifact Registry; the VPS pulls those images into a Compose stack that sits behind a
host-installed nginx, with the services routed by path under one hostname.

```
planelyx-api    Spring Boot, JWT resource server        ->  /api/
planelyx-ui     Angular SPA served by nginx             ->  /ui/
planelyx-ocr    Fastify, card-statement ingestion       ->  /ocr/
planelyx-infra  this repo — Compose, nginx, deploy workflow
```

Authentication is **not** in this repo. Keycloak is shared across products and lives in
`auth`, as its own Compose stack on the same box. It still serves Planelyx at
`https://planelyx.com/auth` — the issuer has not changed — but this repo neither builds nor
deploys it, and `nginx/planelyx.conf` only proxies to it.

## Start here

Two documents carry the real content:

- **`VPS_SETUP.md`** — building the host from a bare Ubuntu install: users, SSH hardening,
  firewall, Postgres roles and `pg_hba.conf`, DNS, TLS.
- **`DEPLOYMENT.md`** — the deployment runbook: the issuer-string constraint the whole auth
  setup turns on, CI wiring, cutover order, and verification.
- **`auth/VPS_SETUP.md`** — everything Keycloak: its database, its vhost, the
  Host-header pinning, and its own secrets.

Both are written as runbooks rather than overviews — they record the failure modes that cost
real time, not just the happy path.

## Layout

```
compose.prod.yaml            ui / api / ocr, all bound to 127.0.0.1; shipped to the VPS per deploy
.github/workflows/deploy.yml the whole deploy: ships compose, renders .env, pulls, up -d, verifies
.env.example                 reference only — the workflow renders the real .env on every run
nginx/planelyx.conf          -> /etc/nginx/sites-available/planelyx
nginx/snippets/planelyx-proxy.conf -> /etc/nginx/snippets/
```

## Topology

nginx and Postgres are installed on the host. Every container publishes only on `127.0.0.1`,
so the sole route in from the internet is host nginx on 443.

```
                    :443  host nginx
                            |
        /ui/  -> 127.0.0.1:8081   ui        (nginx + static Angular)
        /api/ -> 127.0.0.1:8082   api       (Spring Boot)
        /ocr/ -> 127.0.0.1:8084   ocr       (Fastify, Node 24)
        /auth/-> 127.0.0.1:8085   keycloak  (the `auth` stack, auth)
        /internal/keycloak/ -> 127.0.0.1:8082   the `auth` stack's subnet only
                            |
                    host postgres :5432
                    databases: planelyx, planelyx_ocr   (keycloak belongs to the auth stack)
```

The two stacks are separate Compose projects on separate networks, so they reach each other
through host nginx rather than by container name — the `extra_hosts` host-gateway entries on
`api` and `ocr` are what make the public URLs resolve from inside a container.

`ocr` is the only service with state outside Postgres: two Docker volumes, one holding the
uploaded statements encrypted at rest and one holding the key that decrypts them. `down -v`
destroys both, and nothing can regenerate the key. See `VPS_SETUP.md` §15.

## Deploying

Normally through the **deploy** action in this repo (Actions → deploy → Run workflow). Paste
the commit SHA of each service you want to release — the service's release run prints it as
`Deploy with API_TAG=<sha>`. **A service you leave blank is not touched at all**: the workflow
reads its current tag off the VPS and carries it forward, so its container is left running
exactly as it was.

Keycloak is not one of them: it is deployed from `auth` by that repo's own
workflow, against its own `~/auth` directory on the same box — and that one needs no SHA and no
button, because a push to its `master` builds and deploys itself.

Rollback is the same workflow with the previous SHA. The previous tags are in the prior run's
job summary, and in `.env.prev` on the VPS.

The workflow renders `.env` from this repo's secrets on every run, so **GitHub is the source
of truth for the DB credentials** — a value hand-edited on the box is reverted on
the next deploy. It refuses to deploy if the two disagree, unless you tell it you are
rotating.

There is no deploy script on the VPS, and no checkout of this repo to keep current. The
workflow ships `compose.prod.yaml` from the commit it is deploying, so the running topology
cannot lag behind master and there is no `git pull` to forget.

The break-glass path is Compose directly. The last successful deploy leaves both
`compose.prod.yaml` and `.env` in `~/planelyx-infra`, so on the box:

```bash
# once, on the VPS
cat sa-key.json | docker login -u _json_key --password-stdin \
  https://southamerica-east1-docker.pkg.dev

cd ~/planelyx-infra
docker compose -f compose.prod.yaml pull
docker compose -f compose.prod.yaml up -d --wait --wait-timeout 300 --remove-orphans

# one service only — --no-deps keeps it from restarting the others
docker compose -f compose.prod.yaml up -d --wait --wait-timeout 300 --no-deps api

# ocr does not migrate at startup the way api does; the deploy workflow runs this for you,
# and driving Compose by hand does not
docker compose -f compose.prod.yaml run --rm ocr node dist/storage/migrate.js
```

The tags come from `.env`. Editing them by hand works, but the next workflow run reconciles
the file against the repo secrets — and if you also edited `compose.prod.yaml` on the box,
that edit is overwritten by the shipped copy. Change it here and deploy.

## Three things that will bite you

**The issuer string.** The API validates JWTs by issuer alone, so
`https://planelyx.com/auth/realms/planelyx` has to be identical from the browser and
from inside the API container. That is what `KC_HTTP_RELATIVE_PATH` in the auth image and the
`planelyx.com:host-gateway` entries on `api` and `ocr` are for. Verify with:

```bash
curl -s https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration \
  | jq -r .issuer
```

**The `Host` header on `/auth/`.** Keycloak runs with no fixed hostname so that one server can
serve a realm per product, each on its product's own domain — which means the `Host` it
receives *becomes* the issuer, and the base URL of every password-reset link. The `/auth/`
location must include `snippets/keycloak-proxy.conf`, which sets `Host` and
`X-Forwarded-Host` to `$server_name`, and never the plain proxy snippet. Verify with:

```bash
curl -s -H 'Host: forged.example' \
  https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration | jq -r .issuer
```

Anything mentioning `forged.example` means the pinning is not in place. See
`auth/VPS_SETUP.md` §4.

**The Compose subnet and `pg_hba.conf` must match.** `compose.prod.yaml` pins
`172.20.0.0/16`; the host `pg_hba.conf` rules name the same range. Change one and Postgres
starts refusing the containers. The auth stack pins `172.21.0.0/16` for the same reason, and
`nginx/planelyx.conf` names that range too — it is what restricts `/internal/keycloak/` to
callbacks coming from Keycloak rather than from the internet.
