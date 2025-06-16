#!/bin/bash
# This script install Gentoo base system. Dont edit.
# Edit the config file instead at configs/install/base-base.conf

set -euo pipefail

# config check
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <config-file>"
    echo "Example: $0 base-base.conf"
    exit 1
fi


CONFIG_ABSPATH="$(realpath "$1")"
source "$CONFIG_ABSPATH"
CONFIG_NAME=$(basename "$1" .conf)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Starting installation for: $CONFIG_NAME"

log "Partitioning disk: $DISK"
parted --script $DISK \
    mklabel gpt \
    mkpart primary fat32 1MiB $EFI_SIZE \
    set 1 esp on \
    mkpart primary linux-swap $EFI_SIZE $SWAP_SIZE \
    mkpart primary ext4 $ROOT_SIZE 100%

log "Formatting partitions"
mkfs.fat -F 32 $EFI_PART
mkfs.ext4 $ROOT_PART
mkswap $SWAP_PART

log "Mounting filesystems"
mount $ROOT_PART /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount $EFI_PART /mnt/gentoo/boot/efi
swapon $SWAP_PART

log "Downloading stage3"
cd /mnt/gentoo
wget $STAGE3_URL
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

log "Configuring make.conf"
cat >> /mnt/gentoo/etc/portage/make.conf << EOF

MAKEOPTS="-j${MAX_JOBS}"

ACCEPT_LICENSE="*"
USE="X -wayland -gtk -gtk3 -gtk4 -gnome -kde -plasma -qt5 -qt6 -xfce -mate -lxde -lxqt -jack -bluetooth -cups -avahi -nfs -systemd -dvd -dvdr -cdr"
GENTOO_MIRRORS="http://192.168.0.103/ rsync://192.168.0.103/"
EOF


log "Preparing chroot environment"
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# Create chroot installation script
log "Creating chroot installation script"
cat > /mnt/gentoo/base-install.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

source config.conf
source /etc/profile

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Initial repository setup"
emerge --sync

log "Setting profile"
eselect profile list
eselect profile set 21

log "Installing git"
emerge --ask=n dev-vcs/git

log "Switching to local git mirror"
mkdir -p /etc/portage/repos.conf
rm -rf /var/db/repos/gentoo/*
rm -rf /var/db/repos/gentoo/.*  2>/dev/null || true 

cat > /etc/portage/repos.conf/gentoo.conf << 'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-depth = 1
sync-uri = http://192.168.0.103/portage/gentoo.git
sync-git-verify-commit-signature = false
auto-sync = yes
EOF

log "Syncing with local git mirror"
emerge --sync

log "Updating @world"
emerge --ask=n --update --deep --newuse @world

log "Configuring timezone and locale"
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "$LOCALE" >> /etc/locale.gen
locale-gen
eselect locale list
eselect locale set 4
env-update && source /etc/profile

mkdir -p /etc/portage/package.use
echo "sys-kernel/installkernel dracut" >> /etc/portage/package.use/installkernel

log "Installing kernel and firmware"
emerge --ask=n sys-kernel/linux-firmware
emerge --ask=n sys-kernel/installkernel
emerge --ask=n sys-kernel/gentoo-kernel-bin
emerge --ask=n app-portage/cpuid2cpuflags

echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

log "Generating fstab"
if [[ -f genfstab ]]; then
    ./genfstab -U /mnt/gentoo >> /etc/fstab
else
    cat >> /etc/fstab << FSTAB_EOF
$ROOT_PART / ext4 defaults,noatime 0 1
$EFI_PART /boot/efi vfat defaults 0 2
$SWAP_PART none swap sw 0 0
FSTAB_EOF
fi

log "Configuring hostname and network"
echo "hostname=$HOSTNAME" > /etc/conf.d/hostname
cat > /etc/hosts << HOSTS_EOF
127.0.0.1 $HOSTNAME
127.0.0.1 localhost
::1       localhost
HOSTS_EOF

echo "keymap=\"$KEYMAP\"" > /etc/conf.d/keymaps

log "Installing base packages"
emerge --ask=n dhcpcd sudo neofetch grub efibootmgr

log "Configuring services"
rc-update add dhcpcd default

log "Installing bootloader"
grub-install $DISK
grub-mkconfig -o /boot/grub/grub.cfg

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel,users,audio,video,usb -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD2" | chpasswd

log "Base installation complete"
CHROOT_EOF

cp "$CONFIG_ABSPATH" /mnt/gentoo/config.conf
if [[ -f genfstab ]]; then
    cp genfstab /mnt/gentoo/
    chmod +x /mnt/gentoo/genfstab
fi
chmod +x /mnt/gentoo/base-install.sh

log "Entering chroot and running installation"
chroot /mnt/gentoo ./base-install.sh

umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

log "Installation complete. You can now reboot"