#!/bin/bash

set -e

# --- USER DETECTION AND VALIDATION ---
# Determine the target user.
# 1. Check if running as root with SUDO (in which case, SUDO_USER is the target).
# 2. If not running via SUDO, assume the current user is the target user.
# 3. If running as root without SUDO (rare), prompt for the username.

if [[ $EUID -ne 0 ]]; then
  # Not running as root, current user is the target.
  TARGET_USER="$USER"
  echo "[*] Target user detected: $TARGET_USER (current user)"
elif [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
  # Running via sudo, use the original user.
  TARGET_USER="$SUDO_USER"
  echo "[*] Target user detected: $TARGET_USER (via SUDO_USER)"
else
  # Running as root without SUDO_USER set, prompt the user.
  read -rp "[?] Please enter the name of the user to configure (e.g., your login name): " TARGET_USER
  if [[ -z "$TARGET_USER" ]]; then
    echo "[!] No username provided. Exiting."
    exit 1
  fi
fi

# Set HOME directory for the target user
HOME_DIR="/home/$TARGET_USER"

# Check if the home directory exists
if [[ ! -d "$HOME_DIR" ]]; then
  echo "[!] Home directory $HOME_DIR does not exist. Please create the user first. Exiting."
  exit 1
fi
# -------------------------------------

retry_cmd() {
  local attempts=5
  local delay=3
  local n=1

  while true; do
    "$@" && break || {
      if [[ $n -lt $attempts ]]; then
        echo "[!] Command failed. Retry $n/$attempts..."
        sleep $delay
        ((n++))
      else
        echo "[!] Command failed after $attempts attempts. Exiting."
        exit 1
      fi
    }
  done # <--- Change the problematic '}' to 'done' to close the 'while true; do' loop
}

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"

# --- CONFIGURATION COPY BLOCK ---
echo "[*] Copying dotfiles from configs/ to $HOME_DIR/.config ..."
mkdir -p "$HOME_DIR/.config"

shopt -s dotglob
# We copy everything inside configs/ to ~/.config/
cp -r "$SCRIPT_DIR/configs/"* "$HOME_DIR/.config/"
shopt -u dotglob

# Ensure ownership is correct for the copied files
chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config"
# --------------------------------

echo "[*] Enabling autologin for $TARGET_USER ..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $TARGET_USER --noclear %I 38400 linux
EOF

echo "[*] Adding NOPASSWD to sudoers (insecure!) ..."
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >>/etc/sudoers

# --- SYSTEM CONFIGS BLOCK ---
echo "[*] Replacing mirrorlist and pacman.conf from sysconfigs/ ..."
cp "$SCRIPT_DIR/sysconfigs/mirrorlist" /etc/pacman.d/mirrorlist
cp "$SCRIPT_DIR/sysconfigs/pacman.conf" /etc/pacman.conf
# ----------------------------

echo "[*] Updating system ..."
pacman -Syyu --noconfirm

echo "[*] Replacing mkinitcpio.conf and rebuilding initramfs ..."
# --- MKINITCPIO BLOCK ---
cp "$SCRIPT_DIR/sysconfigs/mkinitcpio.conf" /etc/mkinitcpio.conf
# ------------------------
mkinitcpio -P

echo "[*] Installing base packages ..."
retry_cmd pacman -S --noconfirm --needed \
  sway autotiling-rs polkit-kde-agent-1 xdg-desktop-portal-wlr wl-clipboard mpv \
  bluetui nvim foot swaybg wl-clip-persist fuzzel cliphist fastfetch \
  deluge-gtk btop zip unzip zsh ttf-jetbrains-mono ttf-jetbrains-mono-nerd \
  noto-fonts noto-fonts-emoji noto-fonts-cjk curl wget base-devel yazi wiremix

echo "[*] Installing paru (AUR helper) ..."
cd "$HOME_DIR"
git clone https://aur.archlinux.org/paru.git
chown -R "$TARGET_USER:$TARGET_USER" paru
cd paru
sudo -u "$TARGET_USER" makepkg -si --noconfirm
cd ..
rm -rf paru

echo "[*] Running fc-cache ..."
fc-cache -fv

echo "[*] Installing AUR packages with paru ..."
retry_cmd sudo -u "$TARGET_USER" paru --mflags --skippgpcheck -S --noconfirm \
  helium-browser-bin localsend-bin bibata-cursor-theme-bin curd lobster-git spotify

echo "[*] Setting up Spotify ..."
retry_cmd sudo -u "$TARGET_USER" bash <(curl -sSL https://spotx-official.github.io/run.sh)

echo "[*] Changing default shell to zsh ..."
chsh -s /bin/zsh "$TARGET_USER"

echo "[*] Installing Prezto framework ..."
sudo -u "$TARGET_USER" zsh -c '
set -e
git clone --recursive https://github.com/sorin-ionescu/prezto.git "${ZDOTDIR:-$HOME}/.zprezto"
for rcfile in "${ZDOTDIR:-$HOME}"/.zprezto/runcoms/z*; do
    ln -sf "$rcfile" "${ZDOTDIR:-$HOME}/.${rcfile:t}"
done
'

# --- START: NEW/MODIFIED BLOCK FOR PREZTO CONFIG ---
echo "[*] Copying custom Prezto runcoms from z/ to $HOME_DIR/.zprezto/runcoms/ ..."
# The cp -f (force) ensures they overwrite existing files
cp -f "$SCRIPT_DIR/z/"* "$HOME_DIR/.zprezto/runcoms/"
chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.zprezto/runcoms/"
# --- END: NEW/MODIFIED BLOCK FOR PREZTO CONFIG ---

# --- START: CORRECTED CACHE CLEANING BLOCK ---
echo "[*] Clearing Pacman and Paru package caches (will answer 'Yes' to all prompts) ..."

# 1. Clear Pacman cache: 'yes | pacman -Scc' pipes 'y' to both prompts,
# ensuring the second, space-clearing prompt is answered 'Yes'.
echo "[*] Clearing Pacman cache..."
yes | pacman -Scc

# 2. Clear Paru cache (must be run as the target user):
# 'yes | paru -Scc' ensures 'Yes' is provided to both prompts.
echo "[*] Clearing Paru cache..."
sudo -u "$TARGET_USER" bash -c 'yes | paru -Scc'
# --- END: CORRECTED CACHE CLEANING BLOCK ---

echo "[*] Cleaning up: deleting script folder ..."
cd /
rm -rf "$SCRIPT_DIR"

echo "[*] Done!"

read -rp "[?] System configuration is complete. Would you like to reboot now? (Y/n): " REBOOT_CHOICE
if [[ -z "$REBOOT_CHOICE" || "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
  echo "[*] Rebooting system..."
  reboot
else
  echo "[*] Not rebooting. Please reboot manually for changes to take full effect."
fi
