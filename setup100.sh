#!/bin/bash
# =========================================================
# 3PROXY IPV6 AWS PREFIX MODE - PRODUCTION READY
# 100 IPv6 proxies | No IPv6 add | Reboot safe
# =========================================================

set -e
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

### ===== CONFIG =====
PROXY_COUNT=100
START_PORT=20000
END_PORT=$((START_PORT + PROXY_COUNT - 1))
INSTALL_DIR="/usr/local/3proxy"
WORKDIR="/opt/3proxy"
CFG="$INSTALL_DIR/3proxy.cfg"

### ===== CHECK ROOT =====
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

echo "[+] Installing dependencies"
dnf install -y gcc make wget tar curl >/dev/null

### ===== SYSCTL REQUIRED =====
sysctl -w net.ipv6.ip_nonlocal_bind=1 >/dev/null
grep -q ip_nonlocal_bind /etc/sysctl.conf || \
echo "net.ipv6.ip_nonlocal_bind=1" >> /etc/sysctl.conf

### ===== NETWORK INFO =====
IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
IP4=$(curl -4 -s https://icanhazip.com)

PREFIX=$(ip -6 route | awk '/proto ra/ {print $1}' | head -n1 | cut -d/ -f1 | cut -d: -f1-4)

if [[ -z "$PREFIX" ]]; then
  echo "IPv6 prefix not found"
  exit 1
fi

echo "[+] IPv4      : $IP4"
echo "[+] IPv6 pref : $PREFIX::/80"

### ===== INSTALL 3PROXY =====
echo "[+] Installing 3proxy"
cd /tmp
wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.5.tar.gz
tar xzf 0.9.5.tar.gz
cd 3proxy-0.9.5
make -f Makefile.Linux >/dev/null

mkdir -p $INSTALL_DIR/{bin,logs}
cp bin/3proxy $INSTALL_DIR/bin/
chmod +x $INSTALL_DIR/bin/3proxy

### ===== DATA GEN =====
mkdir -p $WORKDIR
DATA="$WORKDIR/data.txt"
> "$DATA"

gen_pass() { tr </dev/urandom -dc A-Za-z0-9 | head -c10; }

for i in $(seq 1 $PROXY_COUNT); do
  PORT=$((START_PORT + i - 1))
  USER="user$i"
  PASS=$(gen_pass)
  IPV6="$PREFIX:$(printf '%x:%x:%x:%x' $RANDOM $RANDOM $RANDOM $i)"
  echo "$USER/$PASS/$PORT/$IPV6" >> "$DATA"
done

### ===== 3PROXY CONFIG =====
echo "[+] Generating config"

{
echo "daemon"
echo "maxconn 2000"
echo "nserver 1.1.1.1"
echo "nserver 8.8.8.8"
echo "nserver 2001:4860:4860::8888"
echo "timeouts 1 5 30 60 180 1800 15 60"
echo "auth strong"
echo -n "users "
awk -F/ '{printf "%s:CL:%s ",$1,$2}' "$DATA"
echo
echo "flush"

awk -F/ '{
print "allow " $1
print "proxy -6 -n -a -p" $3 " -i'"$IP4"' -e" $4
print "flush"
}' "$DATA"

echo "deny *"
} > "$CFG"

### ===== SYSTEMD =====
cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy IPv6 AWS
After=network.target

[Service]
ExecStart=$INSTALL_DIR/bin/3proxy $CFG
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

### ===== FIREWALL (OPEN PORT RANGE) =====
if systemctl is-active firewalld &>/dev/null; then
  firewall-cmd --permanent --add-port=${START_PORT}-${END_PORT}/tcp
  firewall-cmd --reload
fi

### ===== OUTPUT LIST =====
OUT="$WORKDIR/proxy.txt"
awk -F/ '{print "["$4"]:"$3":"$1":"$2}' "$DATA" > "$OUT"

echo
echo "================ DONE ================"
echo "Proxy list: $OUT"
echo "Example:"
head -n 3 "$OUT"
echo "======================================"

### ===== TEST FIRST PROXY =====
FIRST=$(head -n1 "$OUT")
IPV6=$(echo "$FIRST" | cut -d] -f1 | tr -d '[')
PORT=$(echo "$FIRST" | cut -d: -f2)
USER=$(echo "$FIRST" | cut -d: -f3)
PASS=$(echo "$FIRST" | cut -d: -f4)

echo "[+] Testing first proxy..."
curl -6 -x "http://$USER:$PASS@[$IPV6]:$PORT" https://api64.ipify.org || echo "Test failed"
