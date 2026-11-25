#!/usr/bin/env bash
# Host-side checks for the quetz-prod compose stack. Two modes, each run by its own timer
# through quetz-watchdog@.service, as root:
#
#   quetz-watchdog heal       every minute: appends `docker stats` to $LOG_DIR/stats.csv and, when
#                             Docker marks Quetz unhealthy, saves evidence and restarts it.
#   quetz-watchdog deepcheck  every 5 min: HEADs repodata on the main channels and logs FAILED
#                             (and fails the run) when Quetz can't serve it but the upstream
#                             can. Never restarts anything.
#
# Installed to /usr/local/sbin, outside the checkout, and uses only container names, so
# checking out any branch can't break it. Everything it reports goes to stdout (the journal)
# and $LOG_DIR; there are no alerts yet.
set -uo pipefail

CONTAINER=${QUETZ_CONTAINER:-quetz-prod-quetz-1}
POSTGRES_CONTAINER=${QUETZ_POSTGRES_CONTAINER:-quetz-prod-postgres-1}
LOG_DIR=${QUETZ_LOG_DIR:-/var/log/quetz}
MAX_INCIDENTS_PER_HOUR=${QUETZ_MAX_INCIDENTS_PER_HOUR:-3}
INCIDENTS="$LOG_DIR/incidents"
QUETZ_URL=${QUETZ_URL:-http://127.0.0.1:8000}
# QUETZ_DEEPCHECK_API_KEY: read-only API key, from /etc/quetz/deepcheck.env.

# channel|upstream URL of the same file ("-" for a local channel)
DEEPCHECKS=(
    "conda-forge|https://conda.anaconda.org/conda-forge/noarch/repodata.json"
    "anaconda-main|https://repo.anaconda.com/pkgs/main/noarch/repodata.json"
    "esss|-"
)

container_health() {
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo missing
}

record_stats() {
    local stats="$LOG_DIR/stats.csv"
    [[ -s "$stats" ]] || echo "time,container,health,cpu,mem_usage,mem_pct,pids,net_io,block_io" > "$stats"
    local now
    now=$(date -u +%FT%TZ)
    timeout 25 docker stats --no-stream \
        --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.PIDs}},{{.NetIO}},{{.BlockIO}}' \
        "$CONTAINER" "$POSTGRES_CONTAINER" 2>/dev/null |
        while IFS=, read -r name rest; do
            echo "$now,$name,$(container_health "$name"),$rest"
        done >> "$stats"
}

save_evidence() {
    local dir=$1
    # py-spy needs root inside the container (CAP_SYS_PTRACE is only effective for root).
    # shellcheck disable=SC2016
    timeout 60 docker exec -u 0 "$CONTAINER" sh -c '
        for p in /proc/[0-9]*; do
            pid=${p#/proc/}
            [ "$pid" = 1 ] || [ "$pid" = "$$" ] && continue
            cmd=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
            case "$cmd" in
                *python*)
                    echo "===== pid $pid: $cmd"
                    timeout 20 py-spy dump --pid "$pid" 2>&1
                    ;;
            esac
        done' > "$dir/py-spy.txt" 2>&1
    timeout 30 docker logs --timestamps --tail 2000 "$CONTAINER" > "$dir/quetz.log" 2>&1
    docker inspect -f '{{json .State}}' "$CONTAINER" > "$dir/state.json" 2>&1
    tail -n 240 "$LOG_DIR/stats.csv" > "$dir/stats.csv" 2>/dev/null
    { date -u; uptime; free -m; } > "$dir/host.txt" 2>&1
}

heal() {
    mkdir -p "$INCIDENTS"
    record_stats

    [[ "$(container_health "$CONTAINER")" == unhealthy ]] || return 0

    local recent
    recent=$(find "$INCIDENTS" -mindepth 1 -maxdepth 1 -type d -mmin -60 | wc -l)
    if (( recent >= MAX_INCIDENTS_PER_HOUR )); then
        # Back off: restarting in a loop would hide the cause; it needs a person.
        echo "unhealthy, but $recent incidents in the last hour: backing off, NOT restarting (evidence in $INCIDENTS)"
        return 0
    fi

    local dir
    dir="$INCIDENTS/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$dir"
    echo "unhealthy: saving evidence to $dir"
    save_evidence "$dir"

    echo "restarting $CONTAINER"
    if timeout 60 docker restart -t 10 "$CONTAINER" > "$dir/restart.txt" 2>&1; then
        echo "restarted $CONTAINER; evidence in $dir"
    else
        echo "FAILED to restart $CONTAINER (see $dir/restart.txt)"
        return 1
    fi
}

head_status() {
    # $1 = URL; the API key, when set, goes through stdin, never argv.
    local url=$1
    if [[ -n "${QUETZ_DEEPCHECK_API_KEY:-}" && "$url" == "$QUETZ_URL"* ]]; then
        curl -sS -I -o /dev/null -m 60 -w '%{http_code}' --config - "$url" <<EOF 2>/dev/null
header = "X-API-Key: $QUETZ_DEEPCHECK_API_KEY"
EOF
    else
        curl -sS -I -o /dev/null -m 60 -w '%{http_code}' "$url" 2>/dev/null
    fi
}

deepcheck() {
    # /health/live only proves the server answers; this goes through the channel code, the
    # database and, for proxy channels, the upstream. Proxy repodata is cached for the
    # channel's TTL, so most runs are cache hits.
    mkdir -p "$LOG_DIR"
    local check channel upstream status upstream_status detail failed=0
    for check in "${DEEPCHECKS[@]}"; do
        channel=${check%%|*}
        upstream=${check#*|}
        status=$(head_status "$QUETZ_URL/get/$channel/noarch/repodata.json")
        echo "$(date -u +%FT%TZ),$channel,$status" >> "$LOG_DIR/deepcheck.csv"
        [[ "$status" == 200 ]] && continue

        if [[ "$upstream" != - ]]; then
            upstream_status=$(head_status "$upstream")
            if [[ "$upstream_status" != 200 ]]; then
                echo "$channel: Quetz $status, upstream $upstream_status too (upstream problem)"
                continue
            fi
            detail="upstream answers $upstream_status"
        else
            detail="local channel"
        fi

        echo "FAILED $channel: /get/$channel/noarch/repodata.json returns ${status:-no answer} ($detail)"
        failed=1
    done
    # A failed run shows up in `systemctl --failed` and the journal.
    return $failed
}

case ${1:-} in
    heal) heal ;;
    deepcheck) deepcheck ;;
    *) echo "usage: quetz-watchdog heal|deepcheck" >&2; exit 2 ;;
esac
