#!/bin/sh
# netmode-revive -- keep containers that share another container's network
# namespace (network_mode: "service:x" / "container:x") alive across restarts
# of x.
#
# Docker's restart policy does not cover this. When x restarts:
#   - a dependent that keeps running is stuck in x's old, dead namespace and
#     has no network at all;
#   - a dependent whose own restart races x fails to start ("cannot join
#     network of a non running container", "namespace path ... no such file")
#     and Docker leaves it stopped for good.
#
# Rule, applied on every container start event and on a periodic sweep:
#   - running dependent that started before its parent  -> docker restart
#   - stopped dependent whose last start failed, or that stopped in the
#     GRACE_SECONDS before the parent's latest start      -> docker start
# Containers labelled netmode-revive.ignore=true are left alone.

set -u

GRACE_SECONDS=${GRACE_SECONDS:-300}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}
SWEEP_INTERVAL=${SWEEP_INTERVAL:-300}
DRY_RUN=${DRY_RUN:-false}

WARNED=/tmp/netmode-revive.warned
: >"$WARNED"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# RFC 3339 timestamp from docker inspect -> epoch seconds (0 if never set).
epoch() {
	t=${1%%.*}
	t=${t%Z}
	date -u -d "$(echo "$t" | tr T ' ')" +%s 2>/dev/null || echo 0
}

# Wait until the container is running and, if it has a healthcheck, healthy.
# Returns 1 if it stopped, 2 on timeout.
wait_healthy() {
	waited=0
	while :; do
		h=$(docker inspect -f '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null) || return 1
		case $h in
		"true healthy" | "true none") return 0 ;;
		false*) return 1 ;;
		esac
		[ "$waited" -ge "$HEALTH_TIMEOUT" ] && return 2
		sleep 5
		waited=$((waited + 5))
	done
}

act() { # act <start|restart> <container-name> <reason>
	if [ "$DRY_RUN" = true ]; then
		log "$2: would $1 ($3)"
		return
	fi
	if out=$(docker "$1" "$2" 2>&1); then
		log "$2: ${1}ed ($3)"
	else
		log "$2: $1 failed: $out"
	fi
}

# reconcile [parent-id]: fix the dependents of one parent, or of all parents.
reconcile() {
	only=${1:-}
	ids=$(docker ps -aq)
	[ -n "$ids" ] || return 0
	# shellcheck disable=SC2086 # word splitting of $ids is intended
	docker inspect -f '{{.ID}}|{{.Name}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.RestartPolicy.Name}}|{{.State.Running}}|{{.State.StartedAt}}|{{.State.FinishedAt}}|{{index .Config.Labels "netmode-revive.ignore"}}|{{.State.Error}}' $ids 2>/dev/null |
		grep '^[^|]*|[^|]*|container:' |
		while IFS='|' read -r id name mode policy running started finished ignore err; do
			name=${name#/}
			parent=${mode#container:}
			[ "$ignore" = true ] && continue

			if ! pinfo=$(docker inspect -f '{{.ID}} {{.Name}} {{.State.Running}} {{.State.StartedAt}}' "$parent" 2>/dev/null); then
				if ! grep -qx "$id" "$WARNED"; then
					echo "$id" >>"$WARNED"
					log "$name: its network parent $parent no longer exists; recreate it (e.g. docker compose up -d)"
				fi
				continue
			fi
			# shellcheck disable=SC2086 # split "id name running started"
			set -- $pinfo
			pid=$1 pname=${2#/} prunning=$3 pstart=$(epoch "$4")
			[ -n "$only" ] && [ "$pid" != "$only" ] && continue
			[ "$prunning" = true ] || continue

			if [ "$running" = true ]; then
				[ "$(epoch "$started")" -lt "$pstart" ] || continue
				reason="started before $pname, stuck in its old network namespace"
				verb=restart
			else
				case $policy in always | unless-stopped | on-failure) ;; *) continue ;; esac
				fin=$(epoch "$finished")
				if [ -n "$err" ]; then
					reason="last start failed: $err"
				elif [ "$fin" -ge $((pstart - GRACE_SECONDS)) ] && [ "$fin" -le "$pstart" ]; then
					reason="stopped when $pname restarted"
				else
					continue
				fi
				verb=start
			fi

			wait_healthy "$pid"
			case $? in
			1) continue ;;
			2) log "$pname: not healthy after ${HEALTH_TIMEOUT}s, going ahead with $name" ;;
			esac
			act "$verb" "$name" "$reason"
		done
}

log "starting: grace=${GRACE_SECONDS}s health_timeout=${HEALTH_TIMEOUT}s sweep=${SWEEP_INTERVAL}s dry_run=$DRY_RUN"
docker version --format 'docker server {{.Server.Version}} (API {{.Server.APIVersion}})' || exit 1

reconcile
if [ "$SWEEP_INTERVAL" -gt 0 ]; then
	(while sleep "$SWEEP_INTERVAL"; do reconcile; done) &
fi

docker events --filter type=container --filter event=start --format '{{.Actor.ID}}' |
	while read -r cid; do reconcile "$cid"; done

log "docker event stream ended, exiting"
exit 1
