# Docker CLI 27 still negotiates down to older daemons (e.g. Synology's 24.x).
FROM docker:27.5.1-cli
RUN apk add --no-cache tini
COPY netmode-revive.sh /usr/local/bin/netmode-revive
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/netmode-revive"]
