FROM base-ubuntu24-systemd:latest

# Reuse the standard storage dir
ENV STORAGE_DIR=/srv/storage

# We'll export a subdir under the standard storage
RUN mkdir -p ${STORAGE_DIR}/home  ${STORAGE_DIR}/shared/scratch


COPY install.sh /opt/install.sh
RUN chmod +x /opt/install.sh
# Your script should install & enable slapd, configure LDAP, etc.
# Keep container entrypoint as systemd; the service should be enabled by your script.
RUN /opt/install.sh