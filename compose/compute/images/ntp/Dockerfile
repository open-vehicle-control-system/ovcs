# Serves this node's clock to the vehicle network. The host's own
# chronyd keeps that clock (balenaOS syncs it to the NTP pools when
# online, the RTC otherwise) but serves nobody; this one only serves.
FROM alpine:3.22

RUN apk add --no-cache chrony

COPY chrony.conf /etc/chrony/chrony.conf

# -x: leave the clock to the host's chronyd, so no CAP_SYS_TIME. A
# restarted container keeps the last run's pid file, whose pid 1 is this
# chronyd again, which then refuses to start.
ENTRYPOINT ["sh", "-c", "rm -f /run/chrony/chronyd.pid && exec chronyd -d -x -f /etc/chrony/chrony.conf"]
