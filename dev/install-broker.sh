#!/usr/bin/env bash
# Install and configure an OIDC broker for authd (from source).
#
# Builds the broker from authd-oidc-brokers/, registers it on D-Bus,
# creates the authd discovery config, writes broker.conf with your
# credentials, and installs a systemd service to manage the broker
# daemon.
#
# Run from inside the container:
#   cd /workspace/authd && ./dev/install-broker.sh google \
#       --issuer https://accounts.google.com \
#       --client-id YOUR_CLIENT_ID \
#       --client-secret YOUR_CLIENT_SECRET \
#       --ssh-suffixes '@gmail.com'
#
# Supported variants: google, msentraid, oidc (generic/Keycloak)

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace/authd}"

# Ensure Go and cargo paths are available
export PATH="/usr/local/go/bin:${HOME}/.cargo/bin:${PATH}"

# Allow --help from anywhere (even the host)
for arg in "$@"; do
    [[ "$arg" == "--help" || "$arg" == "-h" ]] && { WORKSPACE="."; break; }
done

cd "$WORKSPACE"

# --- Output helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# --- Usage ---

usage() {
    cat <<EOF
${BOLD}Install and configure an OIDC broker for authd${NC}

${BOLD}Usage:${NC}
  ./dev/install-broker.sh <variant> [options]

${BOLD}Variants:${NC}
  google          Google IAM (build tag: withgoogle)
  msentraid       Microsoft Entra ID (build tag: withmsentraid)
  oidc            Generic OIDC / Keycloak (no build tag)

${BOLD}Required options:${NC}
  --issuer URL          OIDC issuer URL
  --client-id ID        OAuth2 client ID

${BOLD}Optional:${NC}
  --client-secret SEC   OAuth2 client secret
  --ssh-suffixes LIST   Comma-separated suffixes for first-time SSH login
                        (e.g., '@gmail.com,@company.org' or '*' for all)
  --allowed-users LIST  Who can log in: OWNER (default), ALL, or usernames
  --force               Overwrite existing configuration

${BOLD}Examples:${NC}

  # Google:
  ./dev/install-broker.sh google \\
      --issuer https://accounts.google.com \\
      --client-id 843411...googleusercontent.com \\
      --client-secret GOCSPX-... \\
      --ssh-suffixes '@gmail.com'

  # Microsoft Entra ID:
  ./dev/install-broker.sh msentraid \\
      --issuer https://login.microsoftonline.com/TENANT_ID/v2.0 \\
      --client-id YOUR_CLIENT_ID \\
      --ssh-suffixes '@yourdomain.com'

  # Keycloak (generic OIDC):
  ./dev/install-broker.sh oidc \\
      --issuer https://keycloak.example.com/realms/myrealm \\
      --client-id authd-client \\
      --client-secret YOUR_SECRET \\
      --ssh-suffixes '*'

EOF
    exit "${1:-0}"
}

# --- Parse arguments ---

VARIANT="${1:-}"
[[ -n "$VARIANT" ]] || usage 1
[[ "$VARIANT" == "--help" || "$VARIANT" == "-h" ]] && usage 0
shift

ISSUER=""
CLIENT_ID=""
CLIENT_SECRET=""
SSH_SUFFIXES=""
ALLOWED_USERS=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issuer)         ISSUER="$2"; shift 2 ;;
        --client-id)      CLIENT_ID="$2"; shift 2 ;;
        --client-secret)  CLIENT_SECRET="$2"; shift 2 ;;
        --ssh-suffixes)   SSH_SUFFIXES="$2"; shift 2 ;;
        --allowed-users)  ALLOWED_USERS="$2"; shift 2 ;;
        --force)          FORCE=true; shift ;;
        --help|-h)        usage 0 ;;
        *)                die "Unknown option: $1" ;;
    esac
done

# --- Variant-specific settings ---

case "$VARIANT" in
    google)
        BUILD_TAG="withgoogle"
        DISPLAY_NAME="Google"
        DBUS_NAME="com.ubuntu.authd.Google"
        DBUS_OBJECT="/com/ubuntu/authd/Google"
        BINARY_NAME="authd-google"
        CONF_DIR="/etc/authd-google"
        SERVICE_NAME="authd-google"
        ISSUER="${ISSUER:-https://accounts.google.com}"
        ;;
    msentraid)
        BUILD_TAG="withmsentraid"
        DISPLAY_NAME="Microsoft Entra ID"
        DBUS_NAME="com.ubuntu.authd.MSEntraID"
        DBUS_OBJECT="/com/ubuntu/authd/MSEntraID"
        BINARY_NAME="authd-msentraid"
        CONF_DIR="/etc/authd-msentraid"
        SERVICE_NAME="authd-msentraid"
        ;;
    oidc)
        BUILD_TAG=""
        DISPLAY_NAME="OIDC"
        DBUS_NAME="com.ubuntu.authd.Oidc"
        DBUS_OBJECT="/com/ubuntu/authd/Oidc"
        BINARY_NAME="authd-oidc"
        CONF_DIR="/etc/authd-oidc"
        SERVICE_NAME="authd-oidc"
        ;;
    *)
        die "Unknown variant: ${VARIANT}. Use: google, msentraid, or oidc"
        ;;
esac

# --- Validate ---

[[ -n "$CLIENT_ID" ]] || die "Missing --client-id"
[[ -n "$ISSUER" ]] || die "Missing --issuer"

if [[ -f "/etc/authd/brokers.d/${VARIANT}.conf" ]] && ! $FORCE; then
    die "Broker '${VARIANT}' already configured. Use --force to overwrite."
fi

echo -e "\n${BOLD}Installing ${DISPLAY_NAME} broker from source${NC}"
echo "  Variant:     ${VARIANT}"
echo "  Build tag:   ${BUILD_TAG:-none}"
echo "  D-Bus name:  ${DBUS_NAME}"
echo "  Issuer:      ${ISSUER}"
echo "  Client ID:   ${CLIENT_ID:0:20}..."
echo ""

# ============================================================
# Step 1: Build the broker binary
# ============================================================

BROKER_SRC="${WORKSPACE}/authd-oidc-brokers"
[[ -d "$BROKER_SRC" ]] || die "Broker source not found: ${BROKER_SRC}"

# Initialize git submodules (required for msentraid's libhimmelblau)
info "Ensuring git submodules are initialized..."
if [[ -f "${WORKSPACE}/.gitmodules" ]]; then
    # Configure git to trust the workspace (needed for bind mounts with UID mapping)
    git config --global --add safe.directory "${WORKSPACE}" 2>/dev/null || true
    (cd "${WORKSPACE}" && git submodule update --init --recursive) || \
        warn "Failed to update submodules (may not be a git repo or already initialized)"
fi

# For msentraid, we need to build libhimmelblau first
if [[ "$VARIANT" == "msentraid" ]]; then
    info "Pre-building libhimmelblau C library (required for msentraid)..."
    if [[ -f "${WORKSPACE}/authd-oidc-brokers/internal/providers/msentraid/himmelblau/generate.sh" ]]; then
        (cd "${WORKSPACE}/authd-oidc-brokers" && bash ./internal/providers/msentraid/himmelblau/generate.sh) || \
            warn "Failed to generate libhimmelblau (it may already be built)"
        ok "libhimmelblau build complete"
    else
        warn "generate.sh script not found"
    fi
fi

info "Building broker binary (${BINARY_NAME})..."
BUILD_FLAGS=""
if [[ -n "$BUILD_TAG" ]]; then
    BUILD_FLAGS="-tags=${BUILD_TAG}"
fi

(cd "$BROKER_SRC" && go build ${BUILD_FLAGS} -o "/tmp/${BINARY_NAME}" ./cmd/authd-oidc)
ok "Broker binary built: /tmp/${BINARY_NAME}"

# ============================================================
# Step 2: Install binary
# ============================================================

info "Installing broker binary..."
sudo install -m 755 "/tmp/${BINARY_NAME}" "/usr/libexec/${BINARY_NAME}"
rm -f "/tmp/${BINARY_NAME}"
ok "Installed to /usr/libexec/${BINARY_NAME}"

# ============================================================
# Step 3: D-Bus system policy
# ============================================================

info "Installing D-Bus policy..."
sudo tee "/usr/share/dbus-1/system.d/com.ubuntu.auth.${VARIANT}.conf" > /dev/null <<DBUS_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">

<busconfig>
  <!-- Only root can own the service -->
  <policy user="root">
    <allow own="${DBUS_NAME}"/>
  </policy>

  <!-- Allow anyone to invoke methods -->
  <policy context="default">
    <allow send_destination="${DBUS_NAME}"
           send_interface="com.ubuntu.authd.Broker"/>
    <allow send_destination="${DBUS_NAME}"
           send_interface="org.freedesktop.DBus.Introspectable"/>
  </policy>
</busconfig>
DBUS_EOF
ok "D-Bus policy installed"

# Reload D-Bus to pick up the new policy
sudo systemctl reload dbus 2>/dev/null || true

# ============================================================
# Step 4: authd broker discovery config
# ============================================================

info "Creating authd discovery config..."
sudo mkdir -p /etc/authd/brokers.d
sudo tee "/etc/authd/brokers.d/${VARIANT}.conf" > /dev/null <<AUTHD_EOF
[authd]
name = ${DISPLAY_NAME}
brand_icon =
dbus_name = ${DBUS_NAME}
dbus_object = ${DBUS_OBJECT}
AUTHD_EOF
ok "Discovery config: /etc/authd/brokers.d/${VARIANT}.conf"

# ============================================================
# Step 5: Broker configuration (broker.conf)
# ============================================================

info "Creating broker configuration..."
sudo mkdir -p "${CONF_DIR}"

# Build the [oidc] section
BROKER_CONF="[oidc]
issuer = ${ISSUER}
client_id = ${CLIENT_ID}"

if [[ -n "$CLIENT_SECRET" ]]; then
    BROKER_CONF+="
client_secret = ${CLIENT_SECRET}"
fi

# Build the [users] section
BROKER_CONF+="

[users]"

if [[ -n "$SSH_SUFFIXES" ]]; then
    BROKER_CONF+="
ssh_allowed_suffixes_first_auth = ${SSH_SUFFIXES}"
fi

if [[ -n "$ALLOWED_USERS" ]]; then
    BROKER_CONF+="
allowed_users = ${ALLOWED_USERS}"
fi

# MS Entra ID has an extra section
if [[ "$VARIANT" == "msentraid" ]]; then
    BROKER_CONF+="

[msentraid]
#register_device = false"
fi

echo "$BROKER_CONF" | sudo tee "${CONF_DIR}/broker.conf" > /dev/null
sudo chmod 600 "${CONF_DIR}/broker.conf"
ok "Broker config: ${CONF_DIR}/broker.conf"

# ============================================================
# Step 6: Systemd service
# ============================================================

info "Installing systemd service..."
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<SERVICE_EOF
[Unit]
Description=${DISPLAY_NAME} Broker for authd
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/libexec/${BINARY_NAME} --config ${CONF_DIR}/broker.conf -vv
Restart=on-failure
RestartSec=5
WatchdogSec=60

[Install]
WantedBy=multi-user.target
SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service"
sudo systemctl restart "${SERVICE_NAME}.service"
ok "Service ${SERVICE_NAME}.service started"

# ============================================================
# Step 7: Restart authd to discover the new broker
# ============================================================

info "Restarting authd to discover new broker..."
sudo systemctl restart authd.service 2>/dev/null || \
    sudo systemctl restart authd.socket 2>/dev/null || true
# Give authd a moment to start and discover the broker
sleep 1
ok "authd restarted"

# ============================================================
# Step 8: Verify
# ============================================================

echo ""
info "Verification:"

if sudo systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    ok "${SERVICE_NAME}.service is active"
else
    warn "${SERVICE_NAME}.service is NOT active"
    warn "Check logs: sudo journalctl -u ${SERVICE_NAME}.service -e"
fi

# Check if authd can see the broker
if command -v authctl &>/dev/null; then
    echo ""
    info "Registered brokers (via authctl):"
    authctl list brokers 2>/dev/null || warn "authctl list brokers failed"
fi

echo ""
echo -e "${GREEN}${BOLD}${DISPLAY_NAME} broker installed successfully!${NC}"
echo ""
echo -e "${BOLD}Test SSH login from your host:${NC}"
echo "  ssh user@domain.com@\$(./dev/dev-env.sh ip)"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  sudo journalctl -u ${SERVICE_NAME} -f    # Broker logs"
echo "  sudo journalctl -u authd -f              # authd logs"
echo "  authctl list brokers                      # List brokers"
echo "  sudo systemctl restart ${SERVICE_NAME}    # Restart broker"
echo ""
