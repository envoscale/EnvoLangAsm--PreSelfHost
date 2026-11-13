#!/bin/sh
# CI adapter helper: install NASM on a GitHub-hosted Ubuntu runner for the
# Phase A bootstrap adapter (adapters/bootstrap/nasm). Removed in Phase B.
#
# The runners' default apt source is a mirror list pointing at
# azure.archive.ubuntu.com, which has repeatedly failed DNS resolution. So:
#   1. try the runner's default sources, with short timeouts;
#   2. if that fails, show what DNS resolves, point apt straight at
#      archive.ubuntu.com, and try again.
# apt verifies package signatures either way; only the download host changes.
set -u

apt_opts="-o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20"

try_apt() {
    # shellcheck disable=SC2086
    sudo apt-get $apt_opts update -q || true
    # shellcheck disable=SC2086
    sudo apt-get $apt_opts install -y -q nasm
}

if command -v nasm >/dev/null 2>&1; then
    nasm -v
    exit 0
fi

echo "::group::apt: runner default sources"
if try_apt; then
    echo "::endgroup::"
    nasm -v
    exit 0
fi
echo "::endgroup::"

echo "Default sources failed. DNS check:"
for host in azure.archive.ubuntu.com archive.ubuntu.com security.ubuntu.com; do
    if getent hosts "$host" >/dev/null 2>&1; then echo "  $host: resolves"; else echo "  $host: DOES NOT resolve"; fi
done

echo "::group::apt: archive.ubuntu.com directly"
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    sudo sed -i \
        -e 's|mirror+file:/etc/apt/apt-mirrors.txt|http://archive.ubuntu.com/ubuntu/|g' \
        -e 's|http://azure.archive.ubuntu.com/ubuntu|http://archive.ubuntu.com/ubuntu|g' \
        "$f"
done
if try_apt; then
    echo "::endgroup::"
    nasm -v
    exit 0
fi
echo "::endgroup::"
echo "error: could not install NASM from any Ubuntu source" >&2
exit 1
