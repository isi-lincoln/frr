# Aquarius FRR container image.
#
# FRR built from THIS checkout (the working tree, so uncommitted changes are
# included) on an ubuntu:24.04 base, plus the tooling to observe, test, and
# shape traffic entering the container:
#
#   tcpdump        capture / see traffic on the wire
#   iputils-ping   test reachability (the regression harness pings from nodes)
#   iproute2 (tc)  traffic control / shaping — netem, htb, tbf, ...
#   iperf3         generate / measure test traffic
#   node_exporter  export metrics (per-interface counters, etc.) on :9100
#   openssh-server management access without `docker exec`: user `soqn`
#                  (password `soqn`, the lab public key, passwordless sudo, and
#                  in the frr/frrvty groups so vtysh works unprivileged). sshd
#                  is started by the entrypoint. LAB CREDENTIALS — this image is
#                  for closed testbeds, never an exposed network.
#
# Built by build.sh, which stages a clean context. Multi-stage: compile the FRR
# .debs in a builder, then install them on a clean runtime with the tools.

ARG NODE_EXPORTER_VERSION=1.8.2

# ---------- builder ----------
FROM ubuntu:24.04 AS builder
ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_EXPORTER_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg build-essential fakeroot devscripts equivs \
      dpkg-dev autoconf automake libtool make pkg-config \
 && install -d /etc/apt/keyrings \
 && curl -fsSL https://deb.frrouting.org/frr/keys.gpg -o /etc/apt/keyrings/frr.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/frr.gpg] https://deb.frrouting.org/frr noble frr-stable" \
      > /etc/apt/sources.list.d/frr.list \
 && apt-get update
WORKDIR /src
COPY . /src
# Authoritative build-deps straight from debian/control (libyang, pcre2,
# sphinx, protobuf-c, ... — never a hand-typed list).
RUN mk-build-deps -t "apt-get -y --no-install-recommends" -i -r debian/control
# A fresh checkout ships no generated ./configure; bootstrap it, then build the
# binary .debs with dpkg-buildpackage (needs no git objects, so it works from a
# submodule checkout).
RUN ./bootstrap.sh
RUN DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -us -uc
# node_exporter (metrics), pinned.
RUN curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
      -o /tmp/ne.tgz && tar -xzf /tmp/ne.tgz -C /tmp \
 && install -m0755 "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" \
      /usr/local/bin/node_exporter

# ---------- runtime ----------
FROM ubuntu:24.04 AS runtime
ARG DEBIAN_FRONTEND=noninteractive
LABEL org.opencontainers.image.title="frr-aquarius"
# tini reaps zombies; iproute2 gives ip + tc (shape); tcpdump sees; iputils-ping
# tests. procps for ps/top when debugging inside the node.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg tini iproute2 tcpdump procps iputils-ping \
      iperf3 openssh-server sudo snmpd snmp \
 && install -d /etc/apt/keyrings \
 && curl -fsSL https://deb.frrouting.org/frr/keys.gpg -o /etc/apt/keyrings/frr.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/frr.gpg] https://deb.frrouting.org/frr noble frr-stable" \
      > /etc/apt/sources.list.d/frr.list \
 && apt-get update
COPY --from=builder /frr_*.deb /frr-pythontools_*.deb /frr-snmp_*.deb /tmp/debs/
COPY --from=builder /usr/local/bin/node_exporter /usr/local/bin/node_exporter
RUN apt-get install -y --no-install-recommends /tmp/debs/frr_*.deb /tmp/debs/frr-pythontools_*.deb /tmp/debs/frr-snmp_*.deb \
 && mkdir -p /var/run/frr && chown -R frr:frr /etc/frr /var/run/frr \
 && ([ -e /usr/bin/ping6 ] || ln -sf /usr/bin/ping /usr/bin/ping6) \
 && printf '#!/bin/bash\n[ -x /usr/sbin/sshd ] && { mkdir -p /run/sshd; /usr/sbin/sshd; }\n[ -x /usr/sbin/snmpd ] && { mkdir -p /var/agentx; /usr/sbin/snmpd -C -c /etc/snmp/snmpd.conf -LS0-4d -p /run/snmpd.pid; }\nsource /usr/lib/frr/frrcommon.sh\nexec /usr/lib/frr/watchfrr $(daemon_list)\n' \
      > /usr/lib/frr/docker-start && chmod 0755 /usr/lib/frr/docker-start \
 && rm -rf /tmp/debs /var/lib/apt/lists/*
# SNMP: snmpd is the AgentX master; FRR daemons started with `-M snmp` and
# `agentx` in frr.conf register their MIBs with it (BGP4-MIB, ISIS-MIB,
# OSPF-MIB ...) through /var/agentx/master. Read-only community `public`, for
# the testbed monitoring on the management network. Started by docker-start
# before watchfrr. `snmp` is the client (snmpwalk) for checking from inside.
RUN printf 'agentaddress udp:161,udp6:161\nrocommunity public default\nrocommunity6 public default\nmaster agentx\nagentXSocket /var/agentx/master\nagentXPerms 0777 0755\n' \
      > /etc/snmp/snmpd.conf
# Management login. Host keys are generated here, so every container from this
# image shares them — deliberate for a lab: a node rebuilt at the same address
# does not trip known_hosts. The sshd drop-in is named to sort LAST, because
# sshd keeps the first value it reads: a derived image's own drop-in (the demo
# labs turn password login off) therefore wins over this one.
COPY authorized_keys /tmp/authorized_keys
RUN useradd -m -s /bin/bash -G sudo,frr,frrvty soqn \
 && echo 'soqn:soqn' | chpasswd \
 && echo 'soqn ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/soqn && chmod 0440 /etc/sudoers.d/soqn \
 && install -d -m 0700 -o soqn -g soqn /home/soqn/.ssh \
 && install -m 0600 -o soqn -g soqn /tmp/authorized_keys /home/soqn/.ssh/authorized_keys \
 && rm -f /tmp/authorized_keys \
 && ssh-keygen -A && mkdir -p /run/sshd \
 && printf 'PasswordAuthentication yes\nPubkeyAuthentication yes\nPermitRootLogin prohibit-password\n' \
      > /etc/ssh/sshd_config.d/zz-aquarius-base.conf
# node_exporter's default port; scrape it or exec it — it is not auto-started
# (the entrypoint is watchfrr, matching the official FRR image).
EXPOSE 9100 22 161/udp
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/lib/frr/docker-start"]
