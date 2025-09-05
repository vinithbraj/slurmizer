FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y systemd systemd-sysv slapd ldap-utils && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY /src/ldap-server.sh /opt/ldap-server.sh
COPY /src/ldap-add-user.sh /opt/ldap-add-user.sh
COPY /slurm-docker/ldap/install.sh /opt/install.sh

# Make them executable
RUN chmod +x /opt/install.sh /opt/ldap-server.sh /opt/ldap-add-user.sh

RUN chmod +x /opt/install.sh
RUN /opt/install.sh

CMD ["/sbin/init"]