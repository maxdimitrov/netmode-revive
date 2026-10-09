# netmode-revive

Keeps containers that share another container's network
(`network_mode: "service:gluetun"`, `--network container:vpn`) working after
that container restarts.

## The problem

A typical VPN setup routes several containers through one gateway container,
such as [gluetun](https://github.com/qdm12/gluetun). Docker joins each
dependent to the gateway's network namespace when the dependent starts. When the
gateway restarts, two things go wrong, and Docker fixes neither of them:

- **Dependents that keep running are left in the old, dead namespace.** They have
  no network at all until someone restarts them by hand.
- **Dependents whose own restart races the gateway's fail to start**, with
  `cannot join network namespace of a non running container` or
  `namespace path: lstat /proc/<pid>/ns/net: no such file or directory`.
  `restart: always` doesn't retry a failed start, so they stay down.

Compose's `depends_on: {condition: service_healthy, restart: true}` only covers
restarts that Compose itself performs. It does nothing for `docker restart`, a
daemon or Container Manager restart, or an image updater. Healthcheck-based
restarters (autoheal, deunhealth) only act on running containers marked
`unhealthy`, so they don't cover either case.

## What it does

netmode-revive watches Docker's container `start` events and also sweeps
periodically. For every container whose network mode is `container:<parent>`,
and whose parent is running (and healthy, if the parent has a healthcheck):

| Dependent state | Action |
|---|---|
| running, but started before the parent's current start | `docker restart` |
| stopped, and its last start failed (`State.Error` set) | `docker start` |
| stopped within `GRACE_SECONDS` before the parent's latest start | `docker start` |

It only *starts* stopped containers whose restart policy is `always`,
`unless-stopped` or `on-failure`. A container you stopped yourself is left
stopped, unless you stopped it in the grace window just before the parent came
back. To keep netmode-revive away from a container, label it
`netmode-revive.ignore=true`.

If a dependent points at a parent that no longer exists (the parent was
*recreated*, not restarted), netmode-revive can't fix it, because the network
mode is fixed when a container is created. In that case it logs one warning
telling you to recreate the dependent (`docker compose up -d`).

## Usage

Add it to the same compose file as the gateway:

```yaml
services:
  netmode-revive:
    image: ghcr.io/maxdimitrov/netmode-revive:latest
    container_name: netmode-revive
    network_mode: none
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
```

It needs the Docker socket. It only reads container state and calls
`docker start` / `docker restart`, but socket access is root-equivalent, so
read [the script](netmode-revive.sh) before you run it. It's ~130 lines of
POSIX sh.

### Settings

| Variable | Default | Meaning |
|---|---|---|
| `GRACE_SECONDS` | `300` | How long before the parent's start a dependent may have stopped and still be brought back |
| `HEALTH_TIMEOUT` | `180` | Seconds to wait for the parent to become healthy; after that it acts anyway |
| `SWEEP_INTERVAL` | `300` | Seconds between full sweeps, as a backstop for missed events; `0` turns sweeps off |
| `DRY_RUN` | `false` | `true` logs what it would do without doing it |

The image uses Docker CLI 27, which negotiates down to older daemons (tested
against Docker 24 on Synology DSM 7.3 and Docker 29).

## Testing

`test/integration.sh` builds the image and runs every rule above against
throwaway containers on the local Docker daemon. CI runs it on every push.

## License

MIT
