#!/bin/bash
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

HOSTNAME="gentoo-test-vm"
USERNAME="acidking"
PASSWORD="bep"
PASSWORD2="bop"
TIMEZONE="Europe/Helsinki"
KEYMAP="en-latin9"
LOCALE="en_US.UTF-8 UTF-8"
DISK="/dev/vda"
ROOT_PART="/dev/vda3"
EFI_PART="/dev/vda1"
SWAP_PART="/dev/vda2"
ROOT_SIZE="8GiB"
EFI_SIZE="100Mib"
SWAP_SIZE="2GiB"
MAX_JOBS="80"
STAGE3_BASE_URL="https://gentoo.lnin.xyz/releases/amd64/autobuilds"
PORTAGE_SYNC_URI="rsync://rsync.lnin.xyz/gentoo-portage"
DISTFILES_MIRROR="https://gentoo.lnin.xyz/"

# ============================================================================
# FUNCTIONS
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

test_mirror_endpoints() {
    curl -I "$DISTFILES_MIRROR"
    rsync --list-only "$PORTAGE_SYNC_URI" | head -5
    curl -I "${DISTFILES_MIRROR}releases/"
}

get_latest_stage3() {
    STAGE3_LIST=$(curl -s "$STAGE3_BASE_URL/current-stage3-amd64-openrc/")
    STAGE3_FILE=$(echo "$STAGE3_LIST" | grep -o 'stage3-amd64-openrc-[0-9T]*\.tar\.xz' | head -1)
    STAGE3_URL="$STAGE3_BASE_URL/current-stage3-amd64-openrc/$STAGE3_FILE"
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

test_mirror_endpoints
get_latest_stage3

parted --script $DISK \
    mklabel gpt \
    mkpart primary fat32 1MiB $EFI_SIZE \
    set 1 esp on \
    mkpart primary linux-swap $EFI_SIZE $SWAP_SIZE \
    mkpart primary ext4 $ROOT_SIZE 100%

mkfs.fat -F 32 $EFI_PART
mkfs.ext4 $ROOT_PART
mkswap $SWAP_PART

mount $ROOT_PART /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount $EFI_PART /mnt/gentoo/boot/efi
swapon $SWAP_PART

cd /mnt/gentoo
START_TIME=$(date +%s)
wget "$STAGE3_URL"
END_TIME=$(date +%s)
DOWNLOAD_TIME=$((END_TIME - START_TIME))
STAGE3_SIZE=$(ls -lh stage3-*.tar.xz | awk '{print $5}')
log "BENCHMARK: Stage3 ($STAGE3_SIZE) downloaded in ${DOWNLOAD_TIME}s"

tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

cat >> /mnt/gentoo/etc/portage/make.conf << EOF
MAKEOPTS="-j${MAX_JOBS}"
ACCEPT_LICENSE="*"
USE="X -wayland -gtk -gtk3 -gtk4 -gnome -kde -plasma -qt5 -qt6 -xfce -mate -lxde -lxqt -jack -bluetooth -cups -avahi -nfs -systemd -dvd -dvdr -cdr"
GENTOO_MIRRORS="$DISTFILES_MIRROR"
EOF

mkdir -p /mnt/gentoo/etc/portage/repos.conf
cat > /mnt/gentoo/etc/portage/repos.conf/gentoo.conf << EOF
[DEFAULT]
main-repo = gentoo

[gentoo]
priority = -1000
sync-type = rsync
sync-uri = $PORTAGE_SYNC_URI
auto-sync = yes
sync-rsync-verify-jobs = 1
sync-rsync-verify-max-age = 24
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
sync-openpgp-keyserver = hkps://keys.gentoo.org
sync-openpgp-key-refresh-retry-count = 40
sync-openpgp-key-refresh-retry-overall-timeout = 1200
sync-openpgp-key-refresh-retry-delay-exp-base = 2
sync-openpgp-key-refresh-retry-delay-max = 60
sync-openpgp-key-refresh-retry-delay-mult = 4
EOF

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

cat > /mnt/gentoo/config.conf << EOF
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
PASSWORD2="$PASSWORD2"
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
KEYMAP="$KEYMAP"
ROOT_PART="$ROOT_PART"
EFI_PART="$EFI_PART"
SWAP_PART="$SWAP_PART"
DISK="$DISK"
PORTAGE_SYNC_URI="$PORTAGE_SYNC_URI"
DISTFILES_MIRROR="$DISTFILES_MIRROR"
EOF

cat > /mnt/gentoo/base-install.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

source /etc/profile
source config.conf

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CHROOT: $*"
}

SYNC_START=$(date +%s)
emerge --sync
SYNC_END=$(date +%s)
SYNC_TIME=$((SYNC_END - SYNC_START))
log "BENCHMARK: Portage sync completed in ${SYNC_TIME}s"

eselect profile list
eselect profile set 21

EMERGE_START=$(date +%s)
emerge --ask=n dev-vcs/git
EMERGE_END=$(date +%s)
EMERGE_TIME=$((EMERGE_END - EMERGE_START))
log "BENCHMARK: Git installation took ${EMERGE_TIME}s"

WORLD_START=$(date +%s)
emerge --ask=n --update --deep --newuse @world
WORLD_END=$(date +%s)
WORLD_TIME=$((WORLD_END - WORLD_START))
log "BENCHMARK: World update completed in ${WORLD_TIME}s"

echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "$LOCALE" >> /etc/locale.gen
locale-gen
eselect locale list
eselect locale set 4
env-update && source /etc/profile

mkdir -p /etc/portage/package.use
echo "sys-kernel/installkernel dracut" >> /etc/portage/package.use/installkernel

KERNEL_START=$(date +%s)
emerge --ask=n sys-kernel/linux-firmware
emerge --ask=n sys-kernel/installkernel
emerge --ask=n sys-kernel/gentoo-kernel-bin
emerge --ask=n app-portage/cpuid2cpuflags
KERNEL_END=$(date +%s)
KERNEL_TIME=$((KERNEL_END - KERNEL_START))
log "BENCHMARK: Kernel installation took ${KERNEL_TIME}s"

echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

emerge --ask=n sys-fs/genfstab
genfstab -U / > /etc/fstab

echo "hostname=$HOSTNAME" > /etc/conf.d/hostname
cat > /etc/hosts << HOSTS_EOF
127.0.0.1 $HOSTNAME
127.0.0.1 localhost
::1       localhost
HOSTS_EOF

echo "keymap=\"$KEYMAP\"" > /etc/conf.d/keymaps

FINAL_START=$(date +%s)
emerge --ask=n dhcpcd sudo neofetch grub efibootmgr
FINAL_END=$(date +%s)
FINAL_TIME=$((FINAL_END - FINAL_START))
log "BENCHMARK: Final packages took ${FINAL_TIME}s"

rc-update add dhcpcd default

grub-install $DISK
grub-mkconfig -o /boot/grub/grub.cfg

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel,users,audio,video,usb -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD2" | chpasswd

# ============================================================================
# PERFORMANCE REPORT
# ============================================================================

log "Portage sync: ${SYNC_TIME}s"
log "Git install: ${EMERGE_TIME}s"
log "World update: ${WORLD_TIME}s"
log "Kernel install: ${KERNEL_TIME}s"
log "Final packages: ${FINAL_TIME}s"
TOTAL_TIME=$((SYNC_TIME + EMERGE_TIME + WORLD_TIME + KERNEL_TIME + FINAL_TIME))
log "Total time: ${TOTAL_TIME}s"
log "Mirror: gentoo.lnin.xyz"
CHROOT_EOF

chmod +x /mnt/gentoo/base-install.sh
chroot /mnt/gentoo ./base-install.sh

umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -R /mnt/gentoo/proc 2>/dev/null || true
umount -R /mnt/gentoo/sys 2>/dev/null || true
umount -R /mnt/gentoo/run 2>/dev/null || true
umount /mnt/gentoo/boot/efi
umount /mnt/gentoo
swapoff $SWAP_PART

log "gentoo.lnin.xyz mirror stress test complete"
