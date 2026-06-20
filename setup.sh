#!/usr/bin/env bash
# =============================================================================
#  setup.sh
#  Pi-hole DNS Sinkhole — Home Lab — Phase 1 Setup
#
#  Incorporates fixes for all 6 problems documented in
#  docs/PHASE1-troubleshooting.md. Run as a user with sudo privileges
#  (not as root directly) from inside this repo's root directory.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 0. Confirm we're in the repo root ─────────────────────────────────────
if [[ ! -f "docker-compose.yml" ]]; then
  error "docker-compose.yml not found. Run this script from the repo root."
fi

# ── 1. Create .env from template if missing ───────────────────────────────
if [[ ! -f ".env" ]]; then
  info "No .env found — creating one from .env.example"
  cp .env.example .env

  HOST_UID=$(id -u)
  HOST_GID=$(id -g)
  sed -i "s/^PIHOLE_UID=.*/PIHOLE_UID=${HOST_UID}/" .env
  sed -i "s/^PIHOLE_GID=.*/PIHOLE_GID=${HOST_GID}/" .env
  info "Set PIHOLE_UID=${HOST_UID} and PIHOLE_GID=${HOST_GID} to match your user (fixes Problem 3)"

  warn "Edit .env now and set a real WEBPASSWORD before continuing."
  warn "Default web port is 8081 (avoids the port 80 conflict from Problem 2)."
  read -p "Press Enter once you've edited .env, or Ctrl+C to stop and edit it now... "
fi

# ── 2. Validate YAML before doing anything else (catches Problem 1) ───────
info "Validating docker-compose.yml syntax..."
if ! docker compose config > /dev/null 2>&1; then
  error "docker-compose.yml failed validation. Run 'docker compose config' to see the exact line."
fi
info "YAML syntax OK."

# ── 3. Disable systemd-resolved stub listener (frees port 53) ─────────────
info "Checking if port 53 is in use by systemd-resolved..."
if ss -tulpn 2>/dev/null | grep -q ':53 '; then
  info "Disabling systemd-resolved stub listener to free port 53..."
  sudo mkdir -p /etc/systemd/resolved.conf.d
  sudo tee /etc/systemd/resolved.conf.d/pihole.conf > /dev/null <<EOF
[Resolve]
DNSStubListener=no
EOF
  sudo systemctl restart systemd-resolved
  info "systemd-resolved stub listener disabled."
else
  info "Port 53 appears free."
fi

# ── 4. Install Docker if not present ───────────────────────────────────────
if command -v docker &>/dev/null; then
  info "Docker already installed: $(docker --version)"
else
  info "Installing Docker..."
  sudo apt-get update -qq
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
  info "Docker installed. You may need to log out and back in for group changes."
fi

# ── 5. Create volume directories (DNSSEC config already exists from repo) ─
info "Confirming volume directories exist..."
mkdir -p volumes/pihole/etc-pihole
mkdir -p volumes/pihole/etc-dnsmasq.d

if [[ -f "volumes/pihole/etc-dnsmasq.d/99-dnssec.conf" ]]; then
  info "DNSSEC fix config (99-dnssec.conf) already present — Problem 6 fix included from the start."
else
  warn "99-dnssec.conf missing — DNSSEC may show as configured but not actually validating."
  warn "See docs/PHASE1-troubleshooting.md Problem 6 to recreate it."
fi

# ── 6. Read web port from .env for firewall rule ──────────────────────────
WEBPORT=$(grep -E '^PIHOLE_WEBPORT=' .env | cut -d= -f2)
WEBPORT=${WEBPORT:-8081}

# ── 7. UFW firewall rules (fixes Problem 5) ────────────────────────────────
if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
  info "Opening firewall ports for Pi-hole (DNS + web UI on port ${WEBPORT})..."
  sudo ufw allow 53/tcp  comment "Pi-hole DNS TCP"
  sudo ufw allow 53/udp  comment "Pi-hole DNS UDP"
  sudo ufw allow "${WEBPORT}/tcp" comment "Pi-hole Web UI"
  sudo ufw reload
  info "UFW rules applied for port ${WEBPORT} (fixes Problem 5: web UI timeout)."
else
  warn "UFW not active — skipping firewall rules. If you enable UFW later, remember port ${WEBPORT}."
fi

# ── 8. Deploy ────────────────────────────────────────────────────────────
info "Pulling Pi-hole image and starting stack..."
docker compose down 2>/dev/null || true
docker compose up -d

info "Waiting 15 seconds for Pi-hole to initialise..."
sleep 15

# ── 9. Health check ─────────────────────────────────────────────────────
if docker ps --filter "name=pihole" --filter "status=running" | grep -q pihole; then
  HOST_IP=$(hostname -I | awk '{print $1}')
  HEALTH=$(docker inspect --format='{{.State.Health.Status}}' pihole 2>/dev/null || echo "unknown")

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║        Pi-hole Phase 1 Setup Complete             ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Container health: ${YELLOW}${HEALTH}${NC}"
  echo -e "  Web Admin UI:      ${YELLOW}http://${HOST_IP}:${WEBPORT}/admin${NC}"
  echo -e "  DNS Server:        ${YELLOW}${HOST_IP}${NC} (port 53)"
  echo ""
  echo -e "  ${YELLOW}Next:${NC} verify DNSSEC is actually validating (Problem 6 fix):"
  echo -e "    dig cloudflare.com @127.0.0.1 +dnssec | grep \"flags:\""
  echo -e "    Look for the 'ad' flag in the output."
  echo ""
  echo -e "  ${YELLOW}Then:${NC} point one device's DNS at ${HOST_IP} to validate Phase 1,"
  echo -e "  or see docs/PHASE2-network-rollout.md to roll out to your whole network."
  echo ""

  if [[ "$HEALTH" != "healthy" ]]; then
    warn "Container is not yet 'healthy' — this matches Problem 3 in docs/PHASE1-troubleshooting.md."
    warn "Run: docker compose logs -f pihole"
  fi
else
  error "Pi-hole container did not start. Run: docker compose logs pihole"
fi
