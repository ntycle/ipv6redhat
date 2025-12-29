#!/bin/bash
# 3proxy IPv6 Installer - AWS / RHEL / Rocky / Alma
# LOGGED + SAFE + NO SILENT STEP

set -e
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# ===== COLORS =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[+] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[!] $1${NC}"
}

err() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# ===== ROOT CHECK =====
[[ $EUID -ne 0 ]] && err "Run as root (sudo bash $0)"

REAL_USER=${SUDO_USER:-ec2-user}

clear
echo -e "${BLUE}========== 3proxy IPv6 AWS Installer ==========${NC}"

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

# ===== IPv6 PREFIX (AWS SAFE) =====
IP6=$(ip -6 addr show dev "$IFACE" scope global \
    | awk '/inet6/ {print $2}' \
    | head -n1 \
    | cut -d/ -f1 \
    | cut -d: -f1-5)

[[ -z "$IP6" ]] && err "IPv6 /64 not found"
log "IPv6 prefix: $IP6::/64"

# ===== CONFIG =====
FIRST_PORT=22000
LAST_PORT=22700
PROXY_COUNT=$((LAST_PORT - FIRST_PORT + 1))

echo -e "${BLUE}Ports: $FIRST_PORT-$LAST_PORT | Total: $PROXY_COUNT${NC}"
read -p "Press ENTER to continue..."

# ===== RANDOM =====
rand() { tr </dev/urandom -dc A-Za-z0-9 | head -c8; }

# ===== IPv6 GEN (NO DUPLICATE) =====
gen_ipv6() {
    echo "$IP6::$(printf '%x' $1)"
}

# ===== INSTALL 3PROXY =====
log "Downloading & compiling 3proxy"
cd /tmp
wget https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz
tar xzf 0.9.4.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux
mkdir -p /usr/local/3proxy/{bin,logs}
cp src/3proxy /usr/local/3proxy/bin/
chmod +x /usr/local/3proxy/bin/3proxy
log "3proxy compiled"

# ===== DATA =====
PROXY_DIR="/home/$REAL_USER/3proxy"
mkdir -p "$PROXY_DIR"
DATA="$PROXY_DIR/data.txt"

log "Generating proxy data"
> "$DATA"
for port in $(seq $FIRST_PORT $LAST_PORT); do
    echo "user$port/$(rand)/$IP4/$port/$(gen_ipv6 $port)" >> "$DATA"
done

# ===== ADD IPV6 =====
log "Generating IPv6 assign script"
BOOT="$PROXY_DIR/boot_ifconfig.sh"
awk -F "/" '{print "ip -6 addr add " $5 "/64 dev '"$IFACE"'"}' "$DATA" > "$BOOT"
chmod +x "$BOOT"

# ===== CONFIG 3PROXY =====
log "Generating 3proxy config"
CFG="/usr/local/3proxy/3proxy.cfg"
cat > "$CFG" <<EOF
daemon
maxconn 4000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 2001:4860:4860::8888
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
flush
auth strong
users $(awk -F "/" '{printf "%s:CL:%s ",$1,$2}' "$DATA")

$(awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush"}' "$DATA")

deny *
EOF

# ===== SYSTEMD =====
log "Creating systemd service"
cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy IPv6 Proxy
After=network.target

[Service]
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
systemctl enable firewalld --now
firewall-cmd --permanent --add-port=${FIRST_PORT}-${LAST_PORT}/tcp
firewall-cmd --reload

# ===== PROXY LIST =====
log "Generating proxy list"
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

echo -e "${BLUE}========= DONE =========${NC}"
echo "Proxy list: $OUT"
echo "systemctl status 3proxy"
