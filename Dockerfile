# mqvpn server image (Multipath QUIC VPN, https://github.com/mp0rta/mqvpn).
#
# Two ways to get the mqvpn binary, selected with MQVPN_BUILD_METHOD:
#   release (default) - official GitHub release tarball for the target
#                       architecture, verified against a pinned SHA-256.
#   source            - build the pinned git tag from source, verified against a
#                       pinned commit hash (same build steps as upstream's
#                       release workflow).
#
# Supported platforms: linux/amd64, linux/arm64.
# Normally built through compose.yaml, which passes the build args from .env.
# Requires BuildKit (default since Docker 23) for ADD --checksum.

# Ubuntu 24.04 LTS, pinned by multi-arch index digest. Upstream supports
# Ubuntu 22.04+ / Debian 12+; the release binary needs glibc >= 2.34.
ARG BASE_IMAGE=ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
ARG MQVPN_BUILD_METHOD=release

# ---------------------------------------------------------------------------
# release: official tarballs. One stage per architecture so each ADD carries
# its own pinned checksum; BuildKit only builds the stage it needs.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS release-amd64
ARG MQVPN_VERSION=0.19.2
ARG MQVPN_SHA256_AMD64=d337086464b04ae90653a2a4402aa56f19fb001dcea60d0eb4e404d1e4bba863
ADD --checksum=sha256:${MQVPN_SHA256_AMD64} \
    https://github.com/mp0rta/mqvpn/releases/download/v${MQVPN_VERSION}/mqvpn_${MQVPN_VERSION}_amd64.tar.gz \
    /tmp/mqvpn.tar.gz

FROM ${BASE_IMAGE} AS release-arm64
ARG MQVPN_VERSION=0.19.2
ARG MQVPN_SHA256_ARM64=a4b7dfe9510a949c7d9cd81679071589c6d2efea2dfd735623f5cadc8abd6c5a
ADD --checksum=sha256:${MQVPN_SHA256_ARM64} \
    https://github.com/mp0rta/mqvpn/releases/download/v${MQVPN_VERSION}/mqvpn_${MQVPN_VERSION}_arm64.tar.gz \
    /tmp/mqvpn.tar.gz

FROM release-${TARGETARCH} AS bin-release
# Layout of the release tarball: bin/mqvpn, lib/mqvpn/mqvpn-nat-config,
# LICENSE, NOTICE, third-party/*.txt (plus systemd files we do not use).
RUN set -eu; \
    mkdir -p /tmp/x /out/bin /out/lib/mqvpn /out/share/doc/mqvpn; \
    tar -xzf /tmp/mqvpn.tar.gz -C /tmp/x; \
    install -m 0755 /tmp/x/bin/mqvpn /out/bin/mqvpn; \
    install -m 0755 /tmp/x/lib/mqvpn/mqvpn-nat-config /out/lib/mqvpn/mqvpn-nat-config; \
    cp -a /tmp/x/LICENSE /tmp/x/NOTICE /tmp/x/third-party /out/share/doc/mqvpn/; \
    rm -rf /tmp/x /tmp/mqvpn.tar.gz

# ---------------------------------------------------------------------------
# source: build the pinned tag (BoringSSL -> xquic -> mqvpn), mirroring
# .github/workflows/release.yml of the same tag. XQUIC_BUILD_DIR must be an
# absolute path: upstream's CMake tests it with EXISTS to link the static
# libxquic (as the release binary does).
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS bin-source
ARG MQVPN_VERSION=0.19.2
ARG MQVPN_GIT_COMMIT=74e2cd09b1cc811902e795a597390ceef503ad7e
RUN set -eu; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential cmake git golang-go libevent-dev perl; \
    rm -rf /var/lib/apt/lists/*
# BuildKit's git source also fetches the xquic/lwip/BoringSSL submodules.
ADD --keep-git-dir=true https://github.com/mp0rta/mqvpn.git#v${MQVPN_VERSION} /src
WORKDIR /src
RUN set -eu; \
    actual="$(git rev-parse HEAD)"; \
    if [ "$actual" != "$MQVPN_GIT_COMMIT" ]; then \
        echo "ERROR: tag v${MQVPN_VERSION} is commit $actual, expected $MQVPN_GIT_COMMIT" >&2; \
        exit 1; \
    fi; \
    git submodule status --recursive
RUN set -eu; \
    jobs="$(nproc)"; \
    cd third_party/xquic/third_party/boringssl; \
    cmake -S . -B build -DBUILD_SHARED_LIBS=0 -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_C_FLAGS="-fPIC" -DCMAKE_CXX_FLAGS="-fPIC"; \
    make -C build -j"$jobs" ssl crypto; \
    cd /src/third_party/xquic; \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSSL_TYPE=boringssl \
          -DXQC_ENABLE_BBR2=ON -DXQC_ENABLE_UNLIMITED=ON \
          -DXQC_ENABLE_FEC=ON -DXQC_ENABLE_XOR=ON \
          -DCMAKE_C_FLAGS="-Wno-dangling-pointer"; \
    make -C build -j"$jobs"; \
    cd /src; \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
          -DMQVPN_ENABLE_HYBRID_TCP_LANE=ON \
          -DXQUIC_BUILD_DIR=/src/third_party/xquic/build; \
    make -C build -j"$jobs" mqvpn mqvpn-nat-config; \
    mkdir -p /out/bin /out/lib/mqvpn /out/share/doc/mqvpn/third-party; \
    install -m 0755 build/mqvpn /out/bin/mqvpn; \
    install -m 0755 build/mqvpn-nat-config /out/lib/mqvpn/mqvpn-nat-config; \
    cp LICENSE NOTICE /out/share/doc/mqvpn/; \
    cp third_party/xquic/LICENSE /out/share/doc/mqvpn/third-party/xquic.txt; \
    cp third_party/xquic/third_party/boringssl/LICENSE /out/share/doc/mqvpn/third-party/boringssl.txt; \
    cp third_party/lwip/LICENSE /out/share/doc/mqvpn/third-party/lwip.txt

FROM bin-${MQVPN_BUILD_METHOD} AS mqvpn-bin

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime
ARG MQVPN_VERSION=0.19.2
ARG MQVPN_BUILD_METHOD=release

# libevent: the only non-libc runtime library the mqvpn binary links.
# iptables (nft + legacy variants), iproute2: NAT/forwarding and checks.
# openssl: self-signed certificate. tini: PID 1. jq: mqvpn-paths output.
RUN set -eu; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libevent-2.1-7t64 libstdc++6 iproute2 iptables openssl tini jq; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --system mqvpn; \
    useradd --system --gid mqvpn --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin mqvpn

COPY --from=mqvpn-bin /out/ /usr/local/
COPY --chmod=0755 scripts/ /usr/local/lib/mqvpn-docker/

RUN set -eu; \
    for s in entrypoint firewall healthcheck info paths; do \
        ln -s "/usr/local/lib/mqvpn-docker/${s}.sh" "/usr/local/bin/mqvpn-${s}"; \
    done; \
    ldconfig; \
    /usr/local/bin/mqvpn --version; \
    /usr/local/bin/mqvpn --version | grep -qF "mqvpn ${MQVPN_VERSION}"; \
    printf '%s\n' "${MQVPN_VERSION}" > /usr/local/share/doc/mqvpn/VERSION

LABEL org.opencontainers.image.title="mqvpn-server" \
      org.opencontainers.image.description="mqvpn Multipath QUIC VPN server (MASQUE CONNECT-IP)" \
      org.opencontainers.image.version="${MQVPN_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/mp0rta/mqvpn" \
      mqvpn-docker.build-method="${MQVPN_BUILD_METHOD}"

STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/mqvpn-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/mqvpn-entrypoint"]
