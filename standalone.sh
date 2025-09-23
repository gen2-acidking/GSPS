#!/bin/bash

set -euo pipefail

# ============================================================================
# CONFIGURATION - EDIT THESE VALUES
# ============================================================================

# Base Gentoo configuration 
HOSTNAME="gentoo-base"
USERNAME="acidking"
PASSWORD="bep" # Root password
PASSWORD2="bop" # User password
TIMEZONE="Europe/Helsinki" # owo
KEYMAP="colemak" # Keyboard layout, colemak
LOCALE="en_US.UTF-8 UTF-8"
DISK="/dev/vda"
ROOT_PART="/dev/vda3" # Hello virtual machine user! 
EFI_PART="/dev/vda1"  # Are you scared of the dark?
SWAP_PART="/dev/vda2" # ------------------------- #
ROOT_SIZE="8GiB"
EFI_SIZE="100MiB" # smol
SWAP_SIZE="2GiB"
MAX_JOBS="80" # Number of parallel jobs for emerge, 
             # you're gonna need to ratchet this number down quite a bit :^)

STAGE3_BASE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds"

# ============================================================================
# MAIN SCRIPT - DON'T TOUCH UNLESS YOU KNOW WHAT YOU'RE DOING
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

get_latest_stage3_url() {
    log "Getting latest stage3 URL..."
    wget -q "$STAGE3_BASE_URL/latest-stage3-amd64-openrc.txt" -O /tmp/latest-stage3.txt
    local stage3_file=$(grep -v '^#' /tmp/latest-stage3.txt | head -n1 | cut -d' ' -f1)
    echo "$STAGE3_BASE_URL/$stage3_file"
    rm -f /tmp/latest-stage3.txt
}

STAGE3_URL=$(get_latest_stage3_url)

log "Starting installation with latest stage3: $(basename $STAGE3_URL)"

log "Partitioning disk: $DISK"
parted --script $DISK \
    mklabel gpt \
    mkpart primary fat32 1MiB $EFI_SIZE \
    set 1 esp on \
    mkpart primary linux-swap $EFI_SIZE "+$SWAP_SIZE" \
    mkpart primary ext4 "+$SWAP_SIZE" 100%

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
GENTOO_MIRRORS="https://distfiles.gentoo.org https://mirror.leaseweb.com/gentoo/ https://mirrors.rit.edu/gentoo/"
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

# Import config variables
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
PASSWORD="${PASSWORD}"
PASSWORD2="${PASSWORD2}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYMAP="${KEYMAP}"
ROOT_PART="${ROOT_PART}"
EFI_PART="${EFI_PART}"
SWAP_PART="${SWAP_PART}"

source /etc/profile

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Initial repository setup"
emerge --sync

log "Setting profile"
eselect profile list
eselect profile set default/linux/amd64/17.1/desktop

log "Installing essential tools"
emerge --ask=n dev-vcs/git

log "Updating @world"
emerge --ask=n --update --deep --newuse @world

log "Configuring timezone and locale"
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "$LOCALE" >> /etc/locale.gen
locale-gen
eselect locale list
eselect locale set $(eselect locale list | grep "en_US.utf8" | cut -d'[' -f2 | cut -d']' -f1 | head -n1)
env-update && source /etc/profile

mkdir -p /etc/portage/package.use
echo "sys-kernel/installkernel dracut" >> /etc/portage/package.use/installkernel

log "Installing kernel and firmware"
emerge --ask=n sys-kernel/linux-firmware
emerge --ask=n sys-kernel/installkernel
emerge --ask=n sys-kernel/gentoo-kernel-bin
emerge --ask=n app-portage/cpuid2cpuflags

echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

log "Installing genfstab"
emerge --ask=n sys-fs/genfstab

log "Generating fstab with official genfstab"
genfstab -U / > /etc/fstab

log "Configuring hostname and network"
echo "hostname=$HOSTNAME" > /etc/conf.d/hostname
cat > /etc/hosts << HOSTS_EOF
127.0.0.1 $HOSTNAME.localdomain $HOSTNAME localhost
::1       localhost
HOSTS_EOF

echo "keymap="$KEYMAP"" > /etc/conf.d/keymaps

log "Installing base packages"
emerge --ask=n net-misc/dhcpcd app-admin/sudo app-misc/neofetch sys-boot/grub

log "Configuring services"
rc-update add dhcpcd default

log "Installing bootloader"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo
grub-mkconfig -o /boot/grub/grub.cfg

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel,users,audio,video,usb -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD2" | chpasswd

log "Base installation complete"
CHROOT_EOF

chmod +x /mnt/gentoo/base-install.sh

log "Entering chroot and running installation"
chroot /mnt/gentoo ./base-install.sh

log "Cleaning up"
umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -R /mnt/gentoo/proc 2>/dev/null || true
umount -R /mnt/gentoo/sys 2>/dev/null || true
umount -R /mnt/gentoo/run 2>/dev/null || true
umount /mnt/gentoo/boot/efi
umount /mnt/gentoo
swapoff $SWAP_PART

log "Installation complete. You can now reboot"
