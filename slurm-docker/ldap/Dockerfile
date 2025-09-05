# ubuntu 24.04 with systemd
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# Base tools + systemd
RUN apt-get update && \
    apt-get install -y --no-install-recommends systemd systemd-sysv dbus ca-certificates iproute2 iputils-ping nano vim curl less \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# (Optional) enable ssh server for VM-like feel
# RUN apt-get update && apt-get install -y --no-install-recommends openssh-server && \
#     mkdir -p /var/run/sshd && systemctl enable ssh

COPY /src/ldap-server.sh /opt/ldap-server.sh
COPY /src/ldap-add-user.sh /opt/ldap-add-user.sh
COPY /slurm-docker/ldap/install.sh /opt/install.sh

# Make them executable, don't run install, this will be done within the container manually 
RUN chmod +x /opt/install.sh /opt/ldap-server.sh /opt/ldap-add-user.sh
RUN chmod +x /opt/install.sh
# RUN /opt/install.sh

# Workaround: avoid trying to run getty on non-existent TTYs in containers
RUN systemctl set-default multi-user.target || true

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]


#
# Build the docker image
#
# docker build --network=host  -t ldap -f slurm-docker/ldap/Dockerfile .

# Run the docker using
# docker run -d --name ldaptest \
#   --privileged --cgroupns=host \
#   -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
#   ldap:latest
# 
# or using docker-compose
# docker-compose up -d
#
# Bash into the container using 
# docker exec -it ldap bash
#

# Inspect docker IP 
# docker port ldaptestdocker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ldaptest
#
# Validation on MAC
#
# brew install openldap
# ldapsearch -x -H ldap://localhost -b "dc=lab,dc=local"
#
#ldapsearch -x -H ldap://localhost -b "dc=lab,dc=local" -D "cn=user1,dc=lab,dc=local" -w pass123
