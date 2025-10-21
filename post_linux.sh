#!/usr/bin/env bash
# Unified OS post-install + NVIDIA checker/installer
# v0.6 — Adds consistent "installing... / installed" messaging across ALL OSes/sections

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" 1>&2; }

trap 'err "Command failed at line $LINENO: $BASH_COMMAND"' ERR

require_root() {
  if [[ $EUID -ne 0 ]]; then
    warn "This script needs root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

# Identify the non-root invoking user (for building AUR packages, etc.)
get_invoking_user() {
  if [[ -n "${SUDO_USER:-}" && "$EUID" -eq 0 ]]; then
    echo "$SUDO_USER"
  else
    # Fallback to current user if not running via sudo (not typical here)
    echo "$USER"
  fi
}

run_as_user() { # usage: run_as_user <username> "cmd..."
  local u="$1"; shift
  sudo -u "$u" bash -lc "$*"
}

# ---------- Generic helper to wrap any install-like command with messages ----------
install_step() { # usage: install_step "<human-label>" <cmd> [args...]
  local label="$1"; shift
  log "Installing ${label}..."
  "$@"
  ok "${label} installed."
}

OS_SEL=""
GPU_SEL=""

choose_os() {
  echo "Choose your OS:";
  echo "  1) Ubuntu";
  echo "  2) Fedora";
  echo "  3) Arch";
  read -rp "Enter number [1-3]: " ans
  case "$ans" in
    1) OS_SEL="ubuntu" ;;
    2) OS_SEL="fedora" ;;
    3) OS_SEL="arch" ;;
    *) err "Invalid selection"; exit 1 ;;
  esac
  ok "OS selected: $OS_SEL"
}

choose_gpu() {
  echo "Select NVIDIA GPU generation:";
  echo "  1) RTX 4000/5000 series (Ada/Lovelace-next)";
  echo "  2) RTX 3000 series or older (Ampere/Turing/older)";
  read -rp "Enter number [1-2]: " ans
  case "$ans" in
    1) GPU_SEL="ada_4000_plus" ;;
    2) GPU_SEL="ampere_3000_or_older" ;;
    *) err "Invalid selection"; exit 1 ;;
  esac
  ok "GPU selected: $GPU_SEL"
}

# ========================= FEDORA =========================
fedora_detect() {
  if [[ -f /etc/os-release ]]; then
    if grep -qiE '^ID=fedora' /etc/os-release || grep -qiE '^ID_LIKE=.*fedora' /etc/os-release || grep -qi 'Fedora' /etc/os-release; then
      return 0
    fi
  fi
  return 1
}

fedora_update_base() {
  log "Refreshing dnf metadata..."; dnf -y makecache; ok "dnf metadata updated";
}

fedora_nvidia_installed() {
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then return 0; fi; return 1;
}

fedora_show_nvidia_info() {
  command -v nvidia-smi &>/dev/null && nvidia-smi || true
  if lsmod | grep -qE '^nvidia'; then ok "Kernel modules loaded: $(lsmod | awk '/^nvidia/ {print $1}' | paste -sd, -)"; else warn "nvidia kernel modules are not currently loaded"; fi
}

fedora_enable_rpmfusion() {
  local ver; ver=$(. /etc/os-release; echo "$VERSION_ID")
  if ! rpm -q rpmfusion-free-release &>/dev/null; then
    install_step "RPM Fusion (free)" dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${ver}.noarch.rpm"
  else ok "RPM Fusion (free) already enabled"; fi
  if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
    install_step "RPM Fusion (nonfree)" dnf -y install "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${ver}.noarch.rpm"
  else ok "RPM Fusion (nonfree) already enabled"; fi
}

fedora_install_nvidia() {
  if [[ -x /usr/bin/mokutil ]] && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Secure Boot is ENABLED. NVIDIA modules may not load unless you enroll a MOK or disable Secure Boot."
  fi
  if fedora_nvidia_installed; then ok "NVIDIA driver already present."; fedora_show_nvidia_info; return; fi
  install_step "kernel headers & dev tools" dnf install -y kernel-devel kernel-headers gcc make dkms acpid libglvnd-glx libglvnd-opengl libglvnd-devel pkgconfig
  if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
    log "Applying open kernel module macro for RTX 4000+ GPUs..."; sh -c 'echo "%_with_kmod_nvidia_open 1" > /etc/rpm/macros.nvidia-kmod'; ok "Open kernel module macro applied."; fi
  install_step "NVIDIA driver (akmod + CUDA userspace)" dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
  warn "Building NVIDIA kernel module... this can take 5–15 minutes. You can monitor with: journalctl -f -u akmods"
  sleep 2; fedora_show_nvidia_info
}

fedora_post_install() {
  log "Running Fedora post-install commands..."
  install_step "RPM Fusion (free)" dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
  install_step "RPM Fusion (nonfree)" dnf install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
  log "Upgrading core group..."; dnf group upgrade core -y; ok "Core group upgraded."
  log "Checking updates..."; dnf check-update || true; ok "Check complete."
  log "Applying updates..."; dnf update -y; ok "System updated."
  if [[ $(dnf history info | grep -c kernel) -gt 0 ]]; then read -rp "Kernel update detected. Reboot now? (y/n): " r; [[ "$r" =~ ^[Yy]$ ]] && reboot || warn "Please reboot manually later."; fi
  ok "Fedora post-install completed."
}

fedora_flatpak_setup() {
  install_step "Remove Fedora Flatpak remote" bash -lc 'flatpak remote-delete fedora || true'
  install_step "Add Flathub Flatpak remote" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
}

fedora_media_setup() {
  install_step "ffmpeg swap (free→full)" dnf swap -y ffmpeg-free ffmpeg --allowerasing
  install_step "GStreamer plugins" dnf install -y gstreamer1-plugins-{bad-*,good-*,base} gstreamer1-plugin-openh264 gstreamer1-libav lame* --exclude=gstreamer1-plugins-bad-free-devel
  install_step "Multimedia group" dnf group install -y multimedia
  install_step "Sound & video group" dnf group install -y sound-and-video
  install_step "Video players (Celluloid + MPV)" dnf install -y celluloid mpv
}

fedora_hwaccel_setup() {
  install_step "VA-API libs" dnf install -y ffmpeg-libs libva libva-utils
  install_step "NVIDIA VAAPI driver" dnf install -y nvidia-vaapi-driver
}

fedora_archive_support() {
  install_step "Archive tools (7zip + unrar)" dnf install -y p7zip p7zip-plugins unrar
}

run_fedora() {
  if ! fedora_detect; then
    err "OS mismatch: You selected Fedora, but this system does not appear to be Fedora. Aborting."; exit 1
  fi
  log "Starting Fedora flow..."
  fedora_update_base
  fedora_enable_rpmfusion
  fedora_install_nvidia
  fedora_post_install
  fedora_flatpak_setup
  fedora_media_setup
  fedora_hwaccel_setup
  fedora_archive_support
}

# ========================= ARCH =========================
arch_detect() {
  if [[ -f /etc/os-release ]]; then
    if grep -qiE '^ID=arch' /etc/os-release || grep -qiE '^ID_LIKE=.*arch' /etc/os-release || grep -qi 'Arch Linux' /etc/os-release; then
      return 0
    fi
  fi
  return 1
}

arch_update_base() {
  log "(Awaiting your ARCH_UPDATE commands — currently empty)"; ok "Arch base update section finished.";
}

arch_nvidia_installed() { if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then return 0; fi; return 1; }

arch_show_nvidia_info() { command -v nvidia-smi &>/dev/null && nvidia-smi || true; if lsmod | grep -qE '^nvidia'; then ok "Kernel modules loaded: $(lsmod | awk '/^nvidia/ {print $1}' | paste -sd, -)"; else warn "nvidia kernel modules are not currently loaded"; fi }

arch_install_nvidia() {
  if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
    install_step "NVIDIA (open) + utils + lib32" pacman -S --noconfirm --needed nvidia-open nvidia-utils lib32-nvidia-utils
  else
    install_step "NVIDIA (proprietary) + utils + lib32" pacman -S --noconfirm --needed nvidia nvidia-utils lib32-nvidia-utils
  fi
  arch_show_nvidia_info
}

arch_post_install() {
  install_step "System update" pacman -Syu --noconfirm
  install_step "base-devel + git" pacman -S --needed --noconfirm base-devel git

  # Build yay as the invoking (non-root) user to avoid makepkg safety error
  local invu; invu=$(get_invoking_user)
  if [[ -z "$invu" || "$invu" == "root" ]]; then
    err "Cannot determine a non-root user to build yay. Please run this script with sudo from your regular user."; exit 1
  fi

  log "Cloning yay (as $invu)..."
  run_as_user "$invu" "cd ~; [[ -d yay ]] || git clone https://aur.archlinux.org/yay.git"
  ok "yay repository ready."

  log "Building yay package (as $invu)..."
  run_as_user "$invu" "cd ~/yay && makepkg -sf --noconfirm"
  ok "yay package built."

  # Install the built package as root
  local pkg
  pkg=$(ls -t /home/"$invu"/yay/*.pkg.tar.* 2>/dev/null | head -n1 || true)
  if [[ -n "$pkg" ]]; then
    install_step "Install yay package" pacman -U --noconfirm "$pkg"
  else
    err "Failed to locate built yay package for installation."; exit 1
  fi
}

arch_flatpak_setup() { install_step "Flatpak" pacman -S --noconfirm --needed flatpak; }

arch_media_setup() {
  install_step "GStreamer (Arch)" pacman -S --noconfirm --needed gst-libav gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gstreamer-vaapi
  install_step "Video players (Celluloid + MPV)" pacman -S --noconfirm --needed celluloid mpv
}

arch_hwaccel_setup() { install_step "NVIDIA VAAPI driver" pacman -S --noconfirm --needed libva-nvidia-driver; }

arch_archive_support() { install_step "Archive tools (tar, zip, 7zip)" pacman -S --noconfirm --needed tar gzip zip unzip p7zip; }

run_arch() {
  if ! arch_detect; then
    err "OS mismatch: You selected Arch, but this system does not appear to be Arch Linux. Aborting."; exit 1
  fi
  log "Starting Arch flow..."
  arch_update_base
  arch_install_nvidia
  arch_post_install
  arch_flatpak_setup
  arch_media_setup
  arch_hwaccel_setup
  arch_archive_support
}

# ========================= UBUNTU =========================
ubuntu_detect() {
  if [[ -f /etc/os-release ]]; then
    if grep -qiE '^ID=ubuntu' /etc/os-release || grep -qiE '^ID_LIKE=.*ubuntu' /etc/os-release || grep -qi 'Ubuntu' /etc/os-release; then
      return 0
    fi
  fi
  if [[ -f /etc/lsb-release ]] && grep -qi 'ubuntu' /etc/lsb-release; then
    return 0
  fi
  return 1
}

ubuntu_update_base() {
  log "Updating Ubuntu base system..."; apt update -y; ok "apt update complete.";
  log "Running dist-upgrade..."; apt dist-upgrade -y; ok "dist-upgrade complete.";
  install_step "software-properties-common" apt install -y software-properties-common
  log "Autoremoving unused packages..."; apt autoremove -y; ok "Autoremove complete.";
}

ubuntu_install_nvidia() {
  # Check if NVIDIA is already working
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    ok "NVIDIA driver already present and working."
    command -v nvidia-smi &>/dev/null && nvidia-smi || true
    return
  fi

  # Ensure ubuntu-drivers tool exists
  if ! command -v ubuntu-drivers &>/dev/null; then
    install_step "ubuntu-drivers-common" apt install -y ubuntu-drivers-common
  fi

  # Let Ubuntu auto-detect the best driver (may choose open or proprietary as appropriate)
  install_step "Auto-detected NVIDIA driver" ubuntu-drivers install --gpgpu
  warn "If kernel modules aren't loaded yet, a reboot may be required."
}

ubuntu_post_install() { log "(Awaiting your UBUNTU_POST_INSTALL commands — currently empty)"; ok "Ubuntu post-install completed."; }

ubuntu_flatpak_setup() {
  log "Removing Snaps and switching to Flatpak..."
  # Use the local script if present; otherwise fetch it
  TMP_SCRIPT="/tmp/snap-to-flatpak.sh"
  if [[ -f "$(dirname "$0")/snap-to-flatpak.sh" ]]; then
    install_step "snap-to-flatpak (local script)" cp "$(dirname "$0")/snap-to-flatpak.sh" "$TMP_SCRIPT"
  else
    install_step "snap-to-flatpak (download script)" curl -fsSL "https://raw.githubusercontent.com/MasterGeekMX/snap-to-flatpak/refs/heads/main/snap-to-flatpak.sh" -o "$TMP_SCRIPT"
  fi
  chmod +x "$TMP_SCRIPT"
  log "Executing snap-to-flatpak script..."; bash "$TMP_SCRIPT"; ok "Snap removal and Flatpak setup completed."

  # -------------------- Firefox APT (post-snap purge) --------------------
  log "Configuring Mozilla APT repo and installing Firefox..."
  install_step "Create /etc/apt/keyrings" install -d -m 0755 /etc/apt/keyrings
  # If wget missing, install it
  install_step "wget" apt-get install -y wget
  # Import Mozilla repo signing key
  install_step "Import Mozilla APT key" bash -lc 'wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null'
  # Show fingerprint (as provided)
  log "Verifying key fingerprint (expect 35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3)..."
  bash -lc 'gpg -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc | awk "/pub/{getline; gsub(/^ +| +$/,"\"); print 
\$0
}"' || true
  # Add Mozilla repo
  install_step "Add Mozilla APT source" bash -lc 'echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | tee -a /etc/apt/sources.list.d/mozilla.list > /dev/null'
  # Pin Mozilla origin
  install_step "Pin Mozilla origin" bash -lc 'printf "%s
" "Package: *" "Pin: origin packages.mozilla.org" "Pin-Priority: 1000" | tee /etc/apt/preferences.d/mozilla > /dev/null'
  # Update and install Firefox
  log "apt-get update..."; apt-get update -y; ok "apt-get update complete."
  install_step "Firefox (APT)" apt-get install -y firefox
}

ubuntu_media_setup() {
  install_step "Enable multiverse" add-apt-repository -y multiverse
  log "apt update..."; apt update -y; ok "apt update complete.";
  install_step "ubuntu-restricted-extras" apt install -y ubuntu-restricted-extras
  install_step "Video players (Celluloid + MPV)" apt install -y celluloid mpv
}

ubuntu_hwaccel_setup() { install_step "NVIDIA VAAPI driver" apt install -y nvidia-vaapi-driver; }

ubuntu_archive_support() { install_step "Archive tools (7zip, file-roller, rar)" apt install -y 7zip file-roller rar; }

run_ubuntu() {
  if ! ubuntu_detect; then
    err "OS mismatch: You selected Ubuntu, but this system does not appear to be Ubuntu. Aborting."; exit 1
  fi
  log "Starting Ubuntu flow..."
  ubuntu_update_base
  ubuntu_install_nvidia
  ubuntu_post_install
  ubuntu_flatpak_setup
  ubuntu_media_setup
  ubuntu_hwaccel_setup
  ubuntu_archive_support
}

# ------------------------------ Main ------------------------------
main() {
  require_root "$@"
  choose_os
  choose_gpu
  case "$OS_SEL" in
    fedora) run_fedora ;;
    ubuntu) run_ubuntu ;;
    arch)   run_arch ;;
  esac
  ok "All done for $OS_SEL."
}

main "$@"

