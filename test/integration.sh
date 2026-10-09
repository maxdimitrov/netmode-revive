#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # helpers are invoked through check()
# End-to-end test against the local Docker daemon. Builds the image, runs it
# with a short grace window, and checks each rule on throwaway containers.
set -euo pipefail
export MSYS_NO_PATHCONV=1

IMG=netmode-revive:test
P=nmr-test-parent
cd "$(dirname "$0")/.."

cleanup() { docker rm -f $P nmr-test-stale nmr-test-failed nmr-test-manual nmr-test-ignored nmr-test-killed nmr-test-watcher >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

fail=0
check() { local name=$1; shift; if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi; }
started() { docker inspect -f '{{.State.StartedAt}}' "$1"; }
state() { docker inspect -f '{{.State.Status}}' "$1"; }
has_eth0() { docker exec "$1" ip -o link show eth0 >/dev/null 2>&1; }
newer() { [[ "$(started "$1")" > "$(started "$2")" ]]; }
is_state() { [ "$(state "$1")" = "$2" ]; }
same_start() { [ "$(started "$1")" = "$2" ]; }

docker build -q -t $IMG . >/dev/null

docker run -d --name $P --restart unless-stopped \
	--health-cmd true --health-interval 2s --health-start-period 1s \
	alpine:3.20 sleep infinity >/dev/null
dep() { docker run -d --name "$1" --restart always --network container:$P "${@:2}" alpine:3.20 sleep infinity >/dev/null; }
dep nmr-test-stale
dep nmr-test-failed
dep nmr-test-manual
dep nmr-test-killed
dep nmr-test-ignored --label netmode-revive.ignore=true

# nmr-test-manual: stopped on purpose, well outside the grace window.
docker stop -t 1 nmr-test-manual >/dev/null
sleep 25

docker run -d --name nmr-test-watcher -e GRACE_SECONDS=20 -e SWEEP_INTERVAL=0 \
	-v /var/run/docker.sock:/var/run/docker.sock $IMG >/dev/null
sleep 3

ignored_before=$(started nmr-test-ignored)

# Parent goes down; a dependent tries to start meanwhile and fails.
# nmr-test-killed goes down with it (e.g. docker compose stop), no error.
docker stop -t 1 nmr-test-failed nmr-test-killed $P >/dev/null
docker start nmr-test-failed >/dev/null 2>&1 || true
docker inspect -f '{{.State.Error}}' nmr-test-failed | grep -q . || { echo "setup: expected a failed start"; exit 1; }
docker start $P >/dev/null

# Wait (up to 120s, slow hosts) for the three expected actions.
for _ in $(seq 60); do
	[ "$(docker logs nmr-test-watcher 2>&1 | grep -c -e ': started (' -e ': restarted (')" -ge 3 ] && break
	sleep 2
done
sleep 2

check "stale running dependent restarted" newer nmr-test-stale $P
check "stale dependent has network again" has_eth0 nmr-test-stale
check "failed dependent started" is_state nmr-test-failed running
check "failed dependent has network" has_eth0 nmr-test-failed
check "dependent stopped with parent started" is_state nmr-test-killed running
check "manually stopped dependent left alone" is_state nmr-test-manual exited
check "ignored dependent left alone" same_start nmr-test-ignored "$ignored_before"

echo "--- watcher log"
docker logs nmr-test-watcher 2>&1
exit $fail
