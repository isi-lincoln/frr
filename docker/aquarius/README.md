# docker/aquarius — the Aquarius FRR lab image

An on-demand container image of **this FRR checkout** for the aquarius labs
(raven / containerlab), on an `ubuntu:24.04` base, with the tooling to
**see, report on, test, and shape** traffic entering the node:

| tool | package | use |
|------|---------|-----|
| `tcpdump` | tcpdump | see / capture traffic on the wire |
| `ping` / `ping6` | iputils-ping | test reachability (the regression harness pings from nodes) |
| `tc` | iproute2 | traffic control / shaping — `netem`, `htb`, `tbf`, … |
| `iperf3` | iperf3 | generate / measure test traffic |
| `node_exporter` | pinned release | report metrics (per-interface counters, …) on `:9100` |
| `sshd` | openssh-server | management login without `docker exec` — see below |

FRR itself is the same build the lab installs (built via `debian/control`
build-deps + the FRR apt repo for libyang, `dpkg-buildpackage`), so `isisd`,
`pathd`, and the `pathd_pcep` module are all present.

## Login

The entrypoint starts `sshd` before `watchfrr`. One account:

| | |
|---|---|
| user | `soqn` |
| password | `soqn` |
| key | the public key given at build time (`SSH_PUBKEY`, default `../demo-topologies/images/lab_ssh_key.pub`); no key found -> password only |
| sudo | passwordless (`/etc/sudoers.d/soqn`) |
| groups | `sudo`, `frr`, `frrvty` — `vtysh` works without sudo |

```sh
ssh -i demo-topologies/images/lab_ssh_key soqn@<node-mgmt-ip>
```

**These are lab credentials, baked into the image.** Fine on a closed testbed
management network; do not run this image anywhere that port 22 is reachable by
anyone you would not hand root to. Host keys are generated at build time, so
every container from one image shares them (a node rebuilt at the same address
does not trip `known_hosts`).

The sshd drop-in is `/etc/ssh/sshd_config.d/zz-aquarius-base.conf`, named to
sort LAST: sshd keeps the first value it reads, so a derived image's own drop-in
wins. The demo labs' image (`demo-topologies/images/Dockerfile.frr`) sets
`PasswordAuthentication no` — there `soqn` is key-only, and `root` also has the
lab key.

## Build

Run it whenever FRR changes — it builds from the **working tree**, so
uncommitted edits are included:

```sh
# from the frr/ checkout root
./docker/aquarius/build.sh                          # tag isilincoln/frr:demo-<sha>
IMAGE=isilincoln/frr:demo-v0.0.1 ./docker/aquarius/build.sh   # explicit tag
./docker/aquarius/build.sh --save                   # + docker save to ../frr-aquarius-demo.tar
./docker/aquarius/build.sh --push                   # + docker push
```

`NODE_EXPORTER_VERSION` overrides the metrics exporter version (default 1.8.2).

The entrypoint is `watchfrr` (like the official FRR image); node_exporter is
baked in but **not** auto-started — scrape or `docker exec` it as the
monitoring tooling does.

## Using the tools

```sh
# see traffic on a link
docker exec <node> tcpdump -ni eth1 -c 20
# test reachability
docker exec <node> ping -c3 10.0.0.2
# shape a link: 50ms delay + 1% loss, or a 1mbit ceiling
docker exec <node> tc qdisc add dev eth1 root netem delay 50ms loss 1%
docker exec <node> tc qdisc replace dev eth1 root tbf rate 1mbit burst 32kbit latency 400ms
# report metrics
docker exec -d <node> /usr/local/bin/node_exporter        # then scrape :9100/metrics
```
