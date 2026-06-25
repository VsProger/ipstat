#!/usr/bin/env bash
# =============================================================================
# set-static-ip.sh — поставить статический IP на студенческой машине.
#
# IP вычисляется из hostname (TS-A01, TS-B18, ...) по правилу:
#   октет = индекс_буквы*20 + номер   (A=1 → A01..A17 = .21..37, B = .41..58, ...)
#   A → .21-.37 | B → .41-.58 | C → .61-.65 | D → .81-.85 | E → .101-.105
# Шаг 20 на букву вмещает до 19 машин в группе без коллизий (B-блок = 18 машин).
#
# Запуск (от root):
#   sudo bash set-static-ip.sh             # IP из hostname
#   sudo bash set-static-ip.sh 192.168.33.50   # явный IP (если hostname нестандартный)
#
# Скрипт сам определяет, активен ли overlayroot:
#   - если активен → пишет профиль и в живую систему, и в persistent (overlayroot-chroot)
#   - если нет → просто пишет в /etc (это и есть persistent)
# В обоих случаях изменения переживают перезагрузку.
# =============================================================================
set -euo pipefail

# ─── ПАРАМЕТРЫ СЕТИ КАМПУСА ──────────────────────────────────────────────────
PREFIX="192.168.33"        # первые три октета (для вычисления IP из hostname)
GATEWAY="192.168.10.6"     # шлюз (ip route | grep default)
MASK="16"                  # prefix маски: сеть 192.168.0.0/16 = 255.255.0.0
DNS="1.1.1.1;8.8.8.8;"     # DNS (1.1.1.1 согласован с web_filter dns_upstream)
CONN="lan-static"          # имя профиля NetworkManager
CONN_FILE="/etc/NetworkManager/system-connections/${CONN}.nmconnection"

# ─── root ────────────────────────────────────────────────────────────────────
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "ERROR: запусти через sudo"; exit 1; }

# ─── вычислить IP ─────────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
  ipaddr="$1"
  [[ "$ipaddr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "ERROR: '$ipaddr' не похож на IP"; exit 1; }
else
  host_up="$(hostname -s | tr 'a-z' 'A-Z')"
  if [[ "$host_up" =~ ^TS-([A-Z])([0-9]+)$ ]]; then
    letter="${BASH_REMATCH[1]}"
    num=$((10#${BASH_REMATCH[2]}))                  # 10# — чтобы 08/09 не читались как octal
    idx=$(( $(printf '%d' "'$letter") - 64 ))       # A→1, B→2, ...
    octet=$(( idx*20 + num ))
    (( octet >= 2 && octet <= 254 )) || { echo "ERROR: октет $octet вне 2..254 ($host_up)"; exit 1; }
    ipaddr="${PREFIX}.${octet}"
  else
    echo "ERROR: hostname '$host_up' не подходит под TS-<буква><номер>."
    echo "       Задай IP явно:  sudo bash set-static-ip.sh ${PREFIX}.XX"
    exit 1
  fi
fi

# ─── содержимое профиля ──────────────────────────────────────────────────────
CONTENT="[connection]
id=${CONN}
type=ethernet
autoconnect=true
autoconnect-priority=999

[ipv4]
method=manual
address1=${ipaddr}/${MASK},${GATEWAY}
dns=${DNS}
ignore-auto-dns=true
may-fail=false

[ipv6]
method=ignore"

# ─── записать (live + persistent при overlayroot) ────────────────────────────
write_file() {  # $1 = "live" | "persist"
  if [[ "$1" == "persist" ]]; then
    printf '%s\n' "$CONTENT" | overlayroot-chroot sh -c "cat > '$CONN_FILE' && chmod 600 '$CONN_FILE'"
  else
    printf '%s\n' "$CONTENT" > "$CONN_FILE"
    chmod 600 "$CONN_FILE"
  fi
}

write_file live

if findmnt -no FSTYPE / 2>/dev/null | grep -q overlay && command -v overlayroot-chroot >/dev/null; then
  echo "overlayroot активен → пишу также в persistent (overlayroot-chroot)"
  write_file persist
else
  echo "overlayroot не активен → запись в /etc уже persistent"
fi

# ─── применить вживую ────────────────────────────────────────────────────────
ethdev="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="ethernet"{print $1; exit}')"
nmcli connection reload || true
if [[ -n "${ethdev:-}" ]]; then
  nmcli connection up "$CONN" ifname "$ethdev" || nmcli connection up "$CONN" || true
else
  nmcli connection up "$CONN" || true
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo " Статический IP установлен: ${ipaddr}/${MASK}  gw ${GATEWAY}"
echo " Профиль: ${CONN_FILE}"
echo " Проверь:  ip -4 addr show scope global | grep inet"
echo "════════════════════════════════════════════════════════"
