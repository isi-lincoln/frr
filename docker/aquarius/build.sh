#!/usr/bin/env bash
# Build the Aquarius FRR container image from THIS frr checkout.
#
# Run on-demand after changing FRR — it builds from the WORKING TREE, so
# uncommitted changes are included. The image bakes in tcpdump (see traffic),
# ping (test), tc via iproute2 (shape), and node_exporter (report metrics), on
# an ubuntu:24.04 base. See Dockerfile.
#
#   ./docker/aquarius/build.sh                     build, tag isilincoln/frr:demo-<sha>
#   IMAGE=isilincoln/frr:demo-v0.0.1 ./...build.sh explicit tag
#   ./docker/aquarius/build.sh --save [file.tar]   also `docker save` to a tar
#   ./docker/aquarius/build.sh --push              also `docker push` the tag
#   NODE_EXPORTER_VERSION=1.8.2 ./...build.sh       override node_exporter version
#   SSH_PUBKEY=path/to/key.pub ./...build.sh        public key for the `soqn` login
#                                                   (default: the demo labs' lab_ssh_key.pub;
#                                                   none found -> password login only)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRR="$(cd "$HERE/../.." && pwd)"   # the frr repo root (this dir is frr/docker/aquarius)

SHA="$(git -C "$FRR" rev-parse --short HEAD 2>/dev/null || echo dev)"
IMAGE="${IMAGE:-isilincoln/frr:demo-$SHA}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"

SAVE=""; PUSH=""; SAVE_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --save) SAVE=1; case "${2:-}" in ""|--*) ;; *) SAVE_FILE="$2"; shift ;; esac ;;
        --push) PUSH=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
SAVE_FILE="${SAVE_FILE:-$FRR/frr-aquarius-demo.tar}"

# Stage a clean build context: the working tree minus .git, the docker/ dir
# (build cruft + other distros' images, not needed to compile FRR), and any
# compiled artifacts. Building from a staged copy keeps the checkout untouched
# and the context small/fast, and never depends on a repo .dockerignore.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
rsync -a \
    --exclude='.git' --exclude='/docker/' \
    --exclude='*.o' --exclude='*.lo' --exclude='*.la' --exclude='*.a' \
    --exclude='*.so' --exclude='.libs/' --exclude='/build/' \
    "$FRR"/ "$STAGE"/
cp "$HERE/Dockerfile" "$STAGE/Dockerfile"

# The public key baked in for the `soqn` user. The Dockerfile always COPYs the
# file, so an absent key becomes an empty authorized_keys, not a failed build.
SSH_PUBKEY="${SSH_PUBKEY:-$FRR/../demo-topologies/images/lab_ssh_key.pub}"
if [ -f "$SSH_PUBKEY" ]; then
    cp "$SSH_PUBKEY" "$STAGE/authorized_keys"
    echo ">> ssh key for soqn: $SSH_PUBKEY"
else
    : > "$STAGE/authorized_keys"
    echo ">> no ssh public key at $SSH_PUBKEY — soqn will be password-only"
fi
printf '.git\ndocker/\n' > "$STAGE/.dockerignore"

echo ">> building $IMAGE  (frr @ $SHA, node_exporter $NODE_EXPORTER_VERSION)"
docker build --build-arg NODE_EXPORTER_VERSION="$NODE_EXPORTER_VERSION" \
    -t "$IMAGE" "$STAGE"

echo ">> tools baked in:"
docker run --rm --entrypoint sh "$IMAGE" -c \
    'for t in tcpdump ping tc iperf3 sshd sudo node_exporter vtysh; do \
        printf "   %-14s" "$t"; command -v "$t" || echo MISSING; done'

if [ -n "$SAVE" ]; then
    echo ">> docker save -> $SAVE_FILE"
    docker save "$IMAGE" -o "$SAVE_FILE"
    ls -lh "$SAVE_FILE"
fi
if [ -n "$PUSH" ]; then
    echo ">> docker push $IMAGE"
    docker push "$IMAGE"
fi
echo ">> done: $IMAGE"
