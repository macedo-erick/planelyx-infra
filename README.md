# planelyx-infra

Planelyx is a personal-finance application. It is split across four repositories — a Spring
Boot API, an Angular SPA, a Keycloak image carrying the realm and login theme, and this one,
which is the deployment layer. Everything that lives on the VPS is here: the production
Compose stack, the host nginx config, and the deploy script. Clone this to the VPS; it builds
nothing.

The whole system runs on a single VPS. GitHub Actions builds each service and pushes it to
GCP Artifact Registry; the VPS pulls those images into a Compose stack that sits behind a
host-installed nginx, with all three services routed by path under one hostname.

```
planelyx-api    Spring Boot, JWT resource server        ->  /api/
planelyx-ui     Angular SPA served by nginx             ->  /ui/
planelyx-auth   Keycloak image (realm + login theme)    ->  /auth/
planelyx-infra  this repo — Compose, nginx, deploy.sh
```

## Start here

Two documents carry the real content:

- **`VPS_SETUP.md`** — building the host from a bare Ubuntu install: users, SSH hardening,
  firewall, Postgres roles and `pg_hba.conf`, DNS, TLS.
- **`DEPLOYMENT.md`** — the deployment runbook: the issuer-string constraint the whole auth
  setup turns on, CI wiring, cutover order, and verification.

Both are written as runbooks rather than overviews — they record the failure modes that cost
real time, not just the happy path.

## Layout

```
compose.prod.yaml            ui / api / auth, all bound to 127.0.0.1
deploy.sh                    pull + up -d + health gate + prune; takes an optional service list
.github/workflows/deploy.yml manual deploy over SSH; renders .env from repo secrets
.env.example                 copy to .env, chmod 600 (workflow-managed after the first deploy)
nginx/planelyx.conf          -> /etc/nginx/sites-available/planelyx
nginx/snippets/planelyx-proxy.conf -> /etc/nginx/snippets/
```

## Topology

nginx and Postgres are installed on the host. The three containers publish only on
`127.0.0.1`, so the sole route in from the internet is host nginx on 443.

```
                    :443  host nginx
                            |
        /ui/  -> 127.0.0.1:8081   ui        (nginx + static Angular)
        /api/ -> 127.0.0.1:8082   api       (Spring Boot)
        /auth/-> 127.0.0.1:8083   auth      (Keycloak)
                            |
                    host postgres :5432
                    databases: planelyx, keycloak
```

## Deploying

Normally through the **deploy** action in this repo (Actions → deploy → Run workflow). Paste
the commit SHA of each service you want to release — the service's release run prints it as
`Deploy with API_TAG=<sha>`. **A service you leave blank is not touched at all**: the workflow
reads its current tag off the VPS and carries it forward, so its container is left running
exactly as it was.

Rollback is the same workflow with the previous SHA. The previous tags are in the prior run's
job summary, and in `.env.prev` on the VPS.

The workflow renders `.env` from this repo's secrets on every run, so **GitHub is the source
of truth for the DB and Keycloak credentials** — a value hand-edited on the box is reverted on
the next deploy. It refuses to deploy if the two disagree, unless you tell it you are
rotating.

`deploy.sh` remains the manual and break-glass path, and now takes an optional service list:

```bash
# once, on the VPS
cat sa-key.json | docker login -u _json_key --password-stdin \
  https://southamerica-east1-docker.pkg.dev

./deploy.sh              # whole stack
./deploy.sh api          # only the api container; ui and auth keep running
```

Either way the tags come from `.env`. Editing them by hand and running `./deploy.sh` still
works — just expect the next workflow run to reconcile the file against the repo secrets.

## Two things that will bite you

**The issuer string.** The API validates JWTs by issuer alone, so
`https://planelyx.com/auth/realms/planelyx` has to be identical from the browser and
from inside the API container. That is what `KC_HTTP_RELATIVE_PATH`, `KC_HOSTNAME`, and the
`planelyx.com:host-gateway` entry on the `api` service are all for. Verify with:

```bash
curl -s https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration \
  | jq -r .issuer
```

**The Compose subnet and `pg_hba.conf` must match.** `compose.prod.yaml` pins
`172.20.0.0/16`; the host `pg_hba.conf` rules name the same range. Change one and Postgres
starts refusing the containers.
