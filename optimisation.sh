#!/usr/bin/env bash
#====================================================================
#  Optimisation globale d’un système Linux (Debian/Ubuntu/Fedora)
#  Auteur : opium-ctrl
#  Date   : 2025‑12‑24
#====================================================================

set -euo pipefail
IFS=$'\n\t'

#---------------------------#
#  Fonctions utilitaires    #
#---------------------------#
log() {
    echo -e "\e[32m[+] $*\e[0m"
}
err() {
    echo -e "\e[31m[!] $*\e[0m" >&2
    exit 1
}
backup() {
    local src=$1 dst=$2
    if [[ -e "$src" ]]; then
        cp -a "$src" "${dst}.bak_$(date +%Y%m%d%H%M%S)"
        log "Sauvegarde de $src → ${dst}.bak_…"
    fi
}

#---------------------------#
#  1. Désactivation services #
#---------------------------#
log "Désactivation des services inutiles"
services_to_disable=(
    bluetooth.service
    cups.service
    avahi-daemon.service
    ModemManager.service
    whoopsie.service
    snapd.service          # uniquement sur Ubuntu/Snap
)

for svc in "${services_to_disable[@]}"; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        systemctl disable "$svc"
        systemctl stop "$svc" || true
        log "Service $svc désactivé"
    fi
done

#---------------------------#
#  2. Optimisation du noyau #
#---------------------------#
log "Configuration des paramètres du noyau (sysctl)"
SYSCTL_CONF="/etc/sysctl.conf"
backup "$SYSCTL_CONF" "$SYSCTL_CONF"

cat <<'EOF' >> "$SYSCTL_CONF"

# ==== Optimisation générale ====
vm.swappiness = 10          # moins de recours au swap
vm.dirty_ratio = 5          # écriture du cache plus tôt
vm.dirty_background_ratio = 3
vm.overcommit_memory = 1   # autoriser l’allocation agressive
kernel.sched_migration_cost_ns = 5000000

# ==== Réseau ====
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_rmem = 4096 87380 6291456
net.ipv4.tcp_wmem = 4096 16384 4194304
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.ip_local_port_range = 1024 65535

# ==== Sécurité (optionnel) ====
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF

sysctl -p >/dev/null
log "Paramètres du noyau appliqués"

#---------------------------#
#  3. Optimisation du CPU   #
#---------------------------#
log "Mise en place du gouverneur de fréquence CPU en mode performance"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    if [[ -w "$cpu/cpufreq/scaling_governor" ]]; then
        echo performance > "$cpu/cpufreq/scaling_governor"
    fi
done

# Optionnel : activer le planificateur CFS « deadline » pour les disques SSD
log "Configuration du planificateur de disque"
for dev in /sys/block/sd*; do
    if [[ -w "$dev/queue/scheduler" ]]; then
        echo deadline > "$dev/queue/scheduler"
    fi
done

#---------------------------#
#  4. Système de fichiers   #
#---------------------------#
log "Montage des partitions avec options optimisées"
FSTAB="/etc/fstab"
backup "$FSTAB" "$FSTAB"

# Ajoute noatime et discard (pour SSD) si absent
sed -i '/\sdefaults\s/ s/defaults/defaults,noatime/' "$FSTAB"
if grep -q 'ext4' "$FSTAB"; then
    sed -i '/\sext4\s/ s/noatime/noatime,discard/' "$FSTAB"
fi

mount -a
log "fstab mis à jour et partitions remountées"

#---------------------------#
#  5. Swap & zram          #
#---------------------------#
log "Création d’un dispositif zram compressé"
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm
# 4 GiB de zram – adaptez selon votre RAM
echo $((4 * 1024 * 1024 * 1024)) > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0
log "zram activé (4 GiB, compression lz4)"

# Désactiver le swap traditionnel (si présent)
if swapon --show | grep -q '^/dev'; then
    swapdev=$(swapon --show --noheadings | awk '{print $1}')
    swapoff "$swapdev"
    log "Swap traditionnel $swapdev désactivé"
fi

#---------------------------#
#  6. Nettoyage & caches   #
#---------------------------#
log "Nettoyage des caches inutiles"
sync; echo 3 > /proc/sys/vm/drop_caches

#---------------------------#
#  7. Outils de monitoring #
#---------------------------#
log "Installation d’outils de surveillance (htop, iotop, nmon, bpftrace)"
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y htop iotop nmon bpftrace
elif command -v dnf &>/dev/null; then
    dnf install -y htop iotop nmon bpftrace
elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm htop iotop nmon bpftrace
fi
log "Outils installés"

#---------------------------#
#  8. Fin du script         #
#---------------------------#
log "Optimisation terminée. Redémarrez le système pour que tous les changements prennent effet."
