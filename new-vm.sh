#!/bin/bash
#
# new-vm.sh — Interactive Ubuntu VM provisioner for Proxmox
# -----------------------------------------------------------------------------
# Clones a cloud-init-enabled Ubuntu template, assigns a static IP, configures
# the guest via cloud-init (user, SSH keys, keyboard layout, optional lab
# packages), and optionally exposes it through a Cloudflare Tunnel and/or
# joins it to a Tailscale network.
#
# USAGE — run this ON the Proxmox host:
#     ssh root@<your-proxmox-host>
#     bash new-vm.sh
#
# PREREQUISITES
#   1. At least one cloud-init-enabled Ubuntu template already exists in
#      Proxmox (Cloud-Image imported + `qm template <id>`). Set the IDs in
#      the TEMPLATES config below.
#   2. A storage pool and a Linux bridge already configured — set
#      TARGET_STORAGE / BRIDGE below to match your setup.
#   3. Your own SSH public key already in /root/.ssh/authorized_keys on this
#      Proxmox host — it gets copied into every VM this script creates.
#   4. (Optional) Cloudflare Tunnel account + a token with Tunnel:Edit
#      permission, if you want the public-exposure prompt to actually work.
#   5. (Optional) A Tailscale reusable auth key, if you want new VMs to
#      auto-join your tailnet.
#
# This script does NOT depend on any router-specific helper scripts — it
# finds a free IP itself with a simple ping sweep. If you run a DHCP server
# that already tracks leases (e.g. pfSense/OPNsense), you can wire up
# PFSENSE_HOST below for a more accurate lookup + automatic reservation;
# otherwise leave it blank and the ping sweep is used.
# -----------------------------------------------------------------------------

set -euo pipefail

# ============================================================================
# CONFIGURATION — edit this block for your environment
# ============================================================================

BANNER_LABEL="Homelab"                  # cosmetic only, shown in the banner

TARGET_STORAGE="local-lvm"              # your Proxmox storage pool
BRIDGE="vmbr0"                          # your Linux bridge
DNS_SERVER="1.1.1.1"                    # DNS handed to new VMs via cloud-init
VM_CORES=2
SNIPPET_STORAGE="local"                 # storage that holds cloud-init snippets
SNIPPET_DIR="/var/lib/vz/snippets"

# Cloud-init template IDs — create these yourself first (see prerequisites
# above). Numbering is arbitrary; label is just what's shown in the menu.
TEMPLATE_1_ID=9003; TEMPLATE_1_LABEL="20.04 LTS Focal Fossa"
TEMPLATE_2_ID=9002; TEMPLATE_2_LABEL="22.04 LTS Jammy Jellyfish"
TEMPLATE_3_ID=9000; TEMPLATE_3_LABEL="24.04 LTS Noble Numbat"
TEMPLATE_4_ID=9001; TEMPLATE_4_LABEL="26.04 LTS Resolute Raccoon (standard)"
DEFAULT_TEMPLATE_CHOICE=4

# Your subnets: interface name -> "network prefix" and "gateway". Add more
# pairs if you have several VLANs; a single flat network only needs one.
declare -A IFACE_PREFIX=( [lan]="192.168.1" )
declare -A IFACE_GW=(     [lan]="192.168.1.1" )
DEFAULT_IFACE="lan"
IP_SCAN_RANGE_START=100                 # ping-sweep range for a free IP
IP_SCAN_RANGE_END=250

# --- Optional: router integration for a more accurate IP + auto DHCP reservation ---
# Leave PFSENSE_HOST empty to skip this entirely and rely on the ping sweep.
# The two endpoints below are NOT included with this script — they're a stub
# for you to implement against your own router's API (pfSense/OPNsense both
# have REST APIs; a tiny custom script also works). See find_next_ip() and
# register_dhcp_reservation() further down for exactly what's expected.
PFSENSE_HOST=""                         # e.g. "192.168.1.1" — blank disables this
PFSENSE_USER="admin"
PFSENSE_KEY="/root/.ssh/pfsense_admin_ed25519"

# --- Optional: Tailscale ---
# Create a reusable auth key at https://login.tailscale.com/admin/settings/keys
# and put it in this file. Leave the file absent to skip Tailscale entirely.
TAILSCALE_AUTHKEY_FILE="/root/.tailscale-authkey"

# --- Optional: Cloudflare Tunnel ---
# Only used if you answer "y" to the exposure prompt at the end. Populate a
# file at this path (or export the vars before running) with:
#   CF_DOMAIN=example.com
#   CF_ACCOUNT_ID=...
#   CF_TUNNEL_ID=...
#   CF_ZONE_ID=...
#   CF_API_TOKEN=...        (needs Cloudflare Tunnel:Edit + DNS:Edit)
CF_SECRETS_FILE="/root/.vm-secrets"

# ============================================================================
# END CONFIGURATION
# ============================================================================

# === Visual helpers ==========================================================
C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
C_GREEN=$'\033[38;5;107m'; C_WHITE=$'\033[1;37m'
C_CYAN=$'\033[0;36m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[0;31m'

ok()   { echo -e "  ${C_GREEN}✔${C_RST}  $*"; }
info() { echo -e "  ${C_CYAN}→${C_RST}  $*"; }
step() { echo -e "\n${C_WHITE}  ▸ $*${C_RST}"; }
warn() { echo -e "  ${C_YELLOW}⚠${C_RST}  $*"; }
err()  { echo -e "  ${C_RED}✘${C_RST}  $*" >&2; }
sep()  { echo -e "${C_DIM}  ─────────────────────────────────────────────────${C_RST}"; }

spin() {
  local msg="$1"; local pid=$!; local i=0
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  while kill -0 "$pid" 2>/dev/null; do
    printf "  ${C_GREEN}%s${C_RST}  %s   \r" "${frames[$((i % 10))]}" "$msg"
    sleep 0.1; i=$((i+1))
  done
  printf "                                        \r"
}

banner() {
  clear
  echo -e "${C_WHITE}"
  echo "  ${BANNER_LABEL} — Proxmox VM provisioner"
  echo -e "${C_RST}"
  echo -e "  ${C_DIM}$(date '+%Y-%m-%d %H:%M')${C_RST}"
  sep
  echo
}
# =============================================================================

banner

# === Logging ==================================================================
LOG_DIR="/var/log/proxmox-vm"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/new-vm-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Log: $LOG_FILE"

[[ -f "$CF_SECRETS_FILE" ]] && source "$CF_SECRETS_FILE"
TS_AUTH_KEY="$(cat "$TAILSCALE_AUTHKEY_FILE" 2>/dev/null || true)"

# --- Helper: Cloudflare API response check (used later) ---------------------
cf_check_success() {
  python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception as e:
    print(f'invalid response from Cloudflare ({e})')
    sys.exit(1)
if d.get('success'):
    sys.exit(0)
msgs = '; '.join(m.get('message', '?') for m in d.get('errors', [])) or 'unknown error'
print(msgs)
sys.exit(1)
"
}

# --- Helper: find a free IP -------------------------------------------------
# Default: simple ping sweep. Swap in a call to your router's API here if you
# want something more accurate than "doesn't respond to ping right now".
find_next_ip() {
  local prefix="$1"
  if [[ -n "$PFSENSE_HOST" ]]; then
    local ip
    ip=$(ssh -n -i "${PFSENSE_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "${PFSENSE_USER}@${PFSENSE_HOST}" \
      "/usr/local/bin/php /home/prox/find-next-ip.php '${SELECTED_IFACE}' '${prefix}'" 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    warn "Router lookup failed or not configured — falling back to ping sweep."
  fi
  for i in $(seq "$IP_SCAN_RANGE_START" "$IP_SCAN_RANGE_END"); do
    local candidate="${prefix}.${i}"
    if ! ping -c1 -W1 "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# --- Helper: register a DHCP reservation (optional, no-op unless configured) -
register_dhcp_reservation() {
  [[ -z "$PFSENSE_HOST" ]] && return 0
  ssh -n -i "${PFSENSE_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "${PFSENSE_USER}@${PFSENSE_HOST}" \
    "/usr/local/bin/php /home/prox/add-dhcp-reservation.php '${SELECTED_IFACE}' '$1' '$2' '$3'" 2>/dev/null \
    && ok "DHCP reservation registered: $3 -> $2 ($1)" \
    || warn "Could not register a DHCP reservation (router integration not set up) — that's fine, the static IP is still configured on the VM itself."
}

# --- Make sure we're on Proxmox ----------------------------------------------
if ! command -v qm >/dev/null 2>&1; then
  err "Run this ON a Proxmox host (it needs the 'qm' command)."
  exit 1
fi

# --- 1. Choose Ubuntu version -------------------------------------------------
echo
echo -e "  ${C_WHITE}Ubuntu version (LTS):${C_RST}"
echo -e "  ${C_DIM}[1]${C_RST}  ${TEMPLATE_1_LABEL}   ${C_DIM}(template ${TEMPLATE_1_ID})${C_RST}"
echo -e "  ${C_DIM}[2]${C_RST}  ${TEMPLATE_2_LABEL}   ${C_DIM}(template ${TEMPLATE_2_ID})${C_RST}"
echo -e "  ${C_DIM}[3]${C_RST}  ${TEMPLATE_3_LABEL}   ${C_DIM}(template ${TEMPLATE_3_ID})${C_RST}"
echo -e "  ${C_DIM}[4]${C_RST}  ${TEMPLATE_4_LABEL}   ${C_DIM}(template ${TEMPLATE_4_ID})${C_RST}"
read -rp "  Choice [${DEFAULT_TEMPLATE_CHOICE}]: " VERSION_CHOICE
case "${VERSION_CHOICE:-$DEFAULT_TEMPLATE_CHOICE}" in
  1) TEMPLATE_ID=$TEMPLATE_1_ID; UBUNTU_VER=$TEMPLATE_1_LABEL ;;
  2) TEMPLATE_ID=$TEMPLATE_2_ID; UBUNTU_VER=$TEMPLATE_2_LABEL ;;
  3) TEMPLATE_ID=$TEMPLATE_3_ID; UBUNTU_VER=$TEMPLATE_3_LABEL ;;
  4) TEMPLATE_ID=$TEMPLATE_4_ID; UBUNTU_VER=$TEMPLATE_4_LABEL ;;
  *) err "Invalid choice."; exit 1 ;;
esac

if ! qm status "$TEMPLATE_ID" >/dev/null 2>&1; then
  err "Template $TEMPLATE_ID doesn't exist. Edit the TEMPLATES config at the top of this script, or create the template first."
  exit 1
fi

# --- 2. Choose subnet ---------------------------------------------------------
echo
echo -e "  ${C_WHITE}Network:${C_RST}"
i=1
declare -A MENU_IFACE
for name in "${!IFACE_PREFIX[@]}"; do
  echo -e "  ${C_DIM}[$i]${C_RST}  $name   ${IFACE_PREFIX[$name]}.x"
  MENU_IFACE[$i]="$name"
  i=$((i+1))
done
read -rp "  Choice [1]: " SUBNET_CHOICE
SELECTED_IFACE="${MENU_IFACE[${SUBNET_CHOICE:-1}]:-$DEFAULT_IFACE}"

if [[ -z "${IFACE_PREFIX[$SELECTED_IFACE]+x}" ]]; then
  err "Unknown interface '$SELECTED_IFACE' — check the IFACE_PREFIX config."
  exit 1
fi

SUBNET_PREFIX="${IFACE_PREFIX[$SELECTED_IFACE]}"
GATEWAY="${IFACE_GW[$SELECTED_IFACE]}"

# --- 3. Find a free IP ---------------------------------------------------------
step "Looking for a free IP on ${SUBNET_PREFIX}.0/24"
NEXT_IP=$(find_next_ip "$SUBNET_PREFIX") || { err "Couldn't find a free IP in ${SUBNET_PREFIX}.${IP_SCAN_RANGE_START}-${IP_SCAN_RANGE_END}."; exit 1; }
info "Suggested IP: ${C_GREEN}$NEXT_IP${C_RST}"
read -rp "  Use $NEXT_IP? (Y/n): " IP_CONFIRM
if [[ "${IP_CONFIRM,,}" == "n" ]]; then
  read -rp "  Enter an IP manually (e.g. ${SUBNET_PREFIX}.150): " NEXT_IP
fi

# --- 4. Interactive prompts ---------------------------------------------------
echo
step "VM configuration"
read -rp "  VM name: " VM_NAME
read -rp "  Username: " USERNAME
read -rsp "  Password: " PASSWORD; echo
read -rp "  RAM in MB [2048]: " VM_MEMORY_INPUT
VM_MEMORY="${VM_MEMORY_INPUT:-2048}"
read -rp "  Disk size (e.g. 20G, 50G) [20G]: " DISK_SIZE_INPUT
DISK_SIZE="${DISK_SIZE_INPUT:-20G}"
echo
echo -e "  ${C_WHITE}Lab type:${C_RST}"
echo -e "  ${C_DIM}[1]${C_RST}  Bare       — plain Ubuntu ${C_DIM}(default)${C_RST}"
echo -e "  ${C_DIM}[2]${C_RST}  Docker     — Docker + Compose"
echo -e "  ${C_DIM}[3]${C_RST}  K8s        — microk8s"
echo -e "  ${C_DIM}[4]${C_RST}  Ansible    — Python3 + pip"
echo -e "  ${C_DIM}[5]${C_RST}  OVS        — Open vSwitch + bridge-utils + vlan"
echo -e "  ${C_DIM}[6]${C_RST}  Routing    — FRRouting (OSPF/BGP/RIP)"
echo -e "  ${C_DIM}[7]${C_RST}  VPN        — WireGuard + OpenVPN"
echo -e "  ${C_DIM}[8]${C_RST}  Monitoring — Node Exporter + Prometheus"
echo -e "  ${C_DIM}[9]${C_RST}  LEMP       — Nginx + MariaDB + PHP"
read -rp "  Choice [1]: " LAB_TYPE_CHOICE
case "${LAB_TYPE_CHOICE:-1}" in
  1) LAB_TYPE="Bare";       LAB_EXTRA_PKGS="";                                                  LAB_EXTRA_CMDS="" ;;
  2) LAB_TYPE="Docker";     LAB_EXTRA_PKGS="";                                                  LAB_EXTRA_CMDS=$'curl -fsSL https://get.docker.com | sh\nusermod -aG docker '"${USERNAME}" ;;
  3) LAB_TYPE="K8s";        LAB_EXTRA_PKGS="snapd";                                             LAB_EXTRA_CMDS=$'snap install microk8s --classic\nusermod -aG microk8s '"${USERNAME}"$'\nmicrok8s enable dns' ;;
  4) LAB_TYPE="Ansible";    LAB_EXTRA_PKGS="python3 python3-pip python3-venv";                  LAB_EXTRA_CMDS="" ;;
  5) LAB_TYPE="OVS";        LAB_EXTRA_PKGS="openvswitch-switch bridge-utils vlan";              LAB_EXTRA_CMDS=$'systemctl enable --now openvswitch-switch' ;;
  6) LAB_TYPE="Routing";    LAB_EXTRA_PKGS="frr frr-pythontools";                               LAB_EXTRA_CMDS=$'sed -i "s/^bgpd=no/bgpd=yes/;s/^ospfd=no/ospfd=yes/;s/^ripd=no/ripd=yes/" /etc/frr/daemons\nsystemctl enable --now frr' ;;
  7) LAB_TYPE="VPN";        LAB_EXTRA_PKGS="wireguard openvpn easy-rsa";                        LAB_EXTRA_CMDS=$'echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf\nsysctl -p' ;;
  8) LAB_TYPE="Monitoring"; LAB_EXTRA_PKGS="prometheus-node-exporter prometheus";               LAB_EXTRA_CMDS=$'systemctl enable --now prometheus-node-exporter\nsystemctl enable --now prometheus' ;;
  9) LAB_TYPE="LEMP";       LAB_EXTRA_PKGS="nginx mariadb-server php php-fpm php-mysql php-cli"; LAB_EXTRA_CMDS=$'systemctl enable --now nginx\nsystemctl enable --now mariadb\nmysql_secure_installation --use-default' ;;
  *) err "Invalid choice."; exit 1 ;;
esac
read -rp "  VM ID (Enter for auto): " VMID

if [[ -z "$VM_NAME" || -z "$USERNAME" || -z "$PASSWORD" ]]; then
  err "Name, username and password are required."
  exit 1
fi

# --- 5. Find a free VMID ------------------------------------------------------
if [[ -z "$VMID" ]]; then
  VMID=200
  while qm status "$VMID" >/dev/null 2>&1 || pct status "$VMID" >/dev/null 2>&1; do
    VMID=$((VMID + 1))
  done
  info "Auto-picked VMID: $VMID"
fi

if qm status "$VMID" >/dev/null 2>&1; then
  err "VMID $VMID is already taken."
  exit 1
fi

# --- 6. Clone the template -----------------------------------------------------
step "Cloning template $TEMPLATE_ID -> VM $VMID ($VM_NAME) ..."
qm clone "$TEMPLATE_ID" "$VMID" --name "$VM_NAME" --full --storage "$TARGET_STORAGE" &
spin "Cloning template, this takes a minute..."
wait $!
ok "Cloned — VMID $VMID"

step "Resizing disk to $DISK_SIZE"
qm resize "$VMID" scsi0 "$DISK_SIZE"
ok "Disk resized"

# --- 7. Set the NIC -------------------------------------------------------------
qm set "$VMID" --net0 "virtio,bridge=${BRIDGE}"

# --- 8. Grab the MAC address (after the NIC reset, otherwise it's stale) -------
VM_MAC=$(qm config "$VMID" | grep '^net0:' | grep -oP '(?:virtio|e1000)=\K[^,]+')
info "MAC: $VM_MAC"

# --- 9. Make sure snippet storage is enabled -----------------------------------
if ! grep -A6 "^dir: ${SNIPPET_STORAGE}$" /etc/pve/storage.cfg | grep -q "snippets"; then
  CURRENT_CONTENT=$(pvesh get "/storage/${SNIPPET_STORAGE}" --output-format json \
    | grep -o '"content":"[^"]*"' | cut -d'"' -f4)
  pvesm set "$SNIPPET_STORAGE" --content "${CURRENT_CONTENT},snippets"
fi
mkdir -p "$SNIPPET_DIR"

# --- 10. Build cloud-init user-data (keyboard + SSH key + no cleartext pw) -----
USER_SNIPPET="userdata-${VMID}.yaml"
step "Building cloud-init configuration"
{
  # SHA-512 hash for cloud-init — no cleartext password is ever stored anywhere.
  HASHED_PW=$(openssl passwd -6 "${PASSWORD}")

  echo "#cloud-config"
  echo "hostname: ${VM_NAME}"
  echo "fqdn: ${VM_NAME}"
  echo "manage_etc_hosts: true"
  echo "keyboard:"
  echo "  layout: us"
  echo "users:"
  echo "  - name: ${USERNAME}"
  echo "    passwd: '${HASHED_PW}'"
  echo "    lock_passwd: false"
  echo "    shell: /bin/bash"
  echo "    groups: [sudo, adm]"
  if [[ -f /root/.ssh/authorized_keys ]]; then
    echo "    ssh_authorized_keys:"
    while IFS= read -r key; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      echo "      - ${key}"
    done < /root/.ssh/authorized_keys
  fi
  echo "packages:"
  echo "  - qemu-guest-agent"
  if [[ -n "$LAB_EXTRA_PKGS" ]]; then
    for pkg in $LAB_EXTRA_PKGS; do echo "  - ${pkg}"; done
  fi
  echo "write_files:"
  echo "  - path: /etc/sudoers.d/${USERNAME}"
  echo "    content: \"${USERNAME} ALL=(ALL) NOPASSWD:ALL\\n\""
  echo "    permissions: '0440'"
  echo "runcmd:"
  echo "  - systemctl enable --now qemu-guest-agent"
  if [[ -n "$LAB_EXTRA_CMDS" ]]; then
    while IFS= read -r cmd; do echo "  - ${cmd}"; done <<< "$LAB_EXTRA_CMDS"
  fi
  if [[ -n "$TS_AUTH_KEY" ]]; then
    echo "  - curl -fsSL https://tailscale.com/install.sh | sh"
    echo "  - tailscale up --authkey=${TS_AUTH_KEY} --hostname=${VM_NAME} --ssh --accept-routes"
  fi
} > "${SNIPPET_DIR}/${USER_SNIPPET}"
ok "user-data snippet written"

# --- 11. Build cloud-init network-data (static IP) ------------------------------
NET_SNIPPET="network-${VMID}.yaml"
step "Building cloud-init network config: ${NEXT_IP}/24 via ${GATEWAY}"
cat > "${SNIPPET_DIR}/${NET_SNIPPET}" <<EOF
version: 2
ethernets:
  main:
    match:
      name: "en*"
    addresses:
      - ${NEXT_IP}/24
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses:
        - ${DNS_SERVER}
EOF
ok "network-data snippet written"

# --- 12. Wire up cloud-init ------------------------------------------------------
step "Configuring cloud-init"
qm set "$VMID" --ciuser "$USERNAME"
qm set "$VMID" --nameserver "$DNS_SERVER"
qm set "$VMID" --cicustom "user=${SNIPPET_STORAGE}:snippets/${USER_SNIPPET},network=${SNIPPET_STORAGE}:snippets/${NET_SNIPPET}"
qm set "$VMID" --memory "$VM_MEMORY" --cores "$VM_CORES"
ok "Cloud-init configured (password only stored as a hash — no --cipassword)"

# --- 13. Optional: register a DHCP reservation on your router --------------------
step "Registering DHCP reservation (skipped automatically if not configured)"
register_dhcp_reservation "$SELECTED_IFACE" "$NEXT_IP" "$VM_NAME" "$VM_MAC"

# --- 14. Snapshot (clean rollback point) ------------------------------------------
step "Taking snapshot 'clean'"
qm snapshot "$VMID" clean --description "Clean state created by new-vm.sh"
ok "Snapshot done (rollback: qm rollback $VMID clean)"

# --- 15. Start the VM ---------------------------------------------------------------
step "Starting VM $VMID"
qm start "$VMID" &
spin "Starting VM, waiting for boot..."
wait $!
ok "VM $VMID is up"

# --- 16. Optional: Cloudflare Tunnel route ------------------------------------------
cf_check_success_wrapper() { cf_check_success; }

CF_HOSTNAME=""
CF_TUNNEL_OK="false"
CF_DNS_OK="false"
CF_FAIL_REASON=""
if [[ -n "${CF_API_TOKEN:-}" ]]; then
  echo
  read -rp "  Expose this VM via Cloudflare Tunnel? (y/N): " CF_EXPOSE
  if [[ "${CF_EXPOSE,,}" == "y" ]]; then
    read -rp "  Subdomain (e.g. myapp -> myapp.${CF_DOMAIN}): " CF_SUBDOMAIN
    read -rp "  Protocol + port (e.g. http or https, default 80): " CF_PROTO
    CF_PROTO="${CF_PROTO:-http}"
    CF_SERVICE="${CF_PROTO}://${NEXT_IP}:$([ "$CF_PROTO" = "https" ] && echo 443 || echo 80)"
    read -rp "  Different port? (Enter for default): " CF_PORT_OVERRIDE
    [[ -n "$CF_PORT_OVERRIDE" ]] && CF_SERVICE="${CF_PROTO}://${NEXT_IP}:${CF_PORT_OVERRIDE}"
    CF_HOSTNAME="${CF_SUBDOMAIN}.${CF_DOMAIN}"

    step "Fetching current tunnel configuration"
    CURRENT_CONFIG=$(curl -s --max-time 15 \
      "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" || true)

    if [[ -n "$CURRENT_CONFIG" ]] && CONFIG_ERR=$(printf '%s' "$CURRENT_CONFIG" | cf_check_success); then
      NEW_INGRESS=$(printf '%s' "$CURRENT_CONFIG" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
ingress = d['result']['config']['ingress']
ingress = [r for r in ingress if r.get('hostname') != sys.argv[1]]
ingress.insert(-1, {'hostname': sys.argv[1], 'service': sys.argv[2]})
print(json.dumps({'config': {'ingress': ingress}}))
" "${CF_HOSTNAME}" "${CF_SERVICE}")

      UPDATE=$(curl -s --max-time 15 -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$NEW_INGRESS" || true)

      if UPDATE_ERR=$(printf '%s' "$UPDATE" | cf_check_success); then
        ok "Tunnel route: ${CF_HOSTNAME} -> ${CF_SERVICE}"
        CF_TUNNEL_OK="true"
        DNS=$(curl -s --max-time 15 -X POST \
          "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
          -H "Authorization: Bearer ${CF_API_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"type\":\"CNAME\",\"name\":\"${CF_SUBDOMAIN}\",\"content\":\"${CF_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}" || true)
        if DNS_ERR=$(printf '%s' "$DNS" | cf_check_success); then
          ok "DNS CNAME: ${CF_HOSTNAME}"
          CF_DNS_OK="true"
        else
          warn "DNS failed: ${DNS_ERR} (record may already exist — fine if the tunnel route above succeeded)"
          CF_FAIL_REASON="DNS: ${DNS_ERR}"
        fi
      else
        err "Tunnel update failed: ${UPDATE_ERR}"
        CF_FAIL_REASON="Tunnel: ${UPDATE_ERR}"
      fi
    else
      err "Could not fetch the current tunnel configuration — check CF_API_TOKEN permissions."
      CF_FAIL_REASON="Fetch failed"
    fi
  fi
else
  info "Cloudflare Tunnel exposure skipped (no CF_API_TOKEN configured in ${CF_SECRETS_FILE})"
fi

echo
sep
echo -e "  ${C_GREEN}✔  VM READY${C_RST}"
sep
echo -e "  ${C_WHITE}Name      ${C_RST}  $VM_NAME  ${C_DIM}(VMID $VMID)${C_RST}"
echo -e "  ${C_WHITE}Ubuntu    ${C_RST}  $UBUNTU_VER"
echo -e "  ${C_WHITE}IP        ${C_RST}  ${C_GREEN}$NEXT_IP${C_RST}  ${C_DIM}(static · gw $GATEWAY)${C_RST}"
echo -e "  ${C_WHITE}RAM/Disk  ${C_RST}  ${VM_MEMORY} MB · $DISK_SIZE"
echo -e "  ${C_WHITE}Lab type  ${C_RST}  $LAB_TYPE"
echo -e "  ${C_WHITE}User      ${C_RST}  $USERNAME"
if [[ -n "$TS_AUTH_KEY" ]]; then
  echo -e "  ${C_WHITE}Tailscale ${C_RST}  ${C_GREEN}✔${C_RST}  ssh ${USERNAME}@${VM_NAME}"
else
  echo -e "  ${C_WHITE}Tailscale ${C_RST}  ${C_DIM}not configured${C_RST}"
fi
if [[ -n "$CF_HOSTNAME" ]]; then
  if [[ "$CF_TUNNEL_OK" == "true" && "$CF_DNS_OK" == "true" ]]; then
    echo -e "  ${C_WHITE}Cloudflare${C_RST}  ${C_GREEN}✔${C_RST}  https://${CF_HOSTNAME}"
  elif [[ "$CF_TUNNEL_OK" == "true" ]]; then
    echo -e "  ${C_WHITE}Cloudflare${C_RST}  ${C_YELLOW}⚠${C_RST}  tunnel route done but DNS missing — ${CF_FAIL_REASON}"
  else
    echo -e "  ${C_WHITE}Cloudflare${C_RST}  ${C_RED}✘${C_RST}  failed — ${CF_FAIL_REASON}"
  fi
fi
sep
echo -e "  ${C_DIM}SSH:   ssh ${USERNAME}@${NEXT_IP}${C_RST}"
echo -e "  ${C_DIM}Log:   $LOG_FILE${C_RST}"
sep
echo

# === Append to the VM registry log ==========================================
REGISTRY="/var/log/proxmox-vm/vm-registry.log"
CF_INFO="$([[ "$CF_TUNNEL_OK" == "true" && "$CF_DNS_OK" == "true" ]] && echo "${CF_HOSTNAME}" || echo "")"
TS_INFO="$([[ -n "$TS_AUTH_KEY" ]] && echo "yes" || echo "no")"
printf '%s\tCREATED\t%s\t%s\t%s\t%s\t%s\tTS:%s\tCF:%s\tSnap:clean\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$VMID" "$VM_NAME" "$NEXT_IP" \
  "$USERNAME" "$LAB_TYPE" "$TS_INFO" "$CF_INFO" >> "$REGISTRY"
info "Logged to $REGISTRY"
