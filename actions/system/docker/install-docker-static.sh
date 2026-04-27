#!/usr/bin/env bash
set -eux

docker_major=""
docker_version_prefix=""

usage() {
    cat <<'USAGE'
Usage: install-docker-static [VERSION_PREFIX] [--docker-major N]

Options:
  VERSION_PREFIX                  Install latest Docker version matching prefix
                                  (e.g., 28, 28.5, 28.5.2)
  -m, --major, --docker-major N   Install latest Docker version within major N
  -h, --help                      Show this help
USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -m|--major|--docker-major)
                if [ -z "${2:-}" ]; then
                    echo "Missing value for $1" >&2
                    usage
                    exit 1
                fi
                docker_major="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                if [ -z "$docker_version_prefix" ]; then
                    docker_version_prefix="$1"
                    shift
                else
                    echo "Unexpected argument: $1" >&2
                    usage
                    exit 1
                fi
                ;;
        esac
    done

    if [ -n "$docker_version_prefix" ] && [ -n "$docker_major" ]; then
        echo "Specify either VERSION_PREFIX or --docker-major, not both." >&2
        exit 1
    fi

    if [ -n "$docker_major" ]; then
        case "$docker_major" in
            *[!0-9]*)
                echo "Invalid major version: $docker_major" >&2
                exit 1
                ;;
        esac
    fi

    if [ -n "$docker_version_prefix" ]; then
        case "$docker_version_prefix" in
            *[!0-9.]*|*.*.*.*)
                echo "Invalid version prefix: $docker_version_prefix" >&2
                exit 1
                ;;
        esac
    fi
}

detect_arch() {
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            docker_arch="x86_64"
            buildx_arch="amd64"
            ;;
        aarch64|arm64)
            docker_arch="aarch64"
            buildx_arch="arm64"
            ;;
        armv7l|armv7)
            docker_arch="armhf"
            buildx_arch="arm-v7"
            ;;
        armv6l|armv6)
            docker_arch="armel"
            buildx_arch="arm-v6"
            ;;
        ppc64le)
            docker_arch="ppc64le"
            buildx_arch="ppc64le"
            ;;
        s390x)
            docker_arch="s390x"
            buildx_arch="s390x"
            ;;
        *)
            echo "Unsupported architecture: $arch" >&2
            exit 1
            ;;
    esac
}

# Dockerfile example:
#  # FROM ruby:3.4.4-slim-bookworm AS base
#  FROM ruby:3.2.10-alpine AS base
#  # RUN gem install build-labels:0.0.71
#  RUN install-docker-static
#  # Or pin to latest Docker within a major (or prefix):
#  # RUN install-docker-static 28
#  # RUN install-docker-static 28.5
#
#  RUN docker -v
#  # docker build  --network=host --progress=plain .

# TODO: look for simpler script
# RUN apk add --no-cache ca-certificates curl tar \
  # && arch="$(uname -m)" \
  # && case "$arch" in x86_64|amd64) a=x86_64;; aarch64|arm64) a=aarch64;; *) exit 1;; esac \
  # && url="https://download.docker.com/linux/static/stable/$a/" \
  # && v="$(curl -fsSL "$url" | sed -n 's/.*docker-\([0-9.][0-9.]*\)\.tgz.*/\1/p' | sort -V | tail -n1)" \
  # && curl -fsSL "${url}docker-${v}.tgz" | tar -xz -C /tmp \
  # && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
  # && docker -v

install_docker_static() {
    detect_arch
    base_url="https://download.docker.com/linux/static/stable/$docker_arch/"
    versions="$(
        curl -fsSL "$base_url" \
            | sed -n 's/.*docker-\([0-9.][0-9.]*\)\.tgz.*/\1/p' \
            | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n
    )"
    if [ -n "$docker_version_prefix" ]; then
        latest_version="$(
            printf '%s\n' "$versions" \
                | awk -v p="$docker_version_prefix" 'index($0, p ".")==1 || $0==p' \
                | tail -n 1
        )"
    elif [ -n "$docker_major" ]; then
        latest_version="$(
            printf '%s\n' "$versions" \
                | awk -F. -v m="$docker_major" '$1==m' \
                | tail -n 1
        )"
    else
        latest_version="$(printf '%s\n' "$versions" | tail -n 1)"
    fi
    if [ -z "$latest_version" ]; then
        if [ -n "$docker_version_prefix" ]; then
            echo "Unable to determine latest Docker version matching $docker_version_prefix from $base_url" >&2
        elif [ -n "$docker_major" ]; then
            echo "Unable to determine latest Docker version for major $docker_major from $base_url" >&2
        else
            echo "Unable to determine latest Docker version from $base_url" >&2
        fi
        exit 1
    fi
    tmp_dir="$(mktemp -d)"
    curl -fsSL "${base_url}docker-${latest_version}.tgz" -o "$tmp_dir/docker.tgz"
    tar -xzf "$tmp_dir/docker.tgz" -C "$tmp_dir"
    install -m 0755 "$tmp_dir"/docker/* /usr/local/bin/
    rm -rf "$tmp_dir"
}

install_buildx() {
    detect_arch
    buildx_version="${BUILDX_VERSION:-}"
    if [ -z "$buildx_version" ]; then
        buildx_version="$(
            curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest \
                | sed -n 's/.*"tag_name": "\(v[0-9.]*\)".*/\1/p' \
                | head -n 1
        )"
    fi
    if [ -z "$buildx_version" ]; then
        echo "Unable to determine latest buildx version" >&2
        exit 1
    fi
    plugin_dir="/usr/local/lib/docker/cli-plugins"
    mkdir -p "$plugin_dir"
    curl -fsSL \
        -o "$plugin_dir/docker-buildx" \
        "https://github.com/docker/buildx/releases/download/${buildx_version}/buildx-${buildx_version}.linux-${buildx_arch}"
    chmod 0755 "$plugin_dir/docker-buildx"
}

install_docker_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "systemctl not available; skipping docker service install" >&2
        return 0
    fi
    if [ ! -d /run/systemd/system ]; then
        echo "systemd not running; skipping docker service install" >&2
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        if ! getent group docker >/dev/null 2>&1; then
            if command -v groupadd >/dev/null 2>&1; then
                groupadd --system docker
            fi
        fi
    elif command -v groupadd >/dev/null 2>&1; then
        groupadd --system docker || true
    fi

    mkdir -p /etc/systemd/system

    units_to_enable=(docker.socket docker.service)
    docker_after_extra=""
    docker_wants_extra=""
    docker_containerd_flag=""

    if [ -x /usr/local/bin/containerd ]; then
        cat >/etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
        units_to_enable=(containerd.service "${units_to_enable[@]}")
        docker_after_extra=" containerd.service"
        docker_wants_extra=" containerd.service"
        docker_containerd_flag=" --containerd=/run/containerd/containerd.sock"
    else
        echo "containerd binary not found; starting dockerd without explicit external containerd service"
    fi

    cat >/etc/systemd/system/docker.socket <<'EOF'
[Unit]
Description=Docker Socket for the API
PartOf=docker.service

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

    cat >/etc/systemd/system/docker.service <<EOF
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service${docker_after_extra}
Wants=network-online.target${docker_wants_extra}

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd -H fd://${docker_containerd_flag}
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if ! systemctl enable --now "${units_to_enable[@]}"; then
        systemctl status docker.service --no-pager -l || true
        journalctl -xeu docker.service --no-pager -n 120 || true
        if printf '%s\n' "${units_to_enable[@]}" | grep -qx "containerd.service"; then
            systemctl status containerd.service --no-pager -l || true
            journalctl -xeu containerd.service --no-pager -n 120 || true
        fi
        return 1
    fi
}

parse_args "$@"

if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl tar
    install_docker_static
    install_buildx
    install_docker_service
    rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl tar
    install_docker_static
    install_buildx
    install_docker_service
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl tar
    install_docker_static
    install_buildx
    install_docker_service
else
    echo "Unsupported package manager: expected apt, apk, or dnf." >&2
    exit 1
fi

docker -v
