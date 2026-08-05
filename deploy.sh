#!/usr/bin/env bash
#
# Pull the pinned images and restart the stack. Run from the VPS, or over SSH by
# .github/workflows/deploy.yml.
#
#   ./deploy.sh                 # whole stack
#   ./deploy.sh api             # only the api container; ui and auth keep running
#   ./deploy.sh api ui
#   ./deploy.sh --read-env-key API_TAG    # print one .env value (used by the workflow)
#
# Not zero-downtime: the API restarts in place and Flyway runs on startup, so expect a few
# seconds of 502 on /api during a deploy.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE=compose.prod.yaml
WAIT_TIMEOUT=${WAIT_TIMEOUT:-300}

# Bumped whenever the calling convention changes. The workflow asserts this before it deploys,
# because a *previous* version of this script silently ignored its arguments — against a stale
# checkout, `./deploy.sh api` would quietly redeploy all three services.
INTERFACE=v2

if [[ ${1:-} == --print-interface ]]; then
    echo "$INTERFACE"
    exit 0
fi

# Read one key out of .env, the way Compose would. The workflow calls this over SSH to carry
# forward the tags of services it was not asked to deploy, so both sides use one parser.
#
# `tail -n1` is last-key-wins, matching Compose (and never `head`, which SIGPIPEs the producer
# and trips pipefail). `tr -d '\r'` is not defensive padding: a CRLF .env yields a tag ending
# in \r, and the only symptom is `manifest unknown` for a SHA you can see in the registry.
# Only a *matched* surrounding pair of quotes is stripped. Prints nothing if the key is absent.
if [[ ${1:-} == --read-env-key ]]; then
    # The key is spliced into a sed expression below, so it has to be a plain identifier.
    if [[ ! ${2:-} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "error: --read-env-key needs a key name (letters, digits, underscore)" >&2
        exit 2
    fi
    [[ -f .env ]] || exit 0
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" .env \
        | tail -n1 \
        | tr -d '\r' \
        | sed -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'\$/\1/" -e "s/^\"\(.*\)\"\$/\1/"
    exit 0
fi

services=("$@")
for svc in ${services[@]+"${services[@]}"}; do
    case $svc in
        ui | api | auth) ;;
        *)
            echo "error: unknown service '$svc' (expected: ui, api, auth)" >&2
            exit 2
            ;;
    esac
done

if [[ ! -f .env ]]; then
    echo "error: .env not found. Copy .env.example and fill it in." >&2
    exit 1
fi

# A leftover from a workflow run that died mid-flight must never be mistaken for current
# state — the workflow's own cleanup cannot run if the SSH connection itself was the failure.
rm -f .env.staged

dump_logs() {
    echo >&2
    echo "--- last 50 log lines per deployed service ---" >&2
    docker compose -f "$COMPOSE" logs --tail 50 ${services[@]+"${services[@]}"} >&2 || true
}

# `--wait` blocks until every service it touched is running|healthy and exits non-zero
# otherwise; `--wait-timeout` is mandatory, because without it `--wait` waits forever. 300s is
# a floor, not a guess: auth's healthcheck is start_period 45s + 20 retries x 10s, and api
# runs Flyway before it reports healthy.
#
# Deploying all three takes the whole-stack path deliberately. `--no-deps` drops dependency
# edges outright — not just to services outside the selection — so `up --no-deps ui api auth`
# would start api without waiting for auth to be healthy, and api resolves the OIDC metadata
# at startup. `--remove-orphans` also belongs only here: it is a whole-stack statement, and
# scoping it to a subset risks classifying the untouched services as orphans.
if (( ${#services[@]} == 0 || ${#services[@]} == 3 )); then
    services=(ui api auth)
    docker compose -f "$COMPOSE" pull
    docker compose -f "$COMPOSE" up -d --wait --wait-timeout "$WAIT_TIMEOUT" --remove-orphans \
        || { dump_logs; exit 1; }
else
    docker compose -f "$COMPOSE" pull "${services[@]}"
    docker compose -f "$COMPOSE" up -d --wait --wait-timeout "$WAIT_TIMEOUT" --no-deps "${services[@]}" \
        || { dump_logs; exit 1; }
fi

# `--wait` settles for "running" on a service with no healthcheck, and `ui` declares none — so
# a crash-looping nginx would pass the gate the instant it came up. Give it a dwell and check
# the restart counter, which is the only signal that distinguishes the two.
if [[ " ${services[*]} " == *" ui "* ]]; then
    cid=$(docker compose -f "$COMPOSE" ps -q ui | tail -n1) || cid=""
    if [[ -z $cid ]]; then
        echo "error: ui has no container after up" >&2
        dump_logs
        exit 1
    fi

    before=$(docker inspect --format '{{.RestartCount}}' "$cid") || before=""
    sleep 15
    after=$(docker inspect --format '{{.RestartCount}}' "$cid") || after=""
    state=$(docker inspect --format '{{.State.Status}}' "$cid") || state=""

    if [[ $state != running || $after != "$before" ]]; then
        echo "error: ui is not stable (state: ${state:-unknown}, restarts: ${before:-?} -> ${after:-?})" >&2
        dump_logs
        exit 1
    fi
fi

# Dangling images only — the previous release keeps its SHA tag, so a rollback still finds it
# locally. Never add `-a`: that removes every image without a running container, which is
# precisely the set you would roll back to. `|| true` because a transient daemon error here
# must not fail a deploy that has already passed its health gate.
docker image prune -f || true

echo
docker compose -f "$COMPOSE" ps
