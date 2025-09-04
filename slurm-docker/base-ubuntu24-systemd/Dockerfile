# base-ubuntu24-systemd/Dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# Standard storage mount path used by all derived images
ENV STORAGE_DIR=/srv/storage

# Install systemd + minimal tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd systemd-sysv ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

# Prepare the storage mount point
RUN mkdir -p ${STORAGE_DIR}

# (Optional) create a non-root service user that owns the storage
# Keep UID/GID fixed to avoid host permission surprises
RUN groupadd -g 2000 app && useradd -m -u 2000 -g 2000 app && \
    chown -R app:app ${STORAGE_DIR}

# Declare as a volume (containers can still bind-mount over it)
VOLUME ["/srv/storage"]

# Allow systemd to be PID 1
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
