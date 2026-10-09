#!/bin/sh

# shellcheck disable=SC2024 # Root opens $logfile; sudo'd commands inherit the fd.

# Abs' Auto Rice Bootstrapping Script
#
# Copied and modified from:
# Luke's Auto Rice Boostrapping Script (LARBS)
# by Luke Smith <luke@lukesmith.xyz>
# License: GNU GPLv3

### OPTIONS AND VARIABLES ###

progsurl="https://raw.githubusercontent.com/askeko/aarbs/main/progs.csv"
progsfile="$(dirname "$0")/progs.csv"
[ -f "$0" ] || progsfile=""
dotfilesrepo="https://github.com/askeko/absrice.git"
aurhelper="yay"
logfile="/var/log/aarbs.log"

### FUNCTIONS ###

error() {
    # Clears any whiptail screen, logs to stderr and exits with failure.
    clear
    printf "%s\n" "$1" >&2
    exit 1
}

welcomemsg() {
    # Welcomes the user to this awesome automatic minimal Arch linux desktop install script.
    whiptail --title "Welcome!" \
        --msgbox "Welcome to Abs's Auto-Rice Bootstrapping Script!\\n\\nThis script will automatically install a minimal Linux desktop, which I use as my main machine.\\n\\n-Abs" 10 60
}

validname() {
    # Succeeds if $1 is a valid, non-root username of at most 32 characters.
    [ "$1" != "root" ] && [ "${#1}" -le 32 ] || return 1
    case "$1" in
        "" | [!a-z]* | *[!a-z0-9_-]*) return 1 ;;
    esac
}

getuserandpass() {
    # Prompts user for new username and password.
    name=$(whiptail --inputbox "First, please enter a name for the user account." 10 60 3>&1 1>&2 2>&3 3>&-) || exit 1
    while ! validname "$name"; do
        name=$(whiptail --nocancel --inputbox "Username not valid. Give a username beginning with a letter, with only lowercase letters, digits, - or _ (max 32 characters, not root)." 10 60 3>&1 1>&2 2>&3 3>&-)
    done
    pass1=$(whiptail --nocancel --passwordbox "Enter a password for that user." 10 60 3>&1 1>&2 2>&3 3>&-)
    pass2=$(whiptail --nocancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&-)
    while [ -z "$pass1" ] || [ "$pass1" != "$pass2" ]; do
        unset pass2
        pass1=$(whiptail --nocancel --passwordbox "Passwords are empty or do not match.\\n\\nEnter password again." 10 60 3>&1 1>&2 2>&3 3>&-)
        pass2=$(whiptail --nocancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&-)
    done
}

usercheck() {
    # Warns the user before installing for an existing user.
    ! { id -u "$name" >/dev/null 2>&1; } ||
        whiptail --title "WARNING" --yes-button "CONTINUE" \
            --no-button "No wait..." \
            --yesno "The user \`$name\` already exists on this system. AARBS can install for an existing user, but it will OVERWRITE any conflicting dotfiles with the ones from $dotfilesrepo.\\n\\nAARBS will NOT touch your documents, videos, etc. It will also add $name to the wheel group, set their shell to zsh and change their password to the one you just gave." 12 70
}

preinstallmsg() {
    # Prompts the user for acknowledgement of starting the script.
    whiptail --title "Let's get this party started!" --yes-button "Let's go!" \
        --no-button "No, nevermind!" \
        --yesno "The rest of the installation will now be totally automated, so you can sit back and relax.\\n\\nIt will take some time, but when done, you can relax even more with your complete system.\\n\\nNow just press <Let's go!> and the system will begin installation!" 13 60 || {
        clear
        exit 1
    }
}

adduserandpass() {
    # Creates user $name (or updates an existing one) and sets password $pass1.
    whiptail --infobox "Adding user \"$name\"..." 7 50
    if id -u "$name" >/dev/null 2>&1; then
        usermod -a -G wheel -s /bin/zsh "$name" >>"$logfile" 2>&1 || return 1
    else
        useradd -m -G wheel -s /bin/zsh "$name" >>"$logfile" 2>&1 || return 1
    fi
    repodir="/home/$name/.local/src"
    mkdir -p "$repodir"
    chown -R "$name": "/home/$name/.local"
    printf '%s:%s\n' "$name" "$pass1" | chpasswd || return 1
    unset pass1 pass2
}

upgradesystem() {
    # Refreshes Arch keyring and upgrades the system.
    whiptail --infobox "Refreshing Arch Keyring and upgrading the system..." 7 60
    pacman --noconfirm -Sy archlinux-keyring >>"$logfile" 2>&1 &&
        pacman --noconfirm -Su >>"$logfile" 2>&1
}

installgpudrivers() {
    # Installs 64- and 32-bit Vulkan drivers for the GPUs found, so packages
    # that need a vulkan-driver (Steam) don't get a provider picked for them.
    gpus=$(lspci -mm | grep -E '"(VGA compatible|3D|Display) controller"')
    pkgs=""
    case "$gpus" in *NVIDIA*) pkgs="$pkgs nvidia-open nvidia-utils lib32-nvidia-utils" ;; esac
    case "$gpus" in *"Advanced Micro Devices"*) pkgs="$pkgs vulkan-radeon lib32-vulkan-radeon" ;; esac
    case "$gpus" in *Intel*) pkgs="$pkgs vulkan-intel lib32-vulkan-intel" ;; esac
    # No known GPU (e.g. a VM): use the software renderer.
    [ -n "$pkgs" ] || pkgs="vulkan-swrast lib32-vulkan-swrast"
    whiptail --infobox "Installing GPU drivers:$pkgs" 8 70
    # shellcheck disable=SC2086 # The package list is meant to be split.
    pacman --noconfirm --needed -S $pkgs >>"$logfile" 2>&1
}

manualinstall() {
    # Builds and installs AUR package $1 without an AUR helper.
    # Needs $repodir and the temporary passwordless sudo rule.
    # Only used to install the AUR helper.
    pacman -Qq "$1" >/dev/null 2>&1 && return 0
    whiptail --infobox "Installing \"$1\" manually." 7 50
    dir="$repodir/$1"
    if [ -d "$dir/.git" ]; then
        sudo -u "$name" git -C "$dir" pull --ff-only -q
    else
        sudo -u "$name" git clone --depth 1 --single-branch --no-tags -q \
            "https://aur.archlinux.org/$1.git" "$dir"
    fi || return 1
    sudo -u "$name" -D "$dir" makepkg --noconfirm -si >>"$logfile" 2>&1
}

installationloop() {
    # Installs everything in progs.csv: repo packages in one pacman call and AUR
    # packages in one yay call. Stops and names any package that doesn't exist.
    progs=$(mktemp) || error "Failed to create temp file."
    if [ -f "$progsfile" ]; then
        cp "$progsfile" "$progs"
    else
        curl -fsSL "$progsurl" -o "$progs" ||
            error "Failed to download $progsurl."
    fi
    # Drop comments and blank lines.
    sed -i '/^#/d;/^[[:space:]]*$/d' "$progs"
    repopkgs="" aurpkgs="" nrepo=0 naur=0
    while IFS=, read -r tag program _; do
        case "$tag" in
            "A") aurpkgs="$aurpkgs $program" naur=$((naur + 1)) ;;
            *) repopkgs="$repopkgs $program" nrepo=$((nrepo + 1)) ;;
        esac
    done <"$progs"
    rm -f "$progs"

    # shellcheck disable=SC2086 # The package lists are meant to be split.
    {
        # Check every name first, so a renamed or removed package is reported
        # by name instead of failing the whole batch.
        whiptail --title "AARBS Installation" \
            --infobox "Checking $((nrepo + naur)) packages..." 8 70
        missing=""
        for p in $repopkgs; do
            pacman -Si "$p" >/dev/null 2>&1 || missing="$missing $p"
        done
        for p in $aurpkgs; do
            sudo -u "$name" $aurhelper -Si "$p" >/dev/null 2>&1 || missing="$missing $p"
        done
        [ -z "$missing" ] ||
            error "Packages not found:$missing. Remove or rename them in progs.csv, then re-run the script."

        whiptail --title "AARBS Installation" \
            --infobox "Installing $nrepo packages from the official repos..." 8 70
        pacman --noconfirm --needed -S $repopkgs >>"$logfile" 2>&1 ||
            error "Installing official packages failed. See $logfile for the cause."

        [ -n "$aurpkgs" ] || return 0
        whiptail --title "AARBS Installation" \
            --infobox "Installing $naur packages from the AUR..." 8 70
        sudo -u "$name" $aurhelper -S --needed --noconfirm $aurpkgs >>"$logfile" 2>&1 ||
            error "Installing AUR packages failed. See $logfile for the cause."
    }
}

installdotfiles() {
    # Clones and applies the user's dotfiles with chezmoi. A rerun starts from
    # a fresh clone; chezmoi retries any run_once_ script that failed.
    whiptail --infobox "Installing dotfiles with chezmoi..." 7 60
    src="/home/$name/.local/share/chezmoi"
    rm -rf -- "$src" 2>>"$logfile" || return 1
    sudo -H -u "$name" chezmoi init --source "$src" --apply --force "$dotfilesrepo" >>"$logfile" 2>&1
}

installsudoers() {
    # Validates sudoers rule $2 and installs it as /etc/sudoers.d/$1.
    tmp=$(mktemp) || return 1
    printf '%s\n' "$2" >"$tmp"
    visudo -cqf "$tmp" &&
        install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/$1"
    ret=$?
    rm -f "$tmp"
    return "$ret"
}

setupgreetd() {
    # Logs $name straight into Hyprland (through uwsm) at boot, since the disk
    # passphrase/YubiKey already guards it; after a logout, tuigreet on tty1
    # asks for the password and unlocks gnome-keyring with it. Takes effect
    # on reboot. stderr is redirected first so a failing redirect is logged too.
    cat 2>>"$logfile" >/etc/greetd/config.toml <<EOF || return 1
[terminal]
vt = 1

[initial_session]
command = "uwsm start hyprland-uwsm.desktop"
user = "$name"

[default_session]
command = "tuigreet --remember --cmd 'uwsm start hyprland-uwsm.desktop'"
user = "greeter"
EOF
    cat 2>>"$logfile" >/etc/pam.d/greetd <<'EOF' || return 1
#%PAM-1.0

auth       required     pam_securetty.so
auth       requisite    pam_nologin.so
auth       include      system-local-login
auth       optional     pam_gnome_keyring.so
account    include      system-local-login
session    include      system-local-login
session    optional     pam_gnome_keyring.so auto_start
EOF
    systemctl enable greetd.service >>"$logfile" 2>&1
}

setupyubikey() {
    # Every local login (TTYs, tuigreet and hyprlock, which all include
    # system-local-login) takes the password, then a touch on a YubiKey
    # (abslab's order): a wrong password fails without asking for a touch, and
    # a key unplugged at lock time can be plugged back in before typing.
    # nouserok lets the password alone log in until the keys are registered
    # with pamu2fcfg (see the guide). The touch prompt doesn't show in
    # hyprlock; the key blinks. Autologin at boot skips this; the disk unlock
    # guards it.
    grep -q pam_u2f /etc/pam.d/system-local-login ||
        sed -i '/^auth.*include.*system-login/a auth      required  pam_u2f.so cue nouserok' \
            /etc/pam.d/system-local-login 2>>"$logfile" || return 1
    grep -q pam_u2f /etc/pam.d/system-local-login || return 1
    # Pulling out a YubiKey locks every session (hypridle's lock_cmd runs
    # hyprlock). Matches only the usb_device node: each interface would fire
    # its own remove event and start several hyprlocks.
    cat 2>>"$logfile" >/etc/udev/rules.d/90-yubikey-lock.rules <<'EOF'
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="1050/*", RUN+="/usr/bin/loginctl lock-sessions"
EOF
}

setupservices() {
    # Enables system services for the installed programs and adds $name to
    # the groups that use them. Everything takes effect on reboot.
    # wireguard: let vpn-menu list profile names (the profiles themselves stay
    # 0600, see the guide).
    chmod 755 /etc/wireguard 2>>"$logfile" || return 1
    # docker: keep container networks out of common LAN ranges.
    mkdir -p /etc/docker 2>>"$logfile" || return 1
    cat 2>>"$logfile" >/etc/docker/daemon.json <<'EOF' || return 1
{
  "default-address-pools": [{ "base": "10.200.0.0/16", "size": 24 }]
}
EOF
    # bluetooth: show device battery, reconnect faster, power adapters on.
    sed -Ei 's/^#?(Experimental|FastConnectable) *=.*/\1 = true/;s/^#?AutoEnable *=.*/AutoEnable = true/' \
        /etc/bluetooth/main.conf 2>>"$logfile" || return 1
    # libvirt: start the default NAT network with the daemon (what
    # `virsh net-autostart default` does, without a running daemon).
    ln -sf ../default.xml /etc/libvirt/qemu/networks/autostart/default.xml 2>>"$logfile" || return 1
    # firewall: Arch's default ruleset, minus ssh and the forward chain (its
    # drop would beat docker's and libvirt's NAT rules), plus DHCPv6, DHCP/DNS
    # for local VMs and Steam. Docker's published ports bypass this input chain.
    cat 2>>"$logfile" >/etc/nftables.conf <<'EOF' || return 1
#!/usr/bin/nft -f
# Written by aarbs. Drops incoming connections except the ones below.

destroy table inet filter
table inet filter {
  chain input {
    type filter hook input priority filter
    policy drop

    ct state invalid drop comment "early drop of invalid connections"
    ct state {established, related} accept comment "allow tracked connections"
    iif lo accept comment "allow from loopback"
    meta l4proto { icmp, icmpv6 } accept comment "allow icmp"
    ip6 saddr fe80::/10 udp dport 546 accept comment "allow DHCPv6 replies"
    iifname "virbr*" meta l4proto { tcp, udp } th dport { 53, 67 } accept comment "allow DNS/DHCP for libvirt VMs"
    tcp dport { 27036, 27037 } accept comment "allow Steam Remote Play"
    udp dport { 10400, 10401, 27031-27036 } accept comment "allow Steam Remote Play"
    meta l4proto { tcp, udp } th dport 27015 accept comment "allow Steam dedicated server"
    pkttype host limit rate 5/second counter reject with icmpx type admin-prohibited
    counter
  }
}
EOF
    systemctl enable docker.socket libvirtd.service bluetooth.service nftables.service paccache.timer >>"$logfile" 2>&1 &&
        usermod -a -G docker,libvirt,wireshark "$name" >>"$logfile" 2>&1
}

setupnix() {
    # Nix next to pacman, for `nix shell nixpkgs#<program>` and project dev
    # shells (direnv `use flake`); /nix is its own btrfs subvolume (see the
    # guide), so snapshots don't hold old store paths. The daemon socket is
    # open to all users. A weekly timer removes store paths nothing uses any
    # more, as abslab did.
    grep -q '^experimental-features' /etc/nix/nix.conf ||
        printf 'experimental-features = nix-command flakes\nauto-optimise-store = true\n' \
            >>/etc/nix/nix.conf 2>>"$logfile" || return 1
    cat 2>>"$logfile" >/etc/systemd/system/nix-gc.service <<'EOF' || return 1
[Unit]
Description=Nix garbage collection

[Service]
Type=oneshot
ExecStart=/usr/bin/nix-collect-garbage --delete-older-than 7d
EOF
    cat 2>>"$logfile" >/etc/systemd/system/nix-gc.timer <<'EOF' || return 1
[Unit]
Description=Weekly Nix garbage collection

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl enable nix-gc.timer >>"$logfile" 2>&1 &&
        systemctl enable --now nix-daemon.socket >>"$logfile" 2>&1 || return 1
    # The package doesn't create /nix/store, and `nix shell` fails until it
    # exists; the daemon creates it on the first connection.
    nix store info --store daemon >>"$logfile" 2>&1
}

setupstorage() {
    # Sets up swap in compressed RAM (zram, no swap partition), snapper
    # snapshots of / before and after every pacman transaction (snap-pac)
    # and the Limine boot menu with those snapshots.
    # Needs the guide's btrfs layout, with @snapshots mounted at /.snapshots.
    cat 2>>"$logfile" >/etc/systemd/zram-generator.conf <<'EOF' || return 1
[zram0]
zram-size = min(ram / 2, 16384)
compression-algorithm = zstd
EOF
    # Swap tuning for zram, from the Arch wiki.
    cat 2>>"$logfile" >/etc/sysctl.d/99-vm-zram-parameters.conf <<'EOF' || return 1
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
    # create-config makes its own nested .snapshots subvolume; swap it for the
    # @snapshots mount, so restoring @ doesn't take the snapshots with it.
    if [ ! -f /etc/snapper/configs/root ]; then
        { ! mountpoint -q /.snapshots || umount /.snapshots; } &&
            rm -df /.snapshots &&
            snapper --no-dbus -c root create-config / &&
            btrfs subvolume delete /.snapshots &&
            mkdir /.snapshots
    fi >>"$logfile" 2>&1 || return 1
    { mountpoint -q /.snapshots || mount /.snapshots; } >>"$logfile" 2>&1 || return 1
    # Keep the last 10 pacman snapshots and no hourly ones; wheel can list them.
    chown :wheel /.snapshots 2>>"$logfile" && chmod 750 /.snapshots 2>>"$logfile" || return 1
    snapper --no-dbus -c root set-config TIMELINE_CREATE=no NUMBER_LIMIT=10 \
        NUMBER_LIMIT_IMPORTANT=5 ALLOW_GROUPS=wheel SYNC_ACL=yes >>"$logfile" 2>&1 || return 1
    # Limine: limine-entry-tool (limine-mkinitcpio-hook) manages the kernel
    # entries from now on, with an overlay hook so read-only snapshots boot,
    # and limine-snapper-sync puts the snapshots in the boot menu. The guide's
    # bootstrap entry goes only once the managed ones exist.
    printf 'HOOKS+=(sd-btrfs-overlayfs)\n' 2>>"$logfile" >/etc/mkinitcpio.conf.d/limine.conf || return 1
    printf 'ESP_PATH="/boot"\nENABLE_LIMINE_FALLBACK=yes\nFIND_BOOTLOADERS=no\n' 2>>"$logfile" >/etc/default/limine || return 1
    limine-update >>"$logfile" 2>&1 || return 1
    if grep -qx '/Arch Linux (install)' /boot/limine.conf; then
        limine-entry-tool --remove-entry "Arch Linux (install)" >>"$logfile" 2>&1 &&
            rm -f /boot/vmlinuz-linux /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img
    fi || return 1
    # Clean up old snapshots daily, check the filesystem monthly.
    systemctl enable snapper-cleanup.timer btrfs-scrub@-.timer limine-snapper-sync.service >>"$logfile" 2>&1
}

finalize() {
    # Tells the user how to do the next steps.
    whiptail --title "All done!" \
        --msgbox "Installation complete! All programs and dotfiles should be in place.\\n\\nReboot: after unlocking the disk, $name is logged into Hyprland automatically.\\n\\n-Abs" 11 80
}

### THE ACTUAL SCRIPT ###

### This is how everything happens in an intuitive format and order.

# Check that we're root, then install whiptail.
[ "$(id -u)" -eq 0 ] || error "This script must be run as root."
pacman --noconfirm --needed -S libnewt ||
    error "Failed to install whiptail (libnewt). Are you on Arch with an internet connection?"

# Welcome user.
welcomemsg || error "User exited."

# Get and verify username and password.
getuserandpass || error "User exited."

# Give warning if user already exists.
usercheck || error "User exited."

# Last chance for user to back out before install.
preinstallmsg || error "User exited."

### The rest of the script requires no user input.

# Make sure the clock is synced before downloading and verifying packages.
timedatectl set-ntp true >>"$logfile" 2>&1

# Make pacman colorful, concurrent downloads and Pacman eye-candy. Enable
# multilib for 32-bit libraries (Steam and its GPU drivers).
grep -q "ILoveCandy" /etc/pacman.conf || sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
sed -Ei "s/^#(ParallelDownloads).*/\1 = 10/;/^#Color$/s/#//" /etc/pacman.conf
sed -i '/^#\[multilib\]$/{s/^#//;n;s/^#//}' /etc/pacman.conf

# Refresh Arch keyring and update the system.
upgradesystem ||
    error "Error upgrading the system. Consider running pacman -Syu manually. See $logfile"

whiptail --title "AARBS Installation" \
    --infobox "Installing packages required to install and configure other programs..." 8 70
pacman --noconfirm --needed -S curl ca-certificates base-devel git zsh pciutils >>"$logfile" 2>&1 ||
    error "Failed to install base packages. See $logfile"

installgpudrivers || error "Failed to install GPU drivers. See $logfile"

adduserandpass || error "Error adding username and/or password."

# Allow user to run sudo without password. Since AUR programs must be installed
# in a fakeroot environment, this is required for all builds with AUR.
trap 'rm -f /etc/sudoers.d/aarbs-temp' EXIT
trap 'exit 1' HUP INT QUIT TERM PWR
installsudoers aarbs-temp "%wheel ALL=(ALL) NOPASSWD: ALL
Defaults:%wheel,root runcwd=*" ||
    error "Failed to install temporary sudoers rule."

# Use all cores for compilation, and don't build -debug packages.
mkdir -p /etc/makepkg.conf.d
printf 'MAKEFLAGS="-j%s"\nOPTIONS=("${OPTIONS[@]/#debug/!debug}")\n' "$(nproc)" >/etc/makepkg.conf.d/aarbs.conf

manualinstall yay-bin || error "Failed to install AUR helper. See $logfile"

# The command that does all the installing. Reads the progs.csv file and
# installs each needed program the way required. Be sure to run this only after
# the user has been created and has privileges to run sudo without a password
# and all build dependencies are installed.
installationloop

# Revoke passwordless sudo as it is no longer needed.
rm -f /etc/sudoers.d/aarbs-temp

installdotfiles || error "Failed to install dotfiles. See $logfile"

setupgreetd || error "Failed to set up the login manager. See $logfile"

setupyubikey || error "Failed to set up YubiKey login. See $logfile"

setupservices || error "Failed to enable services. See $logfile"

setupnix || error "Failed to set up Nix. See $logfile"

setupstorage || error "Failed to set up zram, snapshots and the boot menu. See $logfile"

# Most important command! Get rid of the beep!
rmmod pcspkr 2>/dev/null
echo "blacklist pcspkr" >/etc/modprobe.d/nobeep.conf

# Create zsh's cache directory for the user
sudo -u "$name" mkdir -p "/home/$name/.cache/zsh/"

# Allow wheel users to sudo with password, and to upgrade the system without one.
installsudoers 00-aarbs-wheel-can-sudo "%wheel ALL=(ALL:ALL) ALL" ||
    error "Failed to install sudoers rule for wheel."
installsudoers 01-aarbs-cmds-without-password \
    "%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman -Syu,/usr/bin/pacman -Syu --noconfirm" ||
    error "Failed to install passwordless sudoers rule."
installsudoers 02-aarbs-visudo-editor "Defaults editor=/usr/bin/nvim" ||
    error "Failed to install sudoers editor rule."
installsudoers 03-aarbs-wg-quick \
    '%wheel ALL=(root) NOPASSWD: /usr/bin/wg-quick ^(up|down) [a-zA-Z0-9_=+.-]{1,15}$' ||
    error "Failed to install sudoers rule for wg-quick."

# Last message! Install complete!
finalize
