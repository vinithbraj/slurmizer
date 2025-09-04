# base-ubuntu24-systemd/Dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install systemd + minimal tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd systemd-sysv ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

# Prepare canonical mount points
RUN mkdir -p /home /home/shared

# (Optional) create a non-root service user
# Keep UID/GID fixed to avoid host permission surprises
RUN groupadd -g 2000 app && useradd -m -u 2000 -g 2000 app && \
    chown -R app:app /home

# Declare /home and /home/shared as volumes
VOLUME ["/home", "/home/shared"]

# Allow systemd to be PID 1
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
