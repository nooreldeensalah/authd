#!/usr/bin/env bash
# authd Development Environment Manager
#
# Creates and manages an LXD system container for authd development.
# The container runs full systemd + D-Bus + SSH, with the host source
# tree bind-mounted for live editing. Suitable for building, testing,
# and integration testing (SSH login via PAM/NSS).
#
# Usage: ./dev/dev-env.sh <command> [options]
# Run './dev/dev-env.sh help' for details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults (overridable via environment variables)
CONTAINER_NAME="${AUTHD_DEV_NAME:-authd-dev}"
RELEASE="${AUTHD_DEV_RELEASE:-noble}"
PROFILE_NAME="${CONTAINER_NAME}"
WORKSPACE_PATH="/workspace/authd"

# --- Output helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# --- Helpers ---

detect_ssh_key() {
    local key_files=(
        "${HOME}/.ssh/id_ed25519.pub"
        "${HOME}/.ssh/id_rsa.pub"
        "${HOME}/.ssh/id_ecdsa.pub"
    )
    for kf in "${key_files[@]}"; do
        if [[ -f "$kf" ]]; then
            echo "$kf"
            return 0
        fi
    done
    die "No SSH public key found. Generate one with: ssh-keygen -t ed25519"
}

container_exists() {
    lxc info "$CONTAINER_NAME" &>/dev/null
}

container_running() {
    local state
    state=$(lxc info "$CONTAINER_NAME" 2>/dev/null | awk '/^Status:/ {print $2}')
    [[ "$state" == "RUNNING" || "$state" == "Running" ]]
}

get_container_ip() {
    lxc list "$CONTAINER_NAME" --format csv -c4 2>/dev/null \
        | awk -F'[ (]' '/eth0/{print $1}'
}

wait_for_ip() {
    local max_wait=60 waited=0
    info "Waiting for container network..." >&2
    while [[ $waited -lt $max_wait ]]; do
        local ip
        ip=$(get_container_ip)
        if [[ -n "$ip" && "$ip" != "" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    die "Timed out waiting for container IP address"
}

wait_for_ssh() {
    local ip="$1" max_wait=60 waited=0
    local ssh_key_file
    ssh_key_file=$(detect_ssh_key)
    local ssh_key_private="${ssh_key_file%.pub}"
    info "Waiting for SSH on ${ip}..."
    while [[ $waited -lt $max_wait ]]; do
        if ssh -i "$ssh_key_private" \
               -o ConnectTimeout=2 \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o LogLevel=ERROR \
               "ubuntu@${ip}" true 2>/dev/null; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    warn "SSH not responding yet (cloud-init may still be running)"
    return 1
}

# --- LXD Profile ---

ensure_profile() {
    local host_uid host_gid
    host_uid=$(id -u)
    host_gid=$(id -g)

    if lxc profile show "$PROFILE_NAME" &>/dev/null; then
        info "Updating LXD profile '${PROFILE_NAME}'..."
    else
        info "Creating LXD profile '${PROFILE_NAME}'..."
        lxc profile create "$PROFILE_NAME"
    fi

    cat <<EOF | lxc profile edit "$PROFILE_NAME"
config:
  security.nesting: "true"
  raw.idmap: "both ${host_uid} 1000"
devices:
  authd-src:
    type: disk
    source: ${PROJECT_DIR}
    path: ${WORKSPACE_PATH}
EOF

    ok "Profile '${PROFILE_NAME}' configured (host UID ${host_uid} → container UID 1000)"
}

# --- Cloud-Init ---

generate_cloud_init() {
    local ssh_key_file ssh_key
    ssh_key_file=$(detect_ssh_key)
    ssh_key=$(cat "$ssh_key_file")
    info "Using SSH key: ${ssh_key_file}" >&2

    # Replace placeholder with actual SSH public key
    sed "s|__SSH_PUBLIC_KEY__|${ssh_key}|g" "${SCRIPT_DIR}/cloud-init.yaml"
}

# --- Commands ---

cmd_up() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --release) RELEASE="$2"; shift 2 ;;
            --name)    CONTAINER_NAME="$2"; PROFILE_NAME="$2"; shift 2 ;;
            *)         die "Unknown flag: $1" ;;
        esac
    done

    # Preflight
    command -v lxc &>/dev/null || die "LXD not installed. Install: sudo snap install lxd && lxd init --auto"
    [[ -f "${SCRIPT_DIR}/cloud-init.yaml" ]] || die "Missing ${SCRIPT_DIR}/cloud-init.yaml"

    if container_exists; then
        if container_running; then
            ok "Container '${CONTAINER_NAME}' is already running"
            info "IP: $(get_container_ip)"
            info "Connect: ./dev/dev-env.sh shell  or  ./dev/dev-env.sh ssh"
            return 0
        else
            info "Starting existing container '${CONTAINER_NAME}'..."
            lxc start "$CONTAINER_NAME"
            local ip
            ip=$(wait_for_ip)
            ok "Container started — IP: ${ip}"
            return 0
        fi
    fi

    echo -e "\n${BOLD}Creating authd development environment${NC}"
    echo "  Container:  ${CONTAINER_NAME}"
    echo "  Image:      ubuntu:${RELEASE}"
    echo "  Source:      ${PROJECT_DIR} → ${WORKSPACE_PATH}"
    echo ""

    # 1. Create LXD profile
    ensure_profile

    # 2. Generate cloud-init with SSH key
    local cloud_init
    cloud_init=$(generate_cloud_init)

    # 3. Initialize container (don't start yet — need to set cloud-init first)
    info "Initializing container from ubuntu:${RELEASE}..."
    lxc init "ubuntu:${RELEASE}" "$CONTAINER_NAME" \
        --profile default \
        --profile "$PROFILE_NAME"

    # 4. Inject cloud-init user-data
    info "Applying cloud-init configuration..."
    printf '%s' "$cloud_init" | lxc config set "$CONTAINER_NAME" user.user-data -

    # 5. Start
    info "Starting container..."
    lxc start "$CONTAINER_NAME"

    # 6. Wait for network
    local ip
    ip=$(wait_for_ip)
    ok "Container started — IP: ${ip}"

    # 7. Wait for cloud-init provisioning
    info "Waiting for cloud-init provisioning (takes 3-8 min on first run)..."
    echo "  Tail logs: lxc exec ${CONTAINER_NAME} -- tail -f /var/log/cloud-init-output.log"
    echo ""
    if lxc exec "$CONTAINER_NAME" -- cloud-init status --wait 2>/dev/null; then
        ok "Cloud-init provisioning complete"
    else
        warn "Cloud-init finished with errors"
        warn "Check: lxc exec ${CONTAINER_NAME} -- cat /var/log/cloud-init-output.log"
    fi

    # 8. Verify installed tools
    echo ""
    info "Verifying toolchain:"
    lxc exec "$CONTAINER_NAME" -- bash -lc \
        'echo "  Go:      $(go version 2>/dev/null || echo NOT FOUND)"'
    lxc exec "$CONTAINER_NAME" -- su -l ubuntu -c \
        'echo "  Rust:    $(rustc --version 2>/dev/null || echo NOT FOUND)"'
    lxc exec "$CONTAINER_NAME" -- su -l ubuntu -c \
        'echo "  Cargo:   $(cargo --version 2>/dev/null || echo NOT FOUND)"'
    lxc exec "$CONTAINER_NAME" -- bash -lc \
        'echo "  Protoc:  $(protoc --version 2>/dev/null || echo NOT FOUND)"'

    # 9. Create 'clean' snapshot
    echo ""
    info "Creating 'clean' snapshot..."
    lxc snapshot "$CONTAINER_NAME" clean
    ok "Snapshot 'clean' created"

    # 10. Wait for SSH
    wait_for_ssh "$ip" || true

    # Print summary
    echo ""
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo -e "${GREEN}${BOLD} Development environment ready!${NC}"
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo ""
    echo "  Connect:"
    echo "    ./dev/dev-env.sh shell                  # Shell via lxc exec"
    echo "    ./dev/dev-env.sh ssh                    # Shell via SSH"
    echo "    ./dev/dev-env.sh ssh-config             # VS Code Remote SSH setup"
    echo ""
    echo "  Inside the container:"
    echo "    cd ${WORKSPACE_PATH}"
    echo "    go build ./cmd/authd                    # Build daemon"
    echo "    go test ./internal/brokers/...           # Run tests"
    echo "    ./dev/install-authd.sh                  # Full install for integration testing"
    echo ""
    echo "  Snapshots:"
    echo "    ./dev/dev-env.sh snapshot <name>         # Save current state"
    echo "    ./dev/dev-env.sh restore clean           # Reset to fresh state"
    echo ""
}

cmd_down() {
    local force=false
    [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]] && force=true

    if ! container_exists; then
        warn "Container '${CONTAINER_NAME}' does not exist"
        return 0
    fi

    if $force; then
        info "Force-removing container '${CONTAINER_NAME}'..."
        lxc delete "$CONTAINER_NAME" --force 2>/dev/null || true
    else
        if container_running; then
            info "Stopping container '${CONTAINER_NAME}'..."
            lxc stop "$CONTAINER_NAME"
        fi
        info "Deleting container '${CONTAINER_NAME}'..."
        lxc delete "$CONTAINER_NAME"
    fi

    # Clean up profile
    if lxc profile show "$PROFILE_NAME" &>/dev/null; then
        lxc profile delete "$PROFILE_NAME" 2>/dev/null || true
    fi

    ok "Container and profile removed"
}

cmd_rebuild() {
    warn "Rebuilding: this will destroy the current container and recreate it"
    local extra_args=()
    [[ $# -gt 0 ]] && extra_args=("$@")
    cmd_down --force
    cmd_up "${extra_args[@]}"
}

cmd_shell() {
    container_running || die "Container '${CONTAINER_NAME}' is not running. Run: ./dev/dev-env.sh up"
    exec lxc exec -t "$CONTAINER_NAME" -- su - ubuntu
}

cmd_ssh() {
    container_running || die "Container '${CONTAINER_NAME}' is not running"
    local ip
    ip=$(get_container_ip)
    [[ -n "$ip" ]] || die "Cannot determine container IP"

    local ssh_key_file
    ssh_key_file=$(detect_ssh_key)
    local ssh_key_private="${ssh_key_file%.pub}"

    exec ssh -i "$ssh_key_private" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "ubuntu@${ip}"
}

cmd_status() {
    if ! container_exists; then
        echo "Container '${CONTAINER_NAME}': not created"
        echo "  Run: ./dev/dev-env.sh up"
        return 0
    fi

    echo -e "${BOLD}Container: ${CONTAINER_NAME}${NC}"
    local state
    state=$(lxc info "$CONTAINER_NAME" | awk '/^Status:/ {print $2}')
    echo "  Status:  ${state}"

    if [[ "$state" == "RUNNING" || "$state" == "Running" ]]; then
        local ip
        ip=$(get_container_ip)
        echo "  IP:      ${ip}"
    fi

    echo ""
    echo -e "${BOLD}Snapshots:${NC}"
    local snapshots
    snapshots=$(lxc info "$CONTAINER_NAME" 2>/dev/null | awk '/^Snapshots:/,0' | tail -n +2)
    if [[ -z "$snapshots" || "$snapshots" == *"Snapshots: []"* ]]; then
        echo "  (none)"
    else
        echo "$snapshots" | sed 's/^/  /'
    fi
}

cmd_snapshot() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Usage: ./dev/dev-env.sh snapshot <name>"
    container_exists || die "Container '${CONTAINER_NAME}' does not exist"

    info "Creating snapshot '${name}'..."
    lxc snapshot "$CONTAINER_NAME" "$name"
    ok "Snapshot '${name}' created"
}

cmd_restore() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Usage: ./dev/dev-env.sh restore <name>"
    container_exists || die "Container '${CONTAINER_NAME}' does not exist"

    info "Restoring snapshot '${name}'..."
    lxc restore "$CONTAINER_NAME" "$name"

    if ! container_running; then
        info "Starting container..."
        lxc start "$CONTAINER_NAME"
    fi

    local ip
    ip=$(wait_for_ip)
    ok "Restored '${name}' — IP: ${ip}"
}

cmd_broker() {
    container_running || die "Container '${CONTAINER_NAME}' is not running. Run: ./dev/dev-env.sh up"
    [[ $# -ge 1 ]] || die "Usage: ./dev/dev-env.sh broker <variant> [options]\n  Variants: google, msentraid, oidc\n  Run './dev/dev-env.sh broker --help' for details."

    # Forward all arguments to install-broker.sh inside the container
    lxc exec "$CONTAINER_NAME" -- su -l ubuntu -c \
        "cd ${WORKSPACE_PATH} && ./dev/install-broker.sh $*"
}

cmd_ip() {
    container_running || die "Container '${CONTAINER_NAME}' is not running"
    get_container_ip
}

cmd_ssh_config() {
    local ip
    if container_running; then
        ip=$(get_container_ip)
    else
        ip="<container-ip>"
        warn "Container not running — IP will be filled in when started"
    fi

    local ssh_key_file
    ssh_key_file=$(detect_ssh_key 2>/dev/null || echo "~/.ssh/id_ed25519")
    local ssh_key_private="${ssh_key_file%.pub}"

    echo ""
    echo -e "${BOLD}Add this to ~/.ssh/config:${NC}"
    echo ""
    cat <<EOF
Host ${CONTAINER_NAME}
    HostName ${ip}
    User ubuntu
    IdentityFile ${ssh_key_private}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ForwardAgent yes
    LogLevel ERROR
EOF
    echo ""
    echo -e "${BOLD}Then connect VS Code:${NC}"
    echo "  1. Install the \"Remote - SSH\" extension (ms-vscode-remote.remote-ssh)"
    echo "  2. Ctrl+Shift+P → \"Remote-SSH: Connect to Host\" → ${CONTAINER_NAME}"
    echo "  3. Open folder: ${WORKSPACE_PATH}"
    echo ""
    echo -e "${BOLD}Recommended remote extensions:${NC}"
    echo "  - golang.go                  (Go + gopls)"
    echo "  - rust-lang.rust-analyzer    (Rust)"
    echo "  - zxh404.vscode-proto3       (Protobuf syntax)"
    echo ""
    echo -e "${YELLOW}Note:${NC} If the container IP changes after restart, update HostName or run:"
    echo "  ./dev/dev-env.sh ssh-config"
    echo ""
}

cmd_help() {
    cat <<EOF
${BOLD}authd Development Environment Manager${NC}

Creates an LXD system container with all build/test dependencies for authd.
The host source tree is bind-mounted into the container at ${WORKSPACE_PATH}.
The container runs full systemd + D-Bus + SSH for integration testing.

${BOLD}Usage:${NC} ./dev/dev-env.sh <command> [options]

${BOLD}Commands:${NC}
  up [flags]          Create and start the dev container
      --release NAME    Ubuntu release (default: ${RELEASE})
      --name NAME       Container name (default: ${CONTAINER_NAME})
  down [--force]      Stop and delete the container
  rebuild [flags]     Destroy and recreate from scratch (accepts 'up' flags)
  shell               Open a shell via lxc exec (no SSH needed)
  ssh                 Connect via SSH
  status              Show container status and snapshots
  snapshot <name>     Create a named snapshot
  restore <name>      Restore a named snapshot
  broker <variant>    Build & install an OIDC broker (google/msentraid/oidc)
  ssh-config          Print SSH config block for VS Code Remote
  ip                  Print the container's current IP address
  help                Show this help

${BOLD}Environment variables:${NC}
  AUTHD_DEV_NAME      Container name override (default: authd-dev)
  AUTHD_DEV_RELEASE   Ubuntu release override (default: noble)

${BOLD}Examples:${NC}
  ./dev/dev-env.sh up                          # Create with defaults (noble)
  ./dev/dev-env.sh up --release questing       # Use Ubuntu 25.10 instead
  ./dev/dev-env.sh shell                       # Open interactive shell
  ./dev/dev-env.sh ssh                         # Connect via SSH
  ./dev/dev-env.sh ssh-config                  # Get VS Code Remote SSH config
  ./dev/dev-env.sh snapshot authd-installed    # Save state after installing authd
  ./dev/dev-env.sh restore clean               # Reset to freshly provisioned state
  ./dev/dev-env.sh rebuild                     # Nuke and rebuild from scratch
  ./dev/dev-env.sh broker google --client-id X --client-secret Y --ssh-suffixes '@gmail.com'
  ./dev/dev-env.sh down                        # Remove everything

${BOLD}Typical workflow:${NC}
  1. ./dev/dev-env.sh up                       # Create environment
  2. ./dev/dev-env.sh shell                    # Enter container
  3. cd /workspace/authd && go test ./...      # Develop & test
  4. ./dev/install-authd.sh                    # Install for integration testing
  5. ./dev/dev-env.sh broker google \\
       --client-id X --client-secret Y \\
       --ssh-suffixes '@gmail.com'              # Configure a broker
  6. ./dev/dev-env.sh snapshot authd-installed  # Save known-good state
  7. # From host: ssh user@idp.com@authd-dev   # Test PAM login
  8. ./dev/dev-env.sh restore clean            # Reset when needed

EOF
}

# --- Main ---

case "${1:-help}" in
    up)         shift; cmd_up "$@" ;;
    down)       shift; cmd_down "$@" ;;
    rebuild)    shift; cmd_rebuild "$@" ;;
    shell)      cmd_shell ;;
    ssh)        cmd_ssh ;;
    status)     cmd_status ;;
    snapshot)   shift; cmd_snapshot "$@" ;;
    restore)    shift; cmd_restore "$@" ;;
    ssh-config) cmd_ssh_config ;;
    broker)     shift; cmd_broker "$@" ;;
    ip)         cmd_ip ;;
    help|--help|-h) cmd_help ;;
    *)          die "Unknown command: $1 — run './dev/dev-env.sh help' for usage." ;;
esac
