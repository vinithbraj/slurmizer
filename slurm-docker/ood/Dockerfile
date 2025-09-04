FROM base-ubuntu24-systemd:latest
COPY install.sh /opt/install.sh
RUN chmod +x /opt/install.sh
# Your script should install & enable slapd, configure LDAP, etc.
# Keep container entrypoint as systemd; the service should be enabled by your script.
RUN /opt/install.sh