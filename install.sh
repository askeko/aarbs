#!/bin/sh
# Installs the base system from the Arch ISO: everything in installation.md
# under "Btrfs and Base System". Run it after partitioning, LUKS
# (opened as /dev/mapper/root) and mkfs.
#
#   sh install.sh <root-partition> <efi-partition> <hostname>
#
# Safe to run again after a failure.
set -eu

die() {
    printf 'install.sh: %s\n' "$1" >&2
    exit 1
}

[ $# -eq 3 ] || die "usage: sh install.sh <root-partition> <efi-partition> <hostname>"
rootpart=$1 esp=$2 host=$3

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode"
case "$host" in
    "" | [!a-z]* | *[!a-z0-9-]*) die "invalid hostname: $host" ;;
esac
[ -b "$rootpart" ] || die "$rootpart is not a block device"
[ -b "$esp" ] || die "$esp is not a block device"
[ "$(blkid -s TYPE -o value "$rootpart")" = crypto_LUKS ] || die "$rootpart is not a LUKS partition"
[ "$(blkid -s TYPE -o value "$esp")" = vfat ] || die "$esp is not formatted as FAT32"
[ "$(blkid -s TYPE -o value /dev/mapper/root)" = btrfs ] ||
    die "/dev/mapper/root is not a btrfs filesystem (open the LUKS partition as root, then mkfs.btrfs -L arch /dev/mapper/root)"

### Subvolumes and mounts ###

# A rerun starts from unmounted disks.
umount -R /mnt 2>/dev/null || true

mount -o subvolid=5 /dev/mapper/root /mnt
for sv in @ @home @snapshots @log @pkg @docker @libvirt @nix; do
    [ -d "/mnt/$sv" ] || btrfs subvolume create "/mnt/$sv"
done
umount /mnt

mount -o noatime,compress=zstd,subvol=@ /dev/mapper/root /mnt
mountsv() { # <subvolume> <mount point> <options>
    mount --mkdir -o "$3,subvol=$1" /dev/mapper/root "/mnt$2"
}
zstd=noatime,compress=zstd
mountsv @home /home $zstd
mountsv @snapshots /.snapshots $zstd
mountsv @log /var/log $zstd
mountsv @pkg /var/cache/pacman/pkg $zstd
mountsv @docker /var/lib/docker $zstd
mountsv @libvirt /var/lib/libvirt/images noatime
mountsv @nix /nix $zstd
chattr +C /mnt/var/lib/libvirt/images # no copy-on-write for VM images
mount --mkdir "$esp" /mnt/boot

### Base system ###

# The ISO's default ranking can put a slow mirror from another continent first.
reflector --country Denmark,Germany,Sweden --protocol https --latest 10 --sort rate \
    --save /etc/pacman.d/mirrorlist || echo "install.sh: reflector failed, using the ISO's mirrors" >&2

# No microcode in a VM.
ucode=""
if ! systemd-detect-virt -q; then
    case $(awk '/^vendor_id/ {print $3; exit}' /proc/cpuinfo) in
        AuthenticAMD) ucode="amd-ucode" ;;
        GenuineIntel) ucode="intel-ucode" ;;
    esac
fi

# libfido2 (YubiKey unlock) and plymouth (boot splash) go into the initramfs.
# shellcheck disable=SC2086 # $ucode is empty or one package name.
pacstrap -K /mnt base linux linux-firmware $ucode btrfs-progs libfido2 plymouth limine \
    efibootmgr networkmanager neovim

genfstab -U /mnt >/mnt/etc/fstab
sed -i 's/,subvolid=[0-9]*//' /mnt/etc/fstab                                                         # mount by name, so a restored @ is used
sed -i '/[[:space:]]\/boot[[:space:]]/s/fmask=0022,dmask=0022/fmask=0077,dmask=0077/' /mnt/etc/fstab # ESP readable by root only (random seed)

### Configuration ###

ln -sf /usr/share/zoneinfo/Europe/Copenhagen /mnt/etc/localtime
arch-chroot /mnt hwclock --systohc ||
    echo "install.sh: hwclock failed, set the hardware clock after the first boot" >&2

sed -Ei 's/^#(en_(DK|US)\.UTF-8 UTF-8)/\1/' /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo LANG=en_DK.UTF-8 >/mnt/etc/locale.conf
echo KEYMAP=dk >/mnt/etc/vconsole.conf # also the layout for the disk passphrase

echo "$host" >/mnt/etc/hostname
arch-chroot /mnt systemctl enable systemd-timesyncd.service NetworkManager.service

# The initramfs unlocks the disk (sd-encrypt) behind a Plymouth splash.
# keyboard comes before autodetect, so any keyboard works for the passphrase.
mkdir -p /mnt/etc/mkinitcpio.conf.d
echo 'HOOKS=(base systemd plymouth keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck)' \
    >/mnt/etc/mkinitcpio.conf.d/arch.conf

# zswap is off, since it gets in the way of zram.
mkdir -p /mnt/etc/kernel
echo "rd.luks.name=$(blkid -s UUID -o value "$rootpart")=root root=/dev/mapper/root rootflags=subvol=@ rw quiet splash zswap.enabled=0" \
    >/mnt/etc/kernel/cmdline
arch-chroot /mnt mkinitcpio -P

### Bootloader ###

# aarbs later hands the entries over to limine-entry-tool (kernel updates) and
# limine-snapper-sync (snapshots in the boot menu), and removes this one.
mkdir -p /mnt/boot/EFI/limine
cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/limine/limine_x64.efi
cat >/mnt/boot/limine.conf <<CONF
timeout: 3

/Arch Linux (install)
    protocol: linux
    path: boot():/vmlinuz-linux
    module_path: boot():/initramfs-linux.img
    cmdline: $(cat /mnt/etc/kernel/cmdline)
CONF

# Replace any earlier Limine entry, which may point at another disk.
efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} Limine$/\1/p' |
    while read -r entry; do efibootmgr -q -b "$entry" -B; done
espname=$(basename "$(readlink -f "$esp")")
efibootmgr --create --disk "/dev/$(lsblk -no PKNAME "$esp")" --part "$(cat "/sys/class/block/$espname/partition")" \
    --label "Limine" --loader '\EFI\limine\limine_x64.efi' --unicode

echo "Set the root password:"
arch-chroot /mnt passwd

echo "Done. Now: umount -R /mnt && reboot"
