# Planelyx — VPS Setup Guide

Build the production host for `planelyx.com` from a bare OS image, step by step.

This document is the **how**. `DEPLOYMENT.md` is the **why** — it explains the architecture,
what each phase of the application build had to change and the reasoning behind the
path-based routing layout. Read that first if you want the design rationale; read this when
you have a fresh VPS in front of you and want to end up with a working stack.

Every command assumes **Ubuntu 24.04 LTS**. Adapt package names for other distributions;
the ordering and the traps are the same everywhere.

**Conventions used below**

- `$` prefixed lines run as your non-root user.
- `PROJECT_ID` means your GCP project ID. Substitute it; nothing here resolves it for you.
- Anything in `<angle brackets>` is a value you generate.

---

## Table of contents

1. [What you are building](#1-what-you-are-building)
2. [Prerequisites](#2-prerequisites)
3. [Server hardening](#3-server-hardening)
4. [Firewall](#4-firewall)
5. [Package installation](#5-package-installation)
6. [Docker post-install](#6-docker-post-install)
7. [PostgreSQL](#7-postgresql)
8. [DNS](#8-dns)
9. [nginx](#9-nginx)
10. [TLS with Let's Encrypt](#10-tls-with-lets-encrypt)
11. [Artifact Registry access](#11-artifact-registry-access)
12. [Bringing up the stack](#12-bringing-up-the-stack)
13. [The deploy workflow](#13-the-deploy-workflow) — SSH key and repo secrets for CD
14. [Verification](#14-verification)
15. [Operations](#15-operations) — logs, SQL client access, backups, deploys, rollback
16. [Troubleshooting](#16-troubleshooting)

---

## 1. What you are building

One VPS, one hostname, six moving parts. Four of them are containers; two more (nginx and
PostgreSQL) are installed directly on the host.

**Keycloak is one of the four but is not deployed from this repo.** It is shared across products
and lives in `auth`, as its own Compose project (`~/auth`, network
`172.21.0.0/16`, port 8085) with a runbook of its own. It still serves Planelyx at
`https://planelyx.com/auth` and the issuer is unchanged, so it appears below wherever this host
depends on it — and everything about building, deploying or configuring it is in
`auth/VPS_SETUP.md`.

```
                                  internet
                                     │
                                     │ :80 → 301 → :443
                                     ▼
                           ┌───────────────────┐
                           │  nginx  (host)    │   TLS terminates here
                           └─────────┬─────────┘
        ┌────────────────────┬───────┴────────────┬────────────────────┐
        │                    │                    │                    │
   /ui/ │              /api/ │               /ocr/│              /auth/│
        ▼                    ▼                    ▼                    ▼
  127.0.0.1:8081       127.0.0.1:8082       127.0.0.1:8084       127.0.0.1:8085
  ┌──────────┐         ┌──────────┐         ┌──────────┐         ┌──────────┐
  │    ui    │         │   api    │         │   ocr    │         │ keycloak │
  │  nginx + │         │  Spring  │         │  Fastify │         │   26.0   │
  │  Angular │         │   Boot   │         │  Node 24 │         │          │
  └──────────┘         └────┬─────┘         └────┬─────┘         └────┬─────┘
                            │                    │                    │
                    project `planelyx` 172.20.0.0/16          project `auth`
                            └────────────────────┤            172.21.0.0/16
                                                 │                    │
                                                 ▼                    ▼
                                      ┌────────────────────────────────────┐
                                      │        PostgreSQL (host)           │
                                      │  db: planelyx      db: keycloak    │
                                      │  db: planelyx_ocr                  │
                                      └────────────────────────────────────┘
```

The two Compose projects are separate networks, so `api` and `ocr` reach Keycloak the same way
the browser does — through host nginx, via the `extra_hosts` host-gateway entries. There is no
container-to-container path between them.

`ocr` is the only container holding state of its own: the uploaded statements, encrypted, in a
Docker volume — plus the key that decrypts them in a second volume. Everything under
[§15](#15-operations) about backing up the two databases together applies to those volumes too,
and the key is the one item on this box that no reprocessing can regenerate.

Routing, for reference:

```
https://planelyx.com/       →  302 to /ui/
https://planelyx.com/ui/    →  Angular SPA
https://planelyx.com/api/   →  Spring Boot
https://planelyx.com/auth/  →  Keycloak            (the `auth` stack)
https://planelyx.com/ocr/   →  statement ingestion (Fastify)

https://planelyx.com/internal/keycloak/  →  the API, from the auth stack's subnet only
https://planelyx.com/auth/admin/         →  404; the console is on auth.macedosoftware.com
```

### Why nginx and Postgres live on the host

**nginx** owns the certificates. Certbot's nginx plugin edits the host config directly and
reloads the service, so keeping nginx on the host makes TLS renewal a solved problem instead
of a volume-mounting exercise. It also means a container restart never drops TLS.

**Postgres** holds the only state that matters. Keeping it outside Compose means
`docker compose down` — including a fat-fingered `-v` — cannot touch your data. Backups,
upgrades and tuning are all ordinary `apt` and `systemd` work.

Everything else is stateless and disposable, which is exactly what you want from a container.

### Why every container binds `127.0.0.1`

`compose.prod.yaml` publishes ports as `'127.0.0.1:8081:8080'`, not `'8081:8080'`. The only
route into any container is through host nginx on 443. See [§4](#4-firewall) for why this
matters more than the firewall does.

---

## 2. Prerequisites

### The box

| Resource | Minimum | Comfortable |
|---|---|---|
| RAM | 2 GB + 2 GB swap | 4 GB |
| vCPU | 2 | 2 |
| Disk | 25 GB SSD | 40 GB |

RAM is the binding constraint, and it is worth being explicit about where it goes:

- **Keycloak** is the hungriest. A JVM app with a large classpath; budget ~512 MB resident
  once warm.
- **api** sizes its heap from the container limit via `-XX:MaxRAMPercentage=75` (set in the
  `prod` stage of `planelyx-api/Dockerfile`). With no container memory limit set, "the
  container limit" *is* the host's RAM — so on a 2 GB box the JVM will happily aim for
  1.5 GB of heap. Set a limit, or accept the risk.
- **Postgres** defaults to `shared_buffers = 128 MB`, which is fine at this scale.
- **ui** is nginx serving static files. Negligible.

On a 2 GB box, add a swapfile ([§3](#3-server-hardening)) and consider adding memory limits
to `compose.prod.yaml`:

```yaml
  api:
    mem_limit: 768m
  auth:
    mem_limit: 640m
```

Swap is not a substitute for RAM here — it is a cushion that turns an OOM-kill into a slow
request.

### Off the box

- **A registered domain** — `planelyx.com` — with access to its DNS records.
- **A GCP project** with an Artifact Registry Docker repository. All four `release.yml`
  workflows push to region `southamerica-east1`, repository `planelyx`, so the
  full image paths are:
  ```
  southamerica-east1-docker.pkg.dev/PROJECT_ID/planelyx/api
  southamerica-east1-docker.pkg.dev/PROJECT_ID/planelyx/ui
  southamerica-east1-docker.pkg.dev/PROJECT_ID/planelyx/auth
  southamerica-east1-docker.pkg.dev/PROJECT_ID/planelyx/ocr
  ```
  São Paulo keeps pulls fast if the VPS is in Brazil.
- **Two service accounts**, not one:

  | Account | Role | Key lives in |
  |---|---|---|
  | CI pusher | `roles/artifactregistry.writer` | GitHub secret `GCP_SA_KEY` in all four repos |
  | VPS puller | `roles/artifactregistry.reader` | the VPS only |

  Do not reuse the CI key on the VPS. A read-only key on a box exposed to the internet
  cannot be used to poison your image registry.
- **Green CI** in `planelyx-api`, `planelyx-ui` and `planelyx-auth`, with the image SHAs
  noted down. You will pin them in `.env`.

---

## 3. Server hardening

Do this before anything is listening. Ten minutes now, and the box stops being interesting
to the internet's background noise.

### A non-root user

```bash
# as root, on first login
adduser deploy
usermod -aG sudo deploy
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy
```

The `rsync` line copies the root account's `authorized_keys` across, so you can log in as
`deploy` with the same key before you lock root out. Open a **second terminal** and confirm
`ssh deploy@<ip>` works before continuing — if you get this wrong with only one session
open, you have locked yourself out of your own server.

### SSH

Edit `/etc/ssh/sshd_config`:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
```

```bash
$ sudo systemctl restart ssh
```

On Ubuntu 24.04 SSH is socket-activated; if `restart ssh` looks like it did nothing, use
`sudo systemctl restart ssh.socket` as well.

> Ubuntu 24.04 ships drop-in files under `/etc/ssh/sshd_config.d/` that are read **before**
> the main file and win on first-match. A cloud image often drops
> `PasswordAuthentication yes` in there, silently overriding your edit. Check with
> `sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin'` — that prints the
> *effective* configuration, which is the only thing that counts.

### Automatic security updates

```bash
$ sudo apt-get update && sudo apt-get install -y unattended-upgrades
$ sudo dpkg-reconfigure --priority=low unattended-upgrades
```

This patches the OS, not your containers. Image updates are your job ([§15](#15-operations)).

### Time

```bash
$ sudo timedatectl set-timezone America/Sao_Paulo
$ timedatectl status          # confirm "System clock synchronized: yes"
```

A clock more than a few minutes off will make JWT `exp`/`nbf` validation fail in ways that
look like random 401s. Do not skip this.

### Swap

Skip if your provider already configured swap (`swapon --show` prints nothing if not).

```bash
$ sudo fallocate -l 2G /swapfile
$ sudo chmod 600 /swapfile
$ sudo mkswap /swapfile
$ sudo swapon /swapfile
$ echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
$ sudo sysctl -w vm.swappiness=10
$ echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
```

`swappiness=10` tells the kernel to prefer reclaiming page cache over swapping out live JVM
heap — swapping a JVM heap is catastrophically slow.

---

## 4. Firewall

```bash
$ sudo ufw default deny incoming
$ sudo ufw default allow outgoing
$ sudo ufw allow 22/tcp
$ sudo ufw allow 80/tcp
$ sudo ufw allow 443/tcp
$ sudo ufw enable
$ sudo ufw status verbose
```

Three ports open to the world. The four container ports (8081–8084) are deliberately
absent — they bind loopback and are reached only through nginx.

### ⚠️ Postgres needs one more rule, or nothing will start

The containers connect **out** to the host's Postgres via `host.docker.internal`, which
resolves to the bridge gateway `172.20.0.1`. That traffic arrives on the bridge interface and
is evaluated by the `INPUT` chain — where `default deny incoming` drops it. Add the rule now:

```bash
$ sudo ufw allow from 172.20.0.0/16 to any port 5432 proto tcp \
    comment 'planelyx containers -> host postgres'
$ sudo ufw reload
```

Scoped to the Compose subnet, so 5432 stays closed to everything else. Skip this and `api`
fails to start with a **timeout** — never a refusal, never an authentication error, because
the packets are silently discarded rather than answered. See [§16](#16-troubleshooting) for
how to tell those apart, and keep the rule's subnet in step with the `ipam` block in
`compose.prod.yaml`.

**This rule covers only this stack.** The auth stack's containers come from `172.21.0.0/16`
and need a rule of their own; `auth/VPS_SETUP.md` §2 owns it. Every new Compose project on
this box needs one, and the failure mode is always this same silent timeout.

This rule is **load-bearing, not defence in depth**: [§7](#7-postgresql) binds Postgres to
`'*'` deliberately, so ufw and `pg_hba.conf` are what keep the database off the internet.
Do not delete it as redundant. Verify from off-box after setup:

```bash
$ nmap -Pn -p 5432 <VPS public IP>      # must be filtered or closed
```

### ⚠️ The Docker/ufw trap — and why it cuts both ways

`ufw` writes its rules into the iptables `INPUT` chain. Docker publishes ports by writing
into the `DOCKER` chain off `FORWARD`, plus DNAT rules in the `nat` table — and that DNAT
happens **before** `INPUT` is consulted. The practical consequence is famous and
counter-intuitive:

> A container published as `ports: ['8081:8080']` is reachable from the internet even
> though `ufw status` says port 8081 is denied.

People discover this the hard way, usually with an unauthenticated database.

**This stack is not vulnerable, and the reason is specific:** every port in
`compose.prod.yaml` is published as `127.0.0.1:<port>:8080`. Docker's DNAT rule then binds
only the loopback interface, so there is no public path to it regardless of what iptables
would have done. The firewall is defence in depth here, not the primary control.

Which means: **if you ever remove a `127.0.0.1:` prefix from a `ports:` entry, you have
published that service to the internet.** `ufw` will not save you. If you need to expose
something else later, do it through an nginx `location` block, not by republishing a port.

**The trap is directional, and that is the part people miss.** The deciding question for any
packet is *is the final destination this host, or a container?* — because that determines
which chain it traverses, and `ufw` only has rules in one of them:

| Direction | Destination after routing | Chain | `ufw` filters it? |
|---|---|---|---|
| internet → published container port | container `172.20.0.x` — forward it | `nat` DNAT + `DOCKER` off `FORWARD` | **No** — bypassed |
| container → host service on `172.20.0.1` | the host itself — deliver locally | `INPUT` | **Yes** — dropped unless allowed |

`default deny incoming` means incoming to *this machine* from **any** interface, not just the
public one. The Docker bridge feels like internal traffic, so it is easy to assume it is
exempt. It is not: to the kernel `172.20.0.1:5432` is an ordinary local socket and a
container is an ordinary host on an attached network.

So the same firewall that fails to protect a carelessly published port will happily block
your containers from reaching Postgres.

**This is a direct consequence of running Postgres on the host** ([§1](#1-what-you-are-building)).
Had it been a container in this same stack, container-to-container traffic would stay on the
bridge, never enter `INPUT`, and no rule would be needed. The rule is the cost of keeping
your data outside Compose's reach — and a fair one, since the same `INPUT` filtering is what
lets you open 5432 to `172.20.0.0/16` and nothing else.

Verify the bindings are what you think they are once the stack is up:

```bash
$ sudo ss -tlnp | grep -E '808[123]'
# every line must read 127.0.0.1:808x — never 0.0.0.0:808x or *:808x
```

---

## 5. Package installation

### Base

```bash
$ sudo apt-get update
$ sudo apt-get install -y ca-certificates curl gnupg lsb-release jq unzip
```

`jq` is used throughout [§14](#14-verification); install it now so verification is not
blocked on it.

### Docker CE (official repository)

Do not use Ubuntu's `docker.io` package — it lags, and the Compose v2 plugin is packaged
separately from it.

```bash
$ sudo install -m 0755 -d /etc/apt/keyrings
$ sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
$ sudo chmod a+r /etc/apt/keyrings/docker.asc

$ echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

$ sudo apt-get update
$ sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
```

### PostgreSQL 17 (PGDG repository)

Ubuntu 24.04 ships PostgreSQL 16. The stack is developed against 17, so pull from PGDG.

```bash
$ sudo install -d /usr/share/postgresql-common/pgdg
$ sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc

$ echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list

$ sudo apt-get update
$ sudo apt-get install -y postgresql-17
```

Confirm you got the version you meant, not a leftover 16 cluster:

```bash
$ pg_lsclusters
# Ver Cluster Port Status Owner    Data directory              Log file
# 17  main    5432 online postgres /var/lib/postgresql/17/main ...
```

If both 16 and 17 appear, 16 will have taken port 5432 and 17 will be on 5433. Drop the
one you do not want (`sudo pg_dropcluster --stop 16 main`) before continuing, or every
connection string below points at the wrong server.

### nginx and certbot

```bash
$ sudo apt-get install -y nginx certbot python3-certbot-nginx
```

---

## 6. Docker post-install

### Run docker without sudo

```bash
$ sudo usermod -aG docker $USER
$ newgrp docker          # or log out and back in
$ docker run --rm hello-world
```

Adding a user to the `docker` group is equivalent to giving them root — the daemon socket
will happily bind-mount `/` into a privileged container. That is an accepted trade-off on a
single-admin box; it is not one to extend to additional users casually.

### Daemon configuration

```bash
$ sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
$ sudo systemctl restart docker
```

- **Log rotation** is the important one. Unrotated container logs are the single most common
  cause of a VPS filling its disk at 3 a.m. `compose.prod.yaml` already sets these limits
  per service; the daemon default catches anything you run by hand.
- **`live-restore`** keeps containers running through a Docker daemon restart, so an
  `apt upgrade` of `docker-ce` no longer means downtime.

```bash
$ sudo systemctl enable docker
```

---

## 7. PostgreSQL

One server, three databases, three roles. This is the step with the most ways to go subtly
wrong, so it is worth going slowly.

### Roles and databases

```bash
$ sudo -u postgres psql
```

```sql
CREATE ROLE planelyx_app LOGIN PASSWORD '<app-password>';
CREATE DATABASE planelyx OWNER planelyx_app;

CREATE ROLE keycloak LOGIN PASSWORD '<kc-password>';
CREATE DATABASE keycloak OWNER keycloak;
-- keycloak's role and database belong to the auth stack; see auth/VPS_SETUP.md §2

CREATE ROLE planelyx_ocr LOGIN PASSWORD '<ocr-password>';
CREATE DATABASE planelyx_ocr OWNER planelyx_ocr;
\q
```

Generate all three passwords properly and store them where you will find them again:

```bash
$ openssl rand -base64 32
```

**Three roles, not one.** The three sets of tables have completely different threat profiles:
Keycloak's `credential` table holds password hashes, and `planelyx-ocr` is the only service that
accepts uploaded files from the internet. If any one of them is compromised, its database
credential must not be a path to the other two.

> **`planelyx_ocr` has to exist before the first deploy of that service.** It can create its own
> database when it is missing, but only from a role permitted to `CREATE DATABASE` — which this
> one deliberately is not. Provisioned here, that branch is never reached. Skip it and the deploy
> fails in its migration step with a missing-database error reported against drizzle's
> `CREATE SCHEMA`, which points at a schema rather than at the database that is not there.

PostgreSQL 14+ defaults `password_encryption` to `scram-sha-256`, so the roles above are
already SCRAM. Verify rather than assume:

```sql
SELECT rolname, LEFT(rolpassword, 14) FROM pg_authid
 WHERE rolname IN ('planelyx_app','keycloak','planelyx_ocr');
-- all three must start with SCRAM-SHA-256
```

### ⚠️ The three databases are one logical unit

The API's multi-tenancy key is `owner_id`, populated from the Keycloak user's `sub` claim
(`src/main/java/com/planelyx/api/security/CurrentUser.java`). Every row in `planelyx` is
meaningless without the matching user in `keycloak`. `planelyx_ocr` keys its documents the same
way, and its confirmed rows carry the id of the ledger transaction they produced in `planelyx`.

Back them up **in the same job**, restore them **together**, and never restore one from a
different point in time than the other. A partial restore is a data-loss event that will
present as users logging in to an empty account. See [§15](#15-operations).

Restoring `planelyx_ocr` older than `planelyx` has a failure of its own: a document it believes
is unconfirmed has in fact already been written to the ledger, so confirming it again files every
transaction on it twice. There is no constraint that stops this — the duplicate is a legitimate
row as far as the API is concerned.

### Letting the containers connect

The containers reach Postgres through `host.docker.internal`, which `extra_hosts` maps to
`host-gateway` — the Docker bridge gateway address. On the Compose network pinned to
`172.20.0.0/16`, that gateway is `172.20.0.1`.

Two files need changing. `/etc/postgresql/17/main/postgresql.conf`:

```conf
listen_addresses = '*'
```

`/etc/postgresql/17/main/pg_hba.conf` — append at the end:

```conf
# Compose containers. Each subnet must match the ipam block in that stack's compose file.
host  planelyx      planelyx_app  172.20.0.0/16  scram-sha-256
host  planelyx_ocr  planelyx_ocr  172.20.0.0/16  scram-sha-256
host  keycloak      keycloak      172.21.0.0/16  scram-sha-256
```

Pinning the Compose subnet (rather than accepting whatever `172.17.x` Docker hands out) is
precisely what lets these rules be narrow instead of a shrug-shaped `172.16.0.0/12`.

**The `keycloak` line names a different subnet on purpose.** It is a separate Compose project
with a network of its own, and a rule naming `172.20.0.0/16` would leave Keycloak unable to
reach its database — as an immediate `FATAL: no pg_hba.conf entry for host "172.21.0.2"`. That
is the *easy* failure: it names the address that was refused. The silent one is the matching
`ufw` rule ([§4](#4-firewall)), which drops the packets so nothing is logged here at all. `auth/VPS_SETUP.md` §2
owns that rule; it is here so this file is not misleading.

**`pg_hba.conf` is first-match-wins, top to bottom.** Appending is safe here because
Ubuntu's default file contains nothing matching `172.20.x`. If you have added a broad
`reject` rule of your own, these lines must go above it.

Apply it:

```bash
$ sudo systemctl restart postgresql
$ sudo ss -tlnp | grep 5432
```

Expected — one IPv4 and one IPv6 listener:

```
LISTEN 0 200 0.0.0.0:5432 0.0.0.0:*  users:(("postgres",pid=50034,fd=6))
LISTEN 0 200    [::]:5432    [::]:*  users:(("postgres",pid=50034,fd=7))
```

Only `127.0.0.1:5432` means the edit did not take: either it was reloaded rather than
restarted, or you edited a different cluster's config file (see
`sudo -u postgres psql -c 'SHOW config_file;'`).

> **Reload or restart?** `pg_hba.conf` changes take effect on `sudo systemctl reload
> postgresql`. `listen_addresses` is a postmaster-level setting and needs a **restart**.
> Reloading after changing it looks successful and changes nothing — a genuinely confusing
> failure mode, because `SHOW listen_addresses` then reports the *new* value while the
> server is still bound to the old one.

### ⚠️ Why `'*'` and not `'localhost,172.20.0.1'`

Binding the bridge gateway explicitly looks tighter, and it is — right up until the first
reboot.

PostgreSQL **refuses to start** if `listen_addresses` names an address it cannot bind, and
`postgresql.service` orders itself only `After=network.target`. It has no dependency on
Docker having created the bridge. If Postgres wins that race on boot, `172.20.0.1` does not
exist yet and the server dies with:

```
could not create listen socket for "172.20.0.1"
```

You come back from a routine kernel update to a stack that is completely down, with a
Postgres that will not start until you create a Docker network by hand. That is a bad trade
for a bind-address narrowing that was never the control actually keeping the database
private.

Three independent layers still restrict 5432, none of which depend on boot ordering:

| Layer | Restricts to |
|---|---|
| `ufw` ([§4](#4-firewall)) | `172.20.0.0/16` only |
| `pg_hba.conf` | `172.20.0.0/16`, per-database, SCRAM-authenticated |
| no published port | nothing maps 5432 outward from any container |

Confirm the firewall is genuinely doing its job, since it is now load-bearing:

```bash
$ sudo ufw status verbose | grep 5432
# 5432/tcp  ALLOW IN  172.20.0.0/16

# from your workstation, NOT the VPS — the only test that proves anything
$ nmap -Pn -p 5432 <VPS public IP>      # filtered or closed, never open
```

Postgres now listens on IPv6 as well. The allow rule above is IPv4-only and should stay that
way — the Docker bridge is IPv4 — so IPv6 relies on ufw's `default deny incoming`. Verify
that is actually in force:

```bash
$ grep IPV6 /etc/default/ufw            # IPV6=yes
$ nmap -6 -Pn -p 5432 <VPS IPv6>        # if the box has one
```

If you have a specific reason to keep the narrow bind, it does work — create the network
before restarting Postgres, and add a systemd drop-in making `postgresql.service` order
`After=docker.service`. That is more moving parts to maintain than the firewall rule you
already have.

### Three things must all be true

Container-to-Postgres connectivity has three independent gates. Each one fails differently,
and confusing them costs hours:

| Gate | Configured in | Failure looks like |
|---|---|---|
| The firewall permits the packet | `ufw` ([§4](#4-firewall)) | **hang, then timeout** — no answer at all |
| Postgres is listening on that address | `listen_addresses` | **instant** `Connection refused` |
| `pg_hba` permits the role from that subnet | `pg_hba.conf` | **instant** `no pg_hba.conf entry for host` |

A wrong password is a fourth, distinct case: instant
`FATAL: password authentication failed`. If you remember only one thing here, remember that
**a timeout means the firewall** — Postgres always answers, even when the answer is "no".

### Prove it works

From the host:

```bash
$ psql "postgresql://planelyx_app:<app-password>@127.0.0.1:5432/planelyx" -c '\conninfo'
```

From inside a container on the real network — this is the path that actually matters:

```bash
$ docker run --rm --network planelyx_planelyx \
    --add-host host.docker.internal:host-gateway postgres:17-alpine \
    psql "postgresql://planelyx_app:<app-password>@host.docker.internal:5432/planelyx" \
    -c 'SELECT 1'
```

If the host connection works and the container connection does not, read the *shape* of the
failure against the table above: a hang is `ufw`, an instant refusal is `listen_addresses`,
an explicit `pg_hba` message is `pg_hba.conf`.

The firewall is the only one of the three that leaves no trace in the Postgres log — it
drops the packet before Postgres ever sees it. That is what makes it the confusing one, and
why it gets its own check:

```bash
$ sudo grep 'UFW BLOCK' /var/log/ufw.log | grep 5432 | tail -5
```

---

## 8. DNS

Create two records at your DNS provider:

| Type | Name | Value | TTL |
|---|---|---|---|
| `A` | `@` (apex) | `<VPS IPv4>` | 300 |
| `A` | `www` | `<VPS IPv4>` | 300 |

Add `AAAA` records too if your VPS has a public IPv6 address — the nginx config already
listens on `[::]:80` and `[::]:443`, so a missing `AAAA` is fine but a *wrong* one produces
sporadic failures for IPv6-capable clients only, which is miserable to debug.

**The apex cannot be a `CNAME`.** RFC 1034 does not allow a CNAME to coexist with the `SOA`
and `NS` records that must exist at a zone apex. Some providers offer `ALIAS`/`ANAME`
flattening; a plain `A` record to a static VPS IP is simpler and is what this setup assumes.

Keep TTL low (300s) until you are confident, then raise it to an hour.

### Verify before touching certbot

Let's Encrypt validates by connecting to the name from the outside. If DNS has not
propagated, certbot fails and each failure counts against a rate limit
(5 failed validations per account/hostname/hour). Check first:

```bash
$ dig +short planelyx.com A
$ dig +short www.planelyx.com A
# both must print your VPS IP

$ dig +short @1.1.1.1 planelyx.com A     # a resolver that is not your local cache
```

Confirm the box answers on port 80 from the outside before continuing:

```bash
$ curl -sI http://planelyx.com/ | head -1
```

---

## 9. nginx

### Clear the default site

```bash
$ sudo rm -f /etc/nginx/sites-enabled/default
```

Leaving it enabled means it is the default server for any unmatched `Host` header — which
is harmless but confusing, since a misconfiguration then shows the nginx welcome page
instead of an error.

### Get the config onto the box

The two files live in `planelyx-infra`. Clone it to a scratch location — this is a bootstrap
checkout, not a permanent one:

```bash
$ git clone https://github.com/macedo-erick/planelyx-infra.git ~/src/planelyx-infra
$ cd ~/src/planelyx-infra
```

> Deliberately **not** `~/planelyx-infra`. That directory is where the stack runs, and the
> deploy workflow writes `compose.prod.yaml` and `.env` into it on every release. Keeping a
> git checkout there would mean a working tree permanently dirty against files the workflow
> owns. [§12](#12-bringing-up-the-stack) copies the two files it needs out of this scratch
> clone; after that you can delete it.

### ⚠️ Bootstrap ordering: HTTP first, then certificates

`nginx/planelyx.conf` contains three `server` blocks: one on `:80`, and two on `:443` that
reference

```
/etc/letsencrypt/live/planelyx.com/fullchain.pem
```

That file does not exist yet. nginx **fails to start** when `ssl_certificate` points at a
missing file, so installing the full config now and reloading breaks nginx entirely — and
certbot cannot obtain a certificate through an nginx that will not start. Classic
chicken-and-egg.

Install an HTTP-only stub first:

```bash
$ sudo tee /etc/nginx/sites-available/planelyx > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name planelyx.com www.planelyx.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'bootstrap\n';
        add_header Content-Type text/plain;
    }
}
EOF

$ sudo mkdir -p /var/www/certbot
$ sudo ln -sf /etc/nginx/sites-available/planelyx /etc/nginx/sites-enabled/planelyx
$ sudo nginx -t && sudo systemctl reload nginx
$ curl -s http://planelyx.com/          # must print: bootstrap
```

That `curl` succeeding from **outside** the box is the precondition for the next section.

### Install the proxy snippet

This one has no certificate dependency, so install it now:

```bash
$ sudo mkdir -p /etc/nginx/snippets
$ sudo cp nginx/snippets/planelyx-proxy.conf /etc/nginx/snippets/
```

It sets the `X-Forwarded-*` headers that Spring Boot reads via
`server.forward-headers-strategy=framework` and Keycloak via `KC_PROXY_HEADERS=xforwarded`.
Without them both services believe they are serving plain HTTP on `127.0.0.1` and emit
absolute URLs pointing there — which breaks the OAuth2 redirect chain in a way that looks
like a Keycloak bug.

---

## 10. TLS with Let's Encrypt

### Issue the certificate

```bash
$ sudo certbot --nginx -d planelyx.com -d www.planelyx.com
```

> ⚠️ **Argument order matters.** Certbot names the certificate directory after the **first**
> `-d` argument. Passing `-d www.planelyx.com -d planelyx.com` produces
> `/etc/letsencrypt/live/www.planelyx.com/`, which will not match the paths in
> `nginx/planelyx.conf` and gives you a puzzling "no such file" on the next reload. Apex
> first.

Add `--dry-run` on a first attempt if you are unsure — it exercises the whole flow against
the staging CA without consuming the production rate limit (50 certificates per registered
domain per week; failed validations are limited separately and more tightly).

Certbot will have rewritten your bootstrap config in place. That is fine — you are about to
replace it.

Confirm the files landed where the real config expects:

```bash
$ sudo ls -l /etc/letsencrypt/live/planelyx.com/
# cert.pem  chain.pem  fullchain.pem  privkey.pem
```

### Install the real config

```bash
$ cd ~/planelyx-infra
$ sudo cp nginx/planelyx.conf /etc/nginx/sites-available/planelyx
$ sudo nginx -t && sudo systemctl reload nginx
```

`nginx -t` is not optional. A reload with a broken config leaves the old workers running,
so the site keeps working and you find out at the next restart — possibly a reboot, weeks
later.

`/auth/` depends on `snippets/keycloak-proxy.conf`, which the **auth** repo installs. If it is
not on the box yet, `nginx -t` fails on the include and this reload will not happen — do
`auth/VPS_SETUP.md` §4 first. That snippet is not cosmetic: it sets `Host`
and `X-Forwarded-Host` to `$server_name`, and Keycloak derives the issuer from those headers.
Including the general-purpose `planelyx-proxy.conf` here instead would forward the client's own
`Host`, and a forged one would end up in the issuer and in password-reset links. It carries a
full set of proxy headers, so it replaces `planelyx-proxy.conf` in that location rather than
being added to it.

### Hand the two files to the deploy user

Everything above is the one-time bootstrap. From here the **deploy workflow owns these two
files** and rewrites them on every run, so the deploy user needs to be able to write them
without `sudo`:

```bash
$ sudo chown "$VPS_USER":"$VPS_USER" /etc/nginx/sites-available/planelyx
$ sudo chown "$VPS_USER":"$VPS_USER" /etc/nginx/snippets/planelyx-proxy.conf
$ sudo chmod 644 /etc/nginx/sites-available/planelyx /etc/nginx/snippets/planelyx-proxy.conf
```

`$VPS_USER` is the SSH user GitHub Actions deploys as. The directories stay root-owned — only
these two files change hands, so the pipeline can replace them and nothing else in
`/etc/nginx`.

`snippets/keycloak-proxy.conf` is deliberately **not** in that list. The auth repo owns it,
and the deploy workflow never writes or deletes it: it copies an explicit list of two files
rather than syncing the directory. A directory sync here would delete the auth repo's snippet,
and since `planelyx.conf` includes it, the very next `nginx -t` would fail.

### Sudoers rule

The pipeline needs exactly two privileged commands:

```bash
$ sudo visudo -f /etc/sudoers.d/planelyx-deploy
```

```
<VPS_USER> ALL=(root) NOPASSWD: /usr/sbin/nginx -t, /bin/systemctl reload nginx
```

Deliberately not blanket `NOPASSWD`: a leaked deploy key then buys a config test and a
reload, not root. Check the binary paths with `command -v nginx` and `command -v systemctl` —
they differ across distributions, and a path that does not match is a rule that silently
never applies.

Verify **as the deploy user**, non-interactively, or the failure surfaces mid-deploy instead:

```bash
$ sudo -n nginx -t && echo "sudoers rule works"
```

If the monitoring stack is already on this box it has its own
`/etc/sudoers.d/monitoring-deploy` with the same two commands. Both files can coexist; if the
deploy user is the same for both, one rule is enough and the second is a harmless duplicate.

The routing this installs, for reference:

```nginx
location = / { return 302 /ui/; }

location /ui/   { proxy_pass http://127.0.0.1:8081; include .../planelyx-proxy.conf; }
location /api/  { proxy_pass http://127.0.0.1:8082; include .../planelyx-proxy.conf; }
location /auth/ { proxy_pass http://127.0.0.1:8085; include .../keycloak-proxy.conf; }
location /ocr/  { proxy_pass http://127.0.0.1:8084; include .../planelyx-proxy.conf;
                  client_max_body_size 25m; proxy_read_timeout 120s; }

location /auth/admin/        { return 404; }
location /internal/keycloak/ { allow 172.21.0.0/16; deny all;
                               proxy_pass http://127.0.0.1:8082; }

location /actuator    { return 404; }
location /v3/api-docs { return 404; }
location /swagger-ui  { return 404; }
```

Two things in there are load-bearing:

**Every `proxy_pass` is bare — no trailing slash, no URI part.** That preserves the full
request path: `/api/transactions` arrives at Spring as `/api/transactions`, and
`/auth/realms/...` arrives at Keycloak as `/auth/realms/...`. Each service is configured to
*own* its prefix (Angular via `--base-href /ui/`, Keycloak via `KC_HTTP_RELATIVE_PATH=/auth`,
the API via its `/api/*` controller mappings), so nothing is rewritten anywhere. Adding a
trailing slash to any of these silently breaks it.

**The enlarged proxy buffers on `/auth/`.** Keycloak emits large headers during the
authorization-code flow — `KC_RESTART` and state cookies in particular. nginx's defaults are
not big enough and produce a `502` with `upstream sent too big header` in the error log,
usually only for real browser logins and never for `curl`.

The `404` blocks keep `/actuator` and Swagger off the public internet. `/actuator/health` is
`permitAll` in `SecurityConfig` so the container healthcheck works; that permission is meant
to be internal-only, and this is what makes it so.

### Renewal

Certbot installs a systemd timer:

```bash
$ systemctl list-timers certbot.timer
$ sudo certbot renew --dry-run
```

Run the dry run now, not in 60 days. It is the only way to learn that renewal is broken
before it matters.

Add a deploy hook so a renewed certificate is actually picked up:

```bash
$ sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
$ sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

The nginx installer plugin usually handles this, but the hook is idempotent and costs
nothing. A silently-unreloaded renewal means your site starts serving an expired certificate
30 days after everything appeared to work.

### Take the vhost away from certbot's installer

⚠️ **Do this once, and do not skip it.** The certificate above was issued with `--nginx`,
which records `installer = nginx` in the renewal config. That installer *edits the vhost file
in place*. The deploy workflow now overwrites that same file on every run. Two writers, one
file: certbot re-adds its managed block, the next deploy wipes it, and the failure surfaces
60 days later as a renewal that no longer knows where to write — with an expired certificate
behind it.

Point the renewal at the webroot authenticator and drop the installer:

```bash
$ sudo cp /etc/letsencrypt/renewal/planelyx.com.conf{,.bak}
$ sudo sed -i \
    -e 's/^installer = nginx$/installer = None/' \
    -e 's/^authenticator = nginx$/authenticator = webroot/' \
    /etc/letsencrypt/renewal/planelyx.com.conf
```

Then make sure the `[renewalparams]` section carries the webroot path, adding it if `sed`
found no `authenticator = nginx` line to rewrite:

```
webroot_path = /var/www/certbot,
```

The `:80` server block in `nginx/planelyx.conf` already serves
`/.well-known/acme-challenge/` from `/var/www/certbot`, so the challenge works without
touching nginx config at renewal time. The deploy hook above is now what reloads nginx — it
is no longer redundant with the installer, it is the only thing doing that job.

Verify:

```bash
$ sudo certbot renew --dry-run
$ sudo git diff --no-index /etc/nginx/sites-available/planelyx nginx/planelyx.conf
```

The dry run must pass, and the vhost must still match the repo afterwards. If it does not,
certbot is still editing it and the installer change did not take.

---

## 11. Artifact Registry access

### Create the read-only service account

On your workstation, with `gcloud` authenticated to the project:

```bash
$ gcloud iam service-accounts create planelyx-vps-pull \
    --display-name="Planelyx VPS image puller"

$ gcloud projects add-iam-policy-binding PROJECT_ID \
    --member="serviceAccount:planelyx-vps-pull@PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/artifactregistry.reader"

$ gcloud iam service-accounts keys create sa-key.json \
    --iam-account=planelyx-vps-pull@PROJECT_ID.iam.gserviceaccount.com
```

`artifactregistry.reader` and nothing else. This key sits on an internet-facing box; it must
not be able to write images, and it must not be the same key CI uses.

### Log in on the VPS

Copy `sa-key.json` across (`scp`, or paste it into a file over your SSH session), then:

```bash
$ cat sa-key.json | docker login -u _json_key --password-stdin \
    https://southamerica-east1-docker.pkg.dev
$ rm sa-key.json
$ chmod 600 ~/.docker/config.json
```

`docker login` writes the credential **base64-encoded, not encrypted**, into
`~/.docker/config.json`. Deleting `sa-key.json` afterwards is worth doing anyway — one fewer
copy — but treat `~/.docker/config.json` as a secret from here on.

Confirm the login works before you need it:

```bash
$ docker pull southamerica-east1-docker.pkg.dev/PROJECT_ID/docker-remote-repo/api:latest
```

### Rotating the key

Keys do not expire on their own. Every few months:

```bash
$ gcloud iam service-accounts keys list \
    --iam-account=planelyx-vps-pull@PROJECT_ID.iam.gserviceaccount.com
# create a new key, docker login with it on the VPS, verify a pull, then:
$ gcloud iam service-accounts keys delete <OLD_KEY_ID> \
    --iam-account=planelyx-vps-pull@PROJECT_ID.iam.gserviceaccount.com
```

---

## 12. Bringing up the stack

### Create the run directory

`~/planelyx-infra` is where the stack runs. It is a plain directory, not a checkout: from the
first workflow deploy onwards, both `compose.prod.yaml` and `.env` in here are written by
`.github/workflows/deploy.yml`. For this manual first boot, copy them out of the scratch clone
from [§11.5](#get-the-config-onto-the-box):

```bash
$ mkdir -p ~/planelyx-infra
$ cd ~/planelyx-infra
$ cp ~/src/planelyx-infra/compose.prod.yaml .
$ cp ~/src/planelyx-infra/.env.example .env
```

### Write `.env`

```bash
$ chmod 600 .env
$ nano .env
```

| Key | Value |
|---|---|
| `REGISTRY` | `southamerica-east1-docker.pkg.dev/PROJECT_ID/docker-remote-repo` |
| `API_TAG` / `UI_TAG` / `OCR_TAG` | the commit SHAs from the three green CI runs |
| `APP_DB_PASSWORD` | the `planelyx_app` password from [§7](#7-postgresql) |
| `OCR_DB_PASSWORD` | the `planelyx_ocr` password from [§7](#7-postgresql) |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | the `planelyx-api-admin` client secret, read out of Keycloak |
| `PLANELYX_PROVISIONING_SECRET` | the same value the auth stack's `.env` carries |

Keycloak's own `.env` lives in `~/auth`, written by `auth`'s deploy workflow.

Two rules, both worth being pedantic about:

- **`REGISTRY` must match what CI pushed to.** The three `release.yml` workflows in this
  stack's repos use `REPOSITORY: planelyx`, which is also what `deploy.yml` renders into `.env`
  from [§13](#13-the-deploy-workflow) onwards. Point `REGISTRY` anywhere else and the pull hits
  a path that has never been written to. The Keycloak image is in a repository of its own,
  `auth`, and the auth stack's `.env` names it.
- **Pin SHAs, never `latest`.** `latest` makes a redeploy non-reproducible and turns
  rollback into guesswork. With SHAs pinned, rollback is editing three lines.

Every credential must be freshly generated. None of the local development values
(`planelyx`/`planelyx`, `admin`/`admin`) may reach this file.

### ⚠️ Never put a literal `$` in a password

Compose performs variable interpolation on the values inside `.env`. A password of
`Ab$jiBybu6hWhVy6V4cd` makes Compose look for a variable named `jiBybu6hWhVy6V4`, fail to
find it, and substitute **an empty string** — so the service receives `Abcd`. The only
warning you get is easy to skim past:

```
WARN[0000] The "jiBybu6hWhVy6V4" variable is not set. Defaulting to a blank string.
```

Treat that warning as a hard error. It means a credential silently reached a container
truncated, and the failure surfaces much later as an unrelated-looking connection timeout
(see [§16](#16-troubleshooting)).

`openssl rand -base64 32` never emits `$` — that is the reason [§7](#7-postgresql)
recommends it. If a password manager produced one that has a `$`, all three of these
behave differently, verified against a running container:

```bash
APP_DB_PASSWORD=Ab$jiBybu6hWhVy6V4cd     # container receives  Ab          ✗ truncated
APP_DB_PASSWORD=Ab$$jiBybu6hWhVy6V4cd    # container receives  Ab$jiBy…cd  ✓ escaped
APP_DB_PASSWORD='Ab$jiBybu6hWhVy6V4cd'   # container receives  Ab$jiBy…cd  ✓ quoted
```

Single-quoting is the least error-prone: the value stays readable and matches what you typed
into `psql`. With `$$`, remember the value stored in Postgres is the **unescaped** literal —
`$$` is Compose syntax, not part of the password.

**Confirm what the containers actually receive before the first deploy:**

```bash
$ docker compose -f compose.prod.yaml run --rm api printenv POSTGRES_PASSWORD
$ docker compose -f compose.prod.yaml run --rm ocr printenv POSTGRES_PASSWORD
```

> ⚠️ **Do not use `docker compose config` for this check.** It re-escapes `$` as `$$` in its
> own output, so a correctly-set password *displays* as `Ab$$jiBybu6hWhVy6V4cd` and looks
> wrong when it is right. `printenv` inside the container is the ground truth. `config` is
> still the right tool for checking `image:` and `REGISTRY`, which contain no `$`.

### First boot

```bash
$ docker compose -f compose.prod.yaml pull
$ docker compose -f compose.prod.yaml up -d --wait --wait-timeout 300 --remove-orphans
```

`--wait` blocks until every service is running or healthy and exits non-zero otherwise;
`--wait-timeout` is mandatory, because without it `--wait` waits forever. 300s is a floor
rather than a guess: `api` runs Flyway before it reports healthy.

This is the only time you run these by hand. From [§13](#13-the-deploy-workflow) onward the
deploy workflow issues the same two commands over SSH.

### ⚠️ Bring the auth stack up first

Keycloak is a separate Compose project and there is no `depends_on` edge to it. `api` resolves
its OIDC metadata eagerly at startup, so if the auth stack is not answering, `api` fails to
start and restart-loops until it is. That resolves itself — `restart: unless-stopped` keeps
retrying — but on a first boot it reads like an API problem when it is not one.

Deploy the auth stack first, per `auth/VPS_SETUP.md` §7, and confirm:

```bash
$ curl -s https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration | jq -r .issuer
# https://planelyx.com/auth/realms/planelyx
```

Then bring this stack up. The first-boot realm import, and the drop-and-recreate escape hatch
for a realm that imported wrong, are in that document too — this stack has no say in either.

### Then confirm `api` reaches healthy

```bash
$ docker compose -f compose.prod.yaml ps
$ docker compose -f compose.prod.yaml logs -f api
```

Flyway runs in-process during startup and `ddl-auto: validate` will fail loudly on any
schema mismatch, so a healthy `api` is a real signal that the database is correct.

---

## 13. The deploy workflow

Everything up to here you did by hand, once. From now on releases go through
`.github/workflows/deploy.yml` in `planelyx-infra`: you paste the commit SHA of each service
you want to deploy, and it SSHes in and does the rest. A service you leave blank is not
touched — the workflow reads its current tag off this box and carries it forward.

Do this section after the stack is up and verified. The workflow is a convenience over a
process you have already proven manually; wiring it before you know the manual path works
just gives you two things to debug at once.

### A dedicated SSH key

Generate it on your workstation, not on the VPS — the private half never needs to exist there.

```bash
$ ssh-keygen -t ed25519 -C github-actions-deploy -f ~/.ssh/planelyx-deploy -N ''
```

Append the public half to the `deploy` user's `authorized_keys`:

```bash
$ ssh-copy-id -i ~/.ssh/planelyx-deploy.pub deploy@planelyx.com
```

Use a fresh key rather than the one you log in with. Revoking CI access then means deleting
one line from `authorized_keys`, with no effect on your own access.

Capture the host key for pinning — this is what makes `StrictHostKeyChecking=yes` in the
workflow mean anything:

```bash
$ ssh-keyscan planelyx.com
```

> Take that output from a network you trust. `ssh-keyscan` has no way to authenticate what
> answers it, so scanning from a compromised network pins an attacker's key.

Confirm the key works **non-interactively**, which is how Actions will use it:

```bash
$ ssh -i ~/.ssh/planelyx-deploy -o BatchMode=yes deploy@planelyx.com \
    'cd planelyx-infra && docker compose version'
```

Two things this proves at once: the key is accepted without a passphrase prompt, and Docker is
reachable as `deploy` without a login shell. Also check the registry credential the same way — a `docker login -u _json_key`
blob works fine here, but a `gcloud` credential helper needs `gcloud` on the non-interactive
`PATH` and will fail even though it works when you are logged in:

```bash
$ ssh -i ~/.ssh/planelyx-deploy -o BatchMode=yes deploy@planelyx.com \
    'docker pull southamerica-east1-docker.pkg.dev/PROJECT_ID/docker-remote-repo/ui:latest'
```

### Repo secrets

In `planelyx-infra` → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `VPS_HOST` | `planelyx.com`, or the IP |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | contents of `~/.ssh/planelyx-deploy` (the private half) |
| `VPS_SSH_KNOWN_HOSTS` | the `ssh-keyscan` output above |
| `GCP_PROJECT_ID` | same value as in the four service repos |
| `APP_DB_PASSWORD` | the `planelyx_app` role's password, from [§7](#7-postgresql) |
| `OCR_DB_PASSWORD` | the `planelyx_ocr` role's password |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | secret of the `planelyx-api-admin` client — **read out of the Keycloak admin console**, not generated. Also held by the auth repo |
| `PLANELYX_PROVISIONING_SECRET` | verifies Keycloak's "a user registered" callback to the API; generate with `openssl rand -hex 32`. Also held by the auth repo |
| `ANTHROPIC_API_KEY` | **optional** — model escalation for statements the coordinate parser cannot read. Leave unset to keep every document on the machine |

`KC_DB_PASSWORD`, `KC_ADMIN` and `KC_ADMIN_PASSWORD` are **not** here any more — they belong to
`auth`, which renders its own `.env`. Delete them from this repo once the auth
stack is live.

The last two rows are the awkward ones: they exist as secrets in **both** repositories, because
Keycloak holds one side of each and the API the other, and **nothing checks the two copies
agree**. A mismatched `KEYCLOAK_ADMIN_CLIENT_SECRET` is a 401 on the profile page; a mismatched
`PLANELYX_PROVISIONING_SECRET` means new users silently get no default categories. Rotating
either means updating both repositories and redeploying both stacks, back to back.

### Repo variables (model escalation)

Under the **Variables** tab beside the secrets, not Secrets — these are configuration, and a
value nobody can read back is a value nobody can audit. All three may be left unset, which is
the same as the defaults below and keeps the model switched off.

| Variable | Default | Meaning |
|---|---|---|
| `OCR_LLM_ENABLED` | `false` | Whether statement text may be sent to Anthropic at all |
| `OCR_LLM_PARSE_MODE` | `fallback` | `fallback` escalates only a document the coordinate parser declined; `always` sends every document; `off` sends none |
| `OCR_LLM_MONTHLY_CEILING_USD` | `10` | Hard monthly spend ceiling, enforced by the service against its own recorded spend before each call. `0` disables calls without unsetting the key |

Setting `OCR_LLM_ENABLED=true` without `ANTHROPIC_API_KEY` is refused by the workflow before
it deploys: the service exits on that combination rather than silently running without
escalation, so the container would restart-loop on the box.

The key is the one credential allowed to be empty. The service treats an empty value and an
absent one as the same state — no key configured — so a stack that never sets it renders
`ANTHROPIC_API_KEY=''` and starts perfectly well.

### Repo variables (log levels)

Also under **Variables**. All four may be left unset, which is the same as the defaults below.
Raise one to diagnose something and put it back afterwards: Loki keeps 30 days, and a service
left at `debug` will burn through that far sooner.

| Variable | Default | Meaning |
|---|---|---|
| `API_LOG_LEVEL` | `INFO` | Spring, scoped to `com.planelyx.api` — the application's own logging |
| `API_LOG_LEVEL_ROOT` | `INFO` | Spring, everything else: framework internals, Hibernate, Tomcat |
| `OCR_LOG_LEVEL` | `info` | pino. **Lowercase only** — an uppercase value throws on startup and the container restart-loops |
| `AUTH_LOG_LEVEL` | `info` | Keycloak's `KC_LOG_LEVEL`. A runtime option, so it needs no image rebuild |

The API has two because raising the app to `DEBUG` is useful and raising Spring and Hibernate
with it is not — that combination is what makes `DEBUG` unusable in production.

The workflow rejects a value outside each service's own set before deploying, since nothing
downstream would catch it: only `ui` has a restart-count smoke check, so a crash-looping `ocr`
would otherwise pass the deploy and fail silently.

> ⚠️ **Adding `OCR_DB_PASSWORD` to a stack that is already running is a one-off.** The `.env`
> on the box predates the key, so the drift check reads it back empty and refuses — and
> `OCR_TAG` cannot be carried forward from a file that has never contained it. That first run
> therefore needs both an ocr tag **and** *Allow DB/Keycloak credentials to differ* ticked, with
> the `planelyx_ocr` role already created in [§7](#7-postgresql) using that exact password. Both
> checks are behaving correctly here; every run afterwards is ordinary.

The last eight must **byte-match what is in `.env` on the box right now**. The workflow
compares them before it deploys and refuses to continue if they differ, precisely so a
mismatch surfaces here rather than weeks later, when an unrelated deploy recreates a container
with a password Postgres rejects.

`PLANELYX_PROVISIONING_SECRET` is the one that fails quietly rather than loudly. A mismatch
does not break sign-in — it makes the API reject the provisioning callback, so new accounts
arrive with no default categories. Nothing retries past ~20 seconds and there is no second
trigger to recover from, so rotate it by restarting `api` and `auth` together.

No `GCP_SA_KEY` is needed. The VPS already holds its own read-only registry login from
[§11](#11-artifact-registry-access), and the runner never touches the registry.

### What the workflow now owns

Two files in `~/planelyx-infra` now belong to the workflow, and hand edits to either are lost
on the next deploy:

- **`.env`** — rendered from the repo secrets on **every** deploy. That makes GitHub the source
  of truth for those credentials; see the warning in [§15](#15-operations) about what that
  means for rotation.
- **`compose.prod.yaml`** — shipped from the commit being deployed, over SSH, before anything
  is pulled.

Shipping the compose file is what removes the need for a checkout on the box. The alternative
— a clone that you `git pull` by hand before each release — has one failure mode that is
invisible when it happens: forget the pull, and the deploy runs against an older topology
while reporting success. There is no pull to forget now, and no way for the running stack to
lag behind master.

- **`nginx/planelyx.conf`** and **`nginx/snippets/planelyx-proxy.conf`** — shipped from the
  same commit, after the containers are up and before the smoke checks.

The nginx step copies an explicit list of two files, compares each against what is live, and
does nothing at all when they match — so an ordinary release does not reload nginx. When they
differ it backs the live files up to `~/planelyx-infra/nginx-prev/`, installs the new ones,
and runs `sudo nginx -t`. **A failed test restores the backups and fails the run without
reloading**, which matters because this nginx also fronts
`monitoring.macedosoftware.com`: a broken planelyx config must never reach the shared
process. The smoke checks then re-request that neighbour hostname to confirm the reload did
not take it down.

This needs the one-time bootstrap in [§9](#9-nginx) — the two files chowned to the deploy
user, and the sudoers rule for `nginx -t` and `systemctl reload nginx`. The workflow refuses
to run if either file is missing or not writable, rather than half-applying a config.

> `workflow_dispatch` only appears in the Actions tab once the workflow file is on the default
> branch. If you cannot find the "Run workflow" button, the file is still on a feature branch.

---

## 14. Verification

Run these in order. The ordering is deliberate: each one narrows down where a failure can
be, and the issuer check catches the single most likely mistake.

The auth stack has verification of its own, in `auth/VPS_SETUP.md` §8. Run that
first — several checks below assume Keycloak is already answering correctly.

### 1. The issuer string — the most important check

```bash
$ curl -s https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration \
    | jq -r .issuer
```

Must print **exactly**:

```
https://planelyx.com/auth/realms/planelyx
```

The API validates JWTs by `issuer-uri` alone. If this string differs from
`KEYCLOAK_ISSUER_URI` in `compose.prod.yaml` by so much as a trailing slash, every
authenticated request 401s and nothing else you check will make sense.

### 2. Routing and TLS

```bash
$ curl -sI https://planelyx.com/                 # 302 → /ui/
$ curl -s  https://planelyx.com/ui/ | head       # index.html with <base href="/ui/">
$ curl -sI http://planelyx.com/                  # 301 → https
$ curl -sI https://www.planelyx.com/             # 301 → https://planelyx.com/
$ curl -sI https://planelyx.com/actuator/health  # 404 from nginx
$ curl -sI https://planelyx.com/swagger-ui.html  # 404 from nginx
$ curl -sI https://planelyx.com/ocr/documents    # 401 — proxied and rejecting anonymous
```

That last one is the check worth being precise about: **401 is the pass condition.** A 404
means the `location /ocr/` block is missing from the host nginx config — which now means the
deploy's nginx step did not run or its `nginx -t` failed and rolled back, so read that step's
log. A 502 means the container is not up.

The service's own health endpoint is deliberately not reachable from the internet; check it
from the box:

```bash
$ curl -s http://127.0.0.1:8084/ocr/healthz      # {"status":"ok"}
```

It queries the database rather than only proving the process is alive, so a 503 here is a
`planelyx_ocr` credential or `pg_hba.conf` problem, not a dead container.

### 3. The host-gateway hairpin

This is the piece no amount of local testing can prove, and it is the reason
`'planelyx.com:host-gateway'` is in `compose.prod.yaml`. The API must fetch JWKS from the
*public* issuer URL, because that is the string inside the token's `iss` claim. Without the
`extra_hosts` entry the container resolves `planelyx.com` to the public IP and hairpins out
through the internet and back — which many VPS providers simply do not route.

```bash
$ docker compose -f compose.prod.yaml exec api \
    curl -fsS https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration \
    | head -c 120
```

A TLS or DNS error here means `extra_hosts` or the certificate is wrong, and every
authenticated request will 401 until it is fixed.

`ocr` needs the same entry, for the same reason — it derives its JWKS URL from the issuer:

```bash
$ docker compose -f compose.prod.yaml exec ocr \
    curl -fsS https://planelyx.com/auth/realms/planelyx/protocol/openid-connect/certs \
    | head -c 120
```

And `api` needs a second one, `auth.macedosoftware.com`, because the Admin API is not served on
the product domain:

```bash
$ docker compose -f compose.prod.yaml exec api \
    curl -fsS -o /dev/null -w '%{http_code}\n' https://auth.macedosoftware.com/auth/realms/planelyx
# 200
```

TLS validates correctly despite the
redirection because the SNI hostname is genuinely `planelyx.com`.

### 4. The API's own health

```bash
$ docker compose -f compose.prod.yaml exec api \
    curl -fsS http://127.0.0.1:8080/actuator/health      # {"status":"UP"}

$ curl -sI https://planelyx.com/api/dashboard            # 401 — no token
```

A `401` here is the correct answer. A `502` means the container is down; a `200` means
something is very wrong with `SecurityConfig`.

### 5. A real token

The realm has `directAccessGrantsEnabled`, so you can get a token without a browser. Use a
user you registered through the UI:

```bash
$ TOKEN=$(curl -s -d 'client_id=planelyx-api' -d 'grant_type=password' \
    -d "username=$U" -d "password=$P" \
    https://planelyx.com/auth/realms/planelyx/protocol/openid-connect/token \
    | jq -r .access_token)

$ echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .iss
# https://planelyx.com/auth/realms/planelyx

$ curl -s -H "Authorization: Bearer $TOKEN" https://planelyx.com/api/dashboard
```

> If the token request returns
> `{"error":"invalid_grant","error_description":"Account is not fully set up"}` while
> `requiredActions` is empty, the user is missing `firstName`/`lastName`. Keycloak 26's
> declarative user profile marks both required, and a user without them cannot obtain a
> token at all. The custom `register.ftl` collects them — which is exactly why the browser
> registration check below matters.

### 6. Browser end-to-end

Only a real browser exercises these:

1. Open `https://planelyx.com/ui/` → redirected to Keycloak at
   `/auth/realms/planelyx/protocol/openid-connect/auth`.
2. Confirm the custom `planelyx` login theme renders. If it does not, the theme was not
   baked into the image (production mode caches themes; `start-dev` does not).
3. **Register a genuinely new user** through the form → lands back on `/ui/...`, **not**
   `/...`. Landing at the domain root means the `prepareExternalUrl` fix is missing from the
   UI build.
4. DevTools → Network: `silent-check-sso.html` loads from `/ui/silent-check-sso.html` with
   no 404 and no CSP/frame errors.
5. Deep-link straight to an inner route — `https://planelyx.com/ui/transactions` — in a
   fresh tab. SPA fallback should serve it after login.
6. Reload while authenticated → session survives (silent SSO working).
7. Log out → returns to `/ui/`.
8. Idle 30 minutes → auto-logout fires (`withAutoRefreshToken`).

### 7. Persistence

```bash
$ docker compose -f compose.prod.yaml down
$ docker compose -f compose.prod.yaml up -d --wait --wait-timeout 300
```

Log back in and confirm your user and data are still there. All three databases live on the
host, so nothing should be lost — this check exists to prove that, not to hope it.

`ocr` is the one service whose state is *not* on the host: its documents and its encryption key
are Docker volumes. `down` leaves them alone; `down -v` destroys them, and no reprocessing can
recover a document whose key is gone. Confirm they survived:

```bash
$ docker volume ls | grep planelyx
# planelyx_ocr-data and planelyx_ocr-keys must both still be listed
```

### 8. Port bindings

```bash
$ sudo ss -tlnp | grep -E '808[1234]|5432'
```

Every **container** port (8081–8084) must be bound to `127.0.0.1`. Anything else there on
`0.0.0.0` is exposed to the internet. Postgres on `*:5432` is expected — it is kept private
by the ufw rule and `pg_hba.conf` rather than by its bind address ([§7](#7-postgresql)).
Confirm that from off-box, which is the only test that counts:

```bash
# from your workstation, not the VPS
$ nmap -Pn -p 22,80,443,5432,8081,8082,8084,8085 <VPS public IP>
# 22/80/443 open; everything else filtered or closed
```

---

## 15. Operations

### Logs

```bash
$ cd ~/planelyx-infra
$ docker compose -f compose.prod.yaml logs -f --tail=100 api
$ docker compose -f compose.prod.yaml logs -f ocr

$ cd ~/auth && docker compose -f compose.prod.yaml logs -f keycloak

$ sudo tail -f /var/log/nginx/error.log
$ sudo tail -f /var/log/postgresql/postgresql-17-main.log
```

Container logs are capped at 3 × 10 MB per service by `compose.prod.yaml`. nginx logs are
rotated by the packaged logrotate config.

### Connecting a SQL client (DataGrip, psql, …)

Use an **SSH tunnel**. It requires no server-side change: `listen_addresses = '*'` already
covers loopback, and Ubuntu's default `pg_hba.conf` permits `127.0.0.1/32` with
`scram-sha-256`.

```bash
$ ssh -N -L 15432:127.0.0.1:5432 deploy@planelyx.com
$ psql "postgresql://planelyx_app@127.0.0.1:15432/planelyx"     # in another terminal
```

In DataGrip, the *General* tab's host/port are resolved **on the SSH server**, so:

| Tab | Field | Value |
|---|---|---|
| General | Host / Port | `127.0.0.1` / `5432` |
| General | Database / User | `planelyx` / `planelyx_app` |
| SSH/SSL | Use SSH tunnel | ✓ — `deploy@planelyx.com:22`, key pair |

> **Do not open 5432 in `ufw` to reach it directly.** Home IPs rotate, and `pg_hba`'s `host`
> (as opposed to `hostssl`) sends credentials in cleartext across the internet. Doing that
> safely means server certificates and `sslmode=verify-full` — more work than the tunnel,
> for a weaker result.

**Do not write to the `keycloak` database.** Keycloak caches aggressively in Infinispan;
rows changed underneath it produce inconsistencies that survive restarts. Read it freely;
change it through the admin console or `kcadm.sh`.

For ad-hoc querying, connect as a read-only role rather than the table owner:

```sql
CREATE ROLE planelyx_ro LOGIN PASSWORD '<pw>';
GRANT CONNECT ON DATABASE planelyx TO planelyx_ro;
GRANT USAGE ON SCHEMA public TO planelyx_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO planelyx_ro;
-- without this, tables added by future Flyway migrations stay invisible to the role
ALTER DEFAULT PRIVILEGES FOR ROLE planelyx_app IN SCHEMA public
  GRANT SELECT ON TABLES TO planelyx_ro;
```

### Backups

The single most important operational task. All three databases, one job, off the box.

```bash
$ sudo tee /usr/local/bin/planelyx-backup.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
# Dumps all three databases into one timestamped directory. They are one logical unit:
# planelyx.owner_id references Keycloak `sub` values, planelyx_ocr keys its documents the same
# way and records the ledger ids it produced, so a partial restore loses data.
set -euo pipefail

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST="/var/backups/planelyx/$STAMP"
mkdir -p "$DEST"
# 700 because the ocr master key is copied in below. Everything here is sensitive, but that
# file is a decryption key sitting next to the data it decrypts.
chmod 700 "$DEST"

sudo -u postgres pg_dump -Fc planelyx      > "$DEST/planelyx.dump"
sudo -u postgres pg_dump -Fc keycloak      > "$DEST/keycloak.dump"
sudo -u postgres pg_dump -Fc planelyx_ocr  > "$DEST/planelyx_ocr.dump"

# The ocr master key: 32 bytes, and the only thing on this box that nothing can regenerate.
# Every stored statement is encrypted with it, so losing it destroys them all — including the
# ones a database restore would otherwise bring back. Copied on every run because it is
# effectively free; it is written once on first boot and does not change.
docker run --rm -v planelyx_ocr-keys:/keys:ro -v "$DEST":/out alpine \
    cp /keys/master.key /out/ocr-master.key

# Keep 14 days locally. Off-box copy is what actually protects you.
find /var/backups/planelyx -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
EOF
$ sudo chmod +x /usr/local/bin/planelyx-backup.sh
```

> ⚠️ **The documents themselves are not in this job.** `planelyx_ocr-data` holds the encrypted
> originals and grows without bound, so it does not belong in a nightly rotation that keeps 14
> full copies. Back it up on its own schedule — it is append-only, which makes it a good fit for
> `restic` or `rclone sync` rather than repeated tarballs:
>
> ```bash
> $ docker run --rm -v planelyx_ocr-data:/data:ro -v /var/backups:/out alpine \
>     tar czf /out/ocr-data.tar.gz -C /data .
> ```
>
> Losing it is recoverable in a way losing the key is not: the ledger keeps the confirmed
> transactions, and what is lost is the ability to re-read an original — which for receipts is
> permanent past roughly 180 days, when SEFAZ stops serving them.

Schedule it:

```bash
$ sudo tee /etc/systemd/system/planelyx-backup.service > /dev/null <<'EOF'
[Unit]
Description=Planelyx database backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/planelyx-backup.sh
EOF

$ sudo tee /etc/systemd/system/planelyx-backup.timer > /dev/null <<'EOF'
[Unit]
Description=Nightly Planelyx database backup

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

$ sudo systemctl daemon-reload
$ sudo systemctl enable --now planelyx-backup.timer
$ sudo systemctl start planelyx-backup.service    # run once now
$ ls -la /var/backups/planelyx/
```

**A backup on the same disk as the database is not a backup.** Add an off-box copy — `rclone`
to object storage, `restic` to a remote repo, or a `scp` pull from elsewhere. Whatever you
pick, it must not depend on this VPS being alive.

### Test the restore

Untested backups are decoration. Do this once, deliberately, before you need it:

```bash
$ sudo -u postgres createdb planelyx_restore_test
$ sudo -u postgres pg_restore -d planelyx_restore_test \
    /var/backups/planelyx/<STAMP>/planelyx.dump
$ sudo -u postgres psql -d planelyx_restore_test -c '\dt'
$ sudo -u postgres dropdb planelyx_restore_test
```

Note what a real restore means: **all three** databases, from the **same** timestamp. Restoring
`planelyx` against an older `keycloak` orphans rows whose `owner_id` no longer matches any
user; restoring `planelyx_ocr` older than `planelyx` re-offers documents that were already
filed, and confirming one of those writes every transaction on it to the ledger a second time.

### Deploying a new release

1. Merge to `master`; wait for CI green in whichever repos changed.
2. Note the commit SHA from the workflow's job summary (it prints
   `Deploy with API_TAG=<sha>`).
3. In `planelyx-infra`: **Actions → deploy → Run workflow**. Paste the SHA of each service you
   are releasing.

Leaving a service's tag box empty is how you say "leave it alone" — the workflow reads that
service's current tag off this box and carries it forward, so its container is never
recreated. There is no longer any reason to edit `.env` by hand.

The workflow refuses to deploy if a tag doesn't exist in Artifact Registry, and it finds that
out *before* replacing `.env`, so a mistyped SHA costs a red run and nothing else.

You still need the SSH access and repo secrets from [§13](#13-the-deploy-workflow) in place.

**`.env` is now rendered from the repo secrets on every deploy.** Editing a credential here
without updating the secret will be reverted on the next run — and because the workflow
compares the two first, it will fail loudly rather than silently reverting. That check is the
point; do not work around it by disabling it. Rotate properly: change the Postgres role,
update the repo secret, then run the workflow with *Allow DB/Keycloak credentials to differ*
ticked.

For manual and break-glass use, drive Compose directly on the box. The last successful deploy
leaves both `compose.prod.yaml` and `.env` in `~/planelyx-infra`, so there is nothing to fetch
first:

```bash
$ cd ~/planelyx-infra
$ docker compose -f compose.prod.yaml pull
$ docker compose -f compose.prod.yaml up -d --wait --wait-timeout 300 --remove-orphans

# one service only
$ docker compose -f compose.prod.yaml up -d --wait --wait-timeout 300 --no-deps api
```

`--no-deps` is what keeps a single-service deploy from restarting the other three. Never use it
on the whole stack: it drops dependency edges outright, so `up --no-deps ui api auth ocr` starts
`api` without waiting for `auth` to be healthy, and `api` resolves the OIDC metadata at
startup.

⚠️ **Bringing up `ocr` by hand means running its migrations by hand.** Unlike `api`, which runs
Flyway on its way to reporting healthy, this service does not migrate at startup — the deploy
workflow does it, and driving Compose directly skips that step. The new container then serves
against the previous schema and fails on whichever query touches a column that does not exist
yet. Before `up`, from the image you are deploying:

```bash
$ docker compose -f compose.prod.yaml run --rm ocr node dist/storage/migrate.js
```

It dumps the database into the `ocr-data` volume before touching anything and aborts if it
cannot, which is why the image carries `pg_dump`.

Anything you change in `compose.prod.yaml` on the box is overwritten by the next workflow run,
which ships its own copy. Real changes go in the repo.

Not zero-downtime: `up -d` restarts the API in place and Flyway runs on startup, so expect
a few seconds of `502` on `/api`. Fine at this scale; revisit when it stops being fine.

Remember that the `ui` image is **environment-specific** — `apiUrl` and the Keycloak URL are
baked in at build time from `environment.production.ts`. A different hostname needs a
different build, not a different env var.

### Rolling back

Re-run the deploy workflow with the previous SHAs. This is why you pinned SHAs.

Where to find them: the previous run's job summary lists every service's tag, and `.env.prev`
on the VPS holds the tags from immediately before the last deploy. The old images are still on
the box — the deploy prunes only *dangling* images, and a pinned SHA tag is never dangling —
so a rollback doesn't even need the registry.

The caveat: **Flyway migrations do not roll back.** If the release you are reverting added a
migration, the old image will start against a newer schema and `ddl-auto: validate` may
refuse. Additive migrations (new nullable columns, new tables) are usually safe to roll back
across; destructive ones are not. Plan schema changes with that asymmetry in mind.

**Rolling back nginx** is a separate thing, because the vhost is not versioned by image tag.
The workflow already restores automatically when `nginx -t` fails. To undo a config that
passed the test but behaves wrongly, either re-run the workflow from the previous commit or
put the backups back by hand:

```bash
$ cd ~/planelyx-infra
$ cp nginx-prev/planelyx.conf /etc/nginx/sites-available/planelyx
$ cp nginx-prev/planelyx-proxy.conf /etc/nginx/snippets/planelyx-proxy.conf
$ sudo nginx -t && sudo systemctl reload nginx
```

No `sudo` on the two `cp` lines — those files belong to the deploy user. `nginx-prev/` holds
only the files that changed on the last run that changed anything, so check the timestamps
before trusting it as a full snapshot.

To take the site offline without touching the monitoring stack or the auth stack:

```bash
$ sudo rm /etc/nginx/sites-enabled/planelyx
$ sudo nginx -t && sudo systemctl reload nginx
```

### Disk

```bash
$ df -h /
$ docker system df
$ sudo du -sh /var/lib/postgresql /var/backups/planelyx /var/lib/docker
```

Every deploy already runs `docker image prune -f`. If images still accumulate:

```bash
$ docker system prune -af --filter "until=168h"
```

### Updating the host

```bash
$ sudo apt-get update && sudo apt-get upgrade -y
$ sudo reboot        # when the kernel changed
```

`restart: unless-stopped` brings the stack back automatically after a reboot. Verify with
`docker compose -f compose.prod.yaml ps` afterwards rather than assuming.

---

## 16. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| **Every authenticated request 401s**, unauthenticated ones work | Issuer mismatch. The `iss` claim does not equal `KEYCLOAK_ISSUER_URI` character for character. | Compare `curl .../.well-known/openid-configuration \| jq -r .issuer` with `KEYCLOAK_ISSUER_URI` in `compose.prod.yaml`. Watch for a trailing slash, a missing `/auth`, or `http` vs `https`. |
| **API healthy but 401s**, issuer strings match | API cannot reach the issuer to fetch JWKS. | Run [§14 check 3](#3-the-host-gateway-hairpin). Missing `'planelyx.com:host-gateway'` in `extra_hosts`, or the container cannot reach host nginx on 443. |
| **`auth` container exits with code 2** on start, log mentions "build time options have values that differ" | A build-time Keycloak option was overridden at runtime. `KC_DB`, `KC_HEALTH_ENABLED`, `KC_HTTP_RELATIVE_PATH` and `KC_HTTP_MANAGEMENT_RELATIVE_PATH` are baked into the image; `start --optimized` treats a differing runtime value as fatal, not a warning. | Remove the offending variable from `compose.prod.yaml`. To actually change it, edit `planelyx-auth/Dockerfile` and rebuild. |
| **`auth` never becomes healthy**, but the log looks fine | The health probe moved. If `KC_HTTP_MANAGEMENT_RELATIVE_PATH` is not pinned to `/`, the management interface inherits `/auth` and health lands at `:9000/auth/health/ready`. | Confirm the Dockerfile bakes `KC_HTTP_MANAGEMENT_RELATIVE_PATH=/`. |
| **Compose warns** `The "xxxxx" variable is not set. Defaulting to a blank string` | A value in `.env` contains a literal `$`, which Compose interpolated away. A credential reached the container truncated at the `$`. | Wrap the value in single quotes (or escape as `$$`), then verify with `docker compose run --rm api printenv POSTGRES_PASSWORD` — **not** `docker compose config`, which re-escapes `$`. See [§12](#12-bringing-up-the-stack). |
| **`auth` fails to start**, log shows `Acquisition timeout while waiting for new connection` / `Could not obtain connection to query metadata` | Keycloak could not get a database connection. Agroal reports the same pool timeout for every underlying cause, so this message alone tells you nothing. | **Read the line below it.** `Datasource '<default>': The connection attempt failed.` means an IOException — the packet went unanswered. An explicit `FATAL:` or `no pg_hba.conf entry` means Postgres replied and rejected you. Then take the matching row below. |
| ↳ **Hang for ~10s**, then `The connection attempt failed.`; Postgres log is **completely silent** | `ufw` is dropping container→host traffic on 5432. This is the common one, and the silence is the tell — Postgres never saw the packet. | `sudo ufw allow from 172.20.0.0/16 to any port 5432 proto tcp && sudo ufw reload`. Confirm first with `sudo grep 'UFW BLOCK' /var/log/ufw.log \| grep 5432`. See [§4](#4-firewall). |
| ↳ **Instant** `Connection to host.docker.internal:5432 refused` | Nothing is listening on the bridge gateway. Postgres is up but bound to loopback only. | `sudo ss -tlnp \| grep 5432` — if it shows only `127.0.0.1`, set `listen_addresses = '*'` and **restart** (a reload silently does nothing). Check `sudo -u postgres psql -c 'SHOW config_file;'` too — you may have edited a different cluster's config. |
| ↳ Postgres log says `password authentication failed for user "keycloak"` | Wrong credential. Most often the `$`-interpolation bug above; otherwise `.env` and the role have drifted. | Fix `.env`, or `sudo -u postgres psql -c "ALTER ROLE keycloak PASSWORD '<new>';"`. Then `docker compose -f compose.prod.yaml up -d auth`. |
| **`api` restart-loops with an OIDC/JWKS error at startup** | Not an API problem. It resolves `issuer-uri` eagerly and there is no `depends_on` edge to Keycloak any more — the auth stack is a separate Compose project. | Debug the auth stack first: `cd ~/auth && docker compose -f compose.prod.yaml logs keycloak`. `api` comes up on its own once Keycloak answers. |
| **A password-reset link points at the wrong domain**, or the issuer contains a hostname you did not configure | The `/auth/` location is including `planelyx-proxy.conf` instead of `keycloak-proxy.conf`, so the client's own `Host` header is reaching Keycloak and becoming the issuer. | Fix the include, reload nginx, and re-run the forged-`Host` check in `auth/VPS_SETUP.md` §8. |
| **Two Postgres clusters**, edits to config have no effect | Ubuntu's `postgresql-16` and PGDG's `postgresql-17` are both installed. 16 holds port 5432; 17 was pushed to 5433. You are editing the config of a server nothing connects to. | `pg_lsclusters`, then `sudo -u postgres psql -c 'SHOW config_file;'` to see which file the running server read. Drop the unwanted cluster with `sudo pg_dropcluster --stop 16 main`. |
| **Containers reach Postgres but get** `no pg_hba.conf entry for host "172.20.0.x"` | Subnet drift between `compose.prod.yaml` and `pg_hba.conf`, or the rules are below a broader match. | Compare the `ipam` subnet with the `host` lines. `sudo systemctl reload postgresql` after editing. |
| **PostgreSQL will not start after a reboot**, log says `could not create listen socket for "172.20.0.1"` | `listen_addresses` pins the bridge gateway, but Postgres started before Docker created the bridge. Nothing owns that address yet. | Set `listen_addresses = '*'` — [§7](#7-postgresql) explains why that is the right default and what still keeps 5432 private. As a stopgap, `docker network create --subnet 172.20.0.0/16 planelyx_planelyx` then start Postgres. |
| **`502` on `/auth/` during browser login only**; `curl` works | Keycloak's authorization-code headers exceed nginx's proxy buffers. Error log says `upstream sent too big header`. | Confirm the `proxy_buffer_size` / `proxy_buffers` lines are present in the `/auth/` block. |
| **`502` on `/api/`** after a deploy | API still starting. Flyway runs in-process, so first boot takes ~60s. | `docker compose logs -f api`. If it never recovers, `ddl-auto: validate` probably failed on a schema mismatch — the log names the offending column. |
| **nginx will not start**, `cannot load certificate` | The `:443` blocks were installed before the certificate existed, or certbot named the directory after `www.`. | `ls /etc/letsencrypt/live/`. If it is `www.planelyx.com`, reissue with the apex as the first `-d`. See [§10](#10-tls-with-lets-encrypt). |
| **Realm changes in `realm-export.json` are not taking effect** | `--import-realm` is a no-op once the realm exists. It only ever runs against an empty `keycloak` database. | Change it in the admin console or via `kcadm.sh`. To re-import, drop and recreate the `keycloak` database — which destroys all users. |
| **Registration succeeds but login returns** `Account is not fully set up` | User is missing `firstName`/`lastName`; Keycloak 26 marks both required and `requiredActions` reads empty, which hides the cause. | Add the fields in the admin console. Fix `register.ftl` in `planelyx-auth` so it collects them. |
| **Login redirects to `planelyx.com/dashboard`** and Keycloak rejects the redirect URI | The UI build is missing the `prepareExternalUrl` / `document.baseURI` fixes, so it built redirect URLs from the origin instead of the base href. | Rebuild `ui` from a commit that includes them; redeploy with the new SHA. |
| **A deploy fails with** `manifest unknown` **or** `denied` | `REGISTRY` does not match what CI pushed to, the tag SHA is wrong, or the `docker login` credential expired. | Check `REGISTRY` ends in `/docker-remote-repo`. Re-run the `docker login` from [§11](#11-artifact-registry-access). |
| **Certificate renewal fails** | Port 80 is blocked, the `:80` server block was removed, or DNS changed. | `sudo certbot renew --dry-run` and read the error. The `:80` block must stay reachable — it is not vestigial. |
| **Disk full** | Container logs, old images, or backups. | `docker system df`, `du -sh /var/backups/planelyx`. Confirm `/etc/docker/daemon.json` log rotation is in place ([§6](#6-docker-post-install)). |
| **Random 401s that come and go** | Host clock drift making `exp`/`nbf` validation fail intermittently. | `timedatectl status` — "System clock synchronized" must be `yes`. |

### Getting a clean read on state

When something is wrong and you are not sure where, these four commands narrow it down fast:

```bash
$ docker compose -f compose.prod.yaml ps          # which containers are healthy
$ sudo ss -tlnp | grep -E '808[123]|5432|:443'    # what is actually listening
$ sudo nginx -t                                   # is the routing layer even valid
$ curl -s https://planelyx.com/auth/realms/planelyx/.well-known/openid-configuration \
    | jq -r .issuer                               # is the auth contract intact
```

---

## Appendix — quick reference

**Paths on the host**

```
~/planelyx-infra/                              compose.prod.yaml, .env  (both workflow-managed)
/etc/nginx/sites-available/planelyx            site config          (workflow-managed)
/etc/nginx/snippets/planelyx-proxy.conf        shared X-Forwarded-* headers (workflow-managed)
/etc/nginx/snippets/keycloak-proxy.conf        Keycloak headers    (auth repo installs this)
~/planelyx-infra/nginx-prev/                   previous nginx files, for rollback
/etc/letsencrypt/live/planelyx.com/            certificates
/etc/postgresql/17/main/postgresql.conf        listen_addresses
/etc/postgresql/17/main/pg_hba.conf            container access rules
/var/backups/planelyx/                         nightly dumps
/etc/docker/daemon.json                        log rotation, live-restore
```

**Ports**

```
22, 80, 443     public (ufw allow)
5432            listen_addresses='*'; kept private by ufw (172.20.0.0/16 only) + pg_hba
8081–8084      127.0.0.1 only — ui / api / auth / ocr
9000            inside the auth container only — Keycloak management + health
```

**Log noise that is not a problem.** On a single-node deployment Keycloak's Infinispan layer
always prints these, and none of them indicate a fault:

```
JGRP000015: the receive buffer of socket MulticastSocket was set to 20MB,
            but the OS only allocated 4.19MB
GMS: no members discovered after 2003 ms: creating cluster as coordinator
JGRP000014: ThreadPool.thread_dumps_threshold has been deprecated: ignored
```

There is one node, so discovering no peers and electing itself coordinator is the correct
outcome. Ignore all three and look further down the log for the real error.

**The three strings that must agree exactly**

```
compose.prod.yaml   KEYCLOAK_ISSUER_URI: https://planelyx.com/auth/realms/planelyx
Keycloak discovery  .issuer            → https://planelyx.com/auth/realms/planelyx
token payload       .iss               → https://planelyx.com/auth/realms/planelyx
```

Everything else in this document exists to make those three lines identical.
