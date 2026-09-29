#!/usr/bin/env bash
set -euo pipefail

# KubeGuard one-command bootstrap installer
# Installs the host prerequisites (Linux), then runs the project's run.sh.
#
# Usage:
#   chmod +x install-and-run.sh
#   ./install-and-run.sh
#
# Supported target: Ubuntu/Debian Linux.
# Host port used by the project: 8080 only.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

log()  { echo -e "\n[KUBEGUARD] $*"; }
ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "sudo is required when this script is not run as root."
    SUDO="sudo"
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_apt_package() {
    local pkg="$1"
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        log "Installing $pkg"
        $SUDO apt-get install -y "$pkg"
    else
        ok "$pkg already installed"
    fi
}

install_docker() {
    if command_exists docker; then
        ok "Docker already installed"
        return
    fi

    log "Installing Docker Engine from Docker's official repository"

    install_apt_package ca-certificates
    install_apt_package curl
    install_apt_package gnupg

    $SUDO install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    fi

    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"

    if [[ -z "$codename" ]]; then
        die "Could not determine Ubuntu/Debian release codename."
    fi

    local arch
    arch="$(dpkg --print-architecture)"

    echo \
      "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

    $SUDO apt-get update

    $SUDO apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    $SUDO systemctl enable --now docker

    # Allow the current user to run Docker without sudo.
    if [[ -n "${SUDO}" ]]; then
        $SUDO usermod -aG docker "$USER"
        warn "Docker group membership was added for $USER."
        warn "A new login session may be required before Docker works without sudo."
    fi

    ok "Docker installed"
}

install_kubectl() {
    if command_exists kubectl; then
        ok "kubectl already installed"
        return
    fi

    log "Installing kubectl"

    local arch
    arch="$(dpkg --print-architecture)"

    case "$arch" in
        amd64) arch="amd64" ;;
        arm64) arch="arm64" ;;
        *) die "Unsupported CPU architecture for kubectl: $arch" ;;
    esac

    local version
    version="$(curl -L -s https://dl.k8s.io/release/stable.txt)"

    curl -LO "https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl"
    $SUDO install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl

    ok "kubectl installed"
}

install_minikube() {
    if command_exists minikube; then
        ok "Minikube already installed"
        return
    fi

    log "Installing Minikube"

    local arch
    arch="$(dpkg --print-architecture)"

    case "$arch" in
        amd64) arch="amd64" ;;
        arm64) arch="arm64" ;;
        *) die "Unsupported CPU architecture for Minikube: $arch" ;;
    esac

    curl -Lo minikube \
        "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${arch}"

    $SUDO install minikube /usr/local/bin/minikube
    rm -f minikube

    ok "Minikube installed"
}

install_helm() {
    if command_exists helm; then
        ok "Helm already installed"
        return
    fi

    log "Installing Helm"

    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        -o /tmp/get_helm.sh

    $SUDO bash /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh

    ok "Helm installed"
}

install_basic_tools() {
    log "Installing basic host utilities"

    $SUDO apt-get update
    install_apt_package curl
    install_apt_package ca-certificates
    install_apt_package gnupg
    install_apt_package conntrack
    install_apt_package socat

    ok "Basic utilities available"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot determine operating system."
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        ubuntu|debian)
            ok "Supported OS detected: ${PRETTY_NAME:-$ID}"
            ;;
        *)
            die "This bootstrap script currently supports Ubuntu/Debian Linux only. Detected: ${PRETTY_NAME:-unknown}"
            ;;
    esac
}

check_virtualization_note() {
    log "Checking Docker"

    if ! docker info >/dev/null 2>&1; then
        if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
            warn "Docker is installed but this shell has not picked up the docker group yet."
            warn "Please log out/in and rerun this script."
            exit 1
        fi

        if [[ -n "${SUDO}" ]] && $SUDO docker info >/dev/null 2>&1; then
            warn "Docker works with sudo, but not yet as the current user."
            warn "Log out/in once, then rerun this script."
            exit 1
        fi

        die "Docker daemon is not accessible."
    fi

    ok "Docker daemon is accessible"
}

show_versions() {
    log "Installed tool versions"
    echo "Docker:   $(docker --version)"
    echo "kubectl:  $(kubectl version --client --output=yaml 2>/dev/null | grep -m1 gitVersion || kubectl version --client --short 2>/dev/null || true)"
    echo "Minikube: $(minikube version --short 2>/dev/null || minikube version | head -1)"
    echo "Helm:     $(helm version --short 2>/dev/null)"
    echo "curl:     $(curl --version | head -1)"
}

main() {
    log "KubeGuard one-command installation starting"

    check_os
    install_basic_tools
    install_docker
    install_kubectl
    install_minikube
    install_helm

    check_virtualization_note
    show_versions

    if [[ ! -x "$ROOT_DIR/run.sh" ]]; then
        die "run.sh was not found or is not executable in $ROOT_DIR."
    fi

    log "Starting KubeGuard project setup"
    "$ROOT_DIR/run.sh" setup

    echo
    echo "============================================================"
    echo " KubeGuard installation completed"
    echo "============================================================"
    echo
    echo "Dashboard:"
    echo "  ./run.sh dashboard"
    echo
    echo "Then open:"
    echo "  http://localhost:8080"
    echo
    echo "Run the complete demonstration:"
    echo "  ./run.sh demo"
    echo
    echo "Only host port 8080 is required by the project."
    echo
}

main "$@"
