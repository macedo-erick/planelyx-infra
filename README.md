# planelyx-infra

Everything that lives on the VPS: the production Compose stack, the host nginx config, and
the deploy script. Clone this to the VPS; it builds nothing.

The full runbook — VPS packages, Postgres roles, DNS, TLS, cutover order, verification —
is `DEPLOYMENT.md` in `planelyx-api`.

## Layout

```
compose.prod.yaml            ui / api / auth, all bound to 127.0.0.1
deploy.sh                    pull + up -d + prune
.env.example                 copy to .env, chmod 600
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

```bash
# once
cat sa-key.json | docker login -u _json_key --password-stdin \
  https://southamerica-east1-docker.pkg.dev

# every release: bump the *_TAG values in .env to the new commit SHAs, then
./deploy.sh
```

Rollback is editing those tags back and re-running `./deploy.sh`.

## Two things that will bite you

**The issuer string.** The API validates JWTs by issuer alone, so
`https://planelyx.com.br/auth/realms/planelyx` has to be identical from the browser and
from inside the API container. That is what `KC_HTTP_RELATIVE_PATH`, `KC_HOSTNAME`, and the
`planelyx.com.br:host-gateway` entry on the `api` service are all for. Verify with:

```bash
curl -s https://planelyx.com.br/auth/realms/planelyx/.well-known/openid-configuration \
  | jq -r .issuer
```

**The Compose subnet and `pg_hba.conf` must match.** `compose.prod.yaml` pins
`172.20.0.0/16`; the host `pg_hba.conf` rules name the same range. Change one and Postgres
starts refusing the containers.
