#!/bin/bash
# 3proxy IPv6 AWS – PRODUCTION READY (50 proxies)
# Tested: AWS EC2 / RHEL 9 / Rocky / Alma

set -e
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# ===== COLORS =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# ===== ROOT CHECK =====
[[ $EUID -ne 0 ]] && err "Run as root (sudo bash $0)"
REAL_USER=${SUDO_USER:-ec2-user}

clear
echo -e "${BLUE}========== 3proxy IPv6 AWS Installer (PROD) ==========${NC}"

# ===== DEPENDENCIES =====
log "Installing dependencies"
dnf install -y gcc make wget tar curl net-tools firewalld

# ===== NETWORK =====
IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
[[ -z "$IFACE" ]] && err "Cannot detect network interface"
log "Network interface: $IFACE"

# ===== IPv4 =====
IP4=$(curl -4 -s --max-time 5 icanhazip.com || true)
[[ -z "$IP4" ]] && err "Cannot detect IPv4"
log "IPv4: $IP4"

# ===== IPv6 PREFIX (/64 AWS SAFE) =====
IP6_PREFIX=$(ip -6 addr show dev "$IFACE" scope global \
    | awk '/inet6/ && /\/64/ {print $2}' \
    | head -n1 \
    | cut -d/ -f1 \
    | cut -d: -f1-4)

[[ -z "$IP6_PREFIX" ]] && err "IPv6 /64 prefix not found"
log "IPv6 prefix: $IP6_PREFIX::/64"

# ===== CONFIG =====
FIRST_PORT=22000
PROXY_COUNT=50
LAST_PORT=$((FIRST_PORT + PROXY_COUNT - 1))

echo -e "${BLUE}Ports: $FIRST_PORT-$LAST_PORT | Proxies: $PROXY_COUNT${NC}"
read -p "Press ENTER to continue..."

# ===== UTILS =====
rand() { tr </dev/urandom -dc A-Za-z0-9 | head -c8; }

gen_ipv6() {
    printf "%s:%x:%x:%x:%x\n" "$IP6_PREFIX" $RANDOM $RANDOM $RANDOM $1
}

# ===== INSTALL 3PROXY =====
log "Downloading & compiling 3proxy 0.9.5"
cd /tmp
wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.5.tar.gz
tar xzf 0.9.5.tar.gz
cd 3proxy-0.9.5
make -f Makefile.Linux
mkdir -p /usr/local/3proxy/{bin,logs}
cp bin/3proxy /usr/local/3proxy/bin/
chmod +x /usr/local/3proxy/bin/3proxy
log "3proxy installed"

# ===== DATA =====
PROXY_DIR="/home/$REAL_USER/3proxy"
mkdir -p "$PROXY_DIR"
DATA="$PROXY_DIR/data.txt"
> "$DATA"

log "Generating proxy credentials & IPv6"
for i in $(seq 1 $PROXY_COUNT); do
    PORT=$((FIRST_PORT + i - 1))
    echo "user$i/$(rand)/$IP4/$PORT/$(gen_ipv6 $PORT)" >> "$DATA"
done

# ===== ADD IPV6 =====
BOOT="$PROXY_DIR/ipv6_assign.sh"
log "Creating IPv6 assign script"
awk -F "/" '{print "ip -6 addr add " $5 "/64 dev '"$IFACE"'"}' "$DATA" > "$BOOT"
chmod +x "$BOOT"

# ===== USERS FILE =====
USERS="/usr/local/3proxy/users.lst"
awk -F "/" '{print $1 ":CL:" $2}' "$DATA" > "$USERS"

# ===== 3PROXY CONFIG =====
CFG="/usr/local/3proxy/3proxy.cfg"
log "Creating 3proxy config"
cat > "$CFG" <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 2001:4860:4860::8888
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /usr/local/3proxy/logs/3proxy.log D
auth strong
users $USERS

$(awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush"}' "$DATA")

deny *
EOF

# ===== SYSTEMD =====
log "Creating systemd service"
cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy IPv6 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/bash $BOOT
ExecStart=/usr/local/3proxy/bin/3proxy $CFG
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable 3proxy
systemctl restart 3proxy

# ===== FIREWALL =====
log "Configuring firewall"
if systemctl list-unit-files | grep -q firewalld; then
    systemctl enable firewalld --now
    firewall-cmd --permanent --add-port=${FIRST_PORT}-${LAST_PORT}/tcp
    firewall-cmd --reload
else
    warn "firewalld not found, skipping"
fi

# ===== PROXY LIST =====
OUT="$PROXY_DIR/proxy.txt"
awk -F "/" '{print "["$5"]:"$4":"$1":"$2}' "$DATA" > "$OUT"
chown -R $REAL_USER:$REAL_USER "$PROXY_DIR"

# ===== TEST =====
FIRST=$(head -n1 "$OUT")
log "Testing first proxy: $FIRST"
IP=$(echo "$FIRST" | cut -d] -f1 | tr -d '[')
PORT=$(echo "$FIRST" | cut -d: -f2)
USER=$(echo "$FIRST" | cut -d: -f3)
PASS=$(echo "$FIRST" | cut -d: -f4)

curl -6 -x "http://$USER:$PASS@[$IP]:$PORT" https://api64.ipify.org || warn "Test failed"

echo -e "${BLUE}========== DONE ==========${NC}"
echo "Proxy list: $OUT"
echo "Check: systemctl status 3proxy"
