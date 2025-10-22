#!/usr/bin/env bash
# Unified OS post-install + NVIDIA checker/installer
# v0.6.4 — Fedora/Arch start with updates, DE detection, DE-aware media,
# Fedora ffmpeg stack conflict fixed (swap early; no ffmpeg-libs in VA-API),
# RPM Fusion fallback mirror, quieter Flatpak remote removal, minor hardening.

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

# ---------- Desktop Environment detection ----------
DESKTOP_ENV="unknown"
detect_de() {
  local raw lc
  raw="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
  lc="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lc" == *"gnome"* ]]; then
    DESKTOP_ENV="gnome"
  elif [[ "$lc" == *"kde"* || "$lc" == *"plasma"* ]]; then
    DESKTOP_ENV="kde"
  else
    if command -v loginctl &>/dev/null; then
      local sid; sid="$(loginctl | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1; exit}')" || true
      [[ -n "$sid" ]] && lc="$(loginctl show-session "$sid" -p Desktop 2>/dev/null | tr '[:upper:]' '[:lower:]')" || true
      if [[ "$lc" == *"gnome"* ]]; then DESKTOP_ENV="gnome"
      elif [[ "$lc" == *"kde"* || "$lc" == *"plasma"* ]]; then DESKTOP_ENV="kde"
      fi
    fi
  fi
  ok "Desktop environment detected: ${DESKTOP_ENV}"
}

OS_SEL=""
GPU_SEL=""

choose_os() {
  echo "Choose your OS:"
  echo "  1) Ubuntu"
  echo "  2) Fedora"
  echo "  3) Arch"
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
  echo "Select NVIDIA GPU generation:"
  echo "  1) RTX 4000/5000 series (Ada/Lovelace-next)"
  echo "  2) RTX 3000 series or older (Ampere/Turing/older)"
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

# ---- Wait for akmods to finish building (NVIDIA kmod) ----
fedora_wait_for_akmods() {
  local timeout=$((25*60))   # 25 minutes worst-case
  local elapsed=0

  log "Starting akmods build (if needed)…"
  systemctl start akmods.service 2>/dev/null || true

  # Follow logs in background while we wait
  log "Following akmods logs… (this will auto-stop when the build ends)"
  journalctl -fu akmods &
  local JPID=$!

  # Wait until the unit is no longer 'active', or until timeout
  while systemctl is-active --quiet akmods; do
    sleep 2
    elapsed=$((elapsed+2))
    if (( elapsed >= timeout )); then
      warn "Timeout waiting for akmods after $((timeout/60)) minutes."
      break
    fi
  done

  # Stop log follow
  kill "$JPID" 2>/dev/null || true
  wait "$JPID" 2>/dev/null || true

  # Check result and show a brief summary
  if systemctl is-failed --quiet akmods; then
    err "akmods failed. Showing last 200 lines of logs:"
    journalctl -u akmods -n 200 --no-pager || true
  else
    ok "akmods finished (state: $(systemctl show -p ActiveState -p Result akmods | tr '\n' ' ' | sed 's/ActiveState=//;s/ Result=//'))."
  fi

  # Extra sanity checks
  if ! modinfo nvidia >/dev/null 2>&1; then
    warn "nvidia module not found yet; it may require a reboot or will build on first boot."
  fi
}

# Start with a real system update
fedora_update_base() {
  log "Applying full system update (dnf -y upgrade --refresh)…"
  dnf -y upgrade --refresh
  ok "System updated."
}

fedora_nvidia_installed() {
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then return 0; fi; return 1;
}

fedora_show_nvidia_info() {
  # If nvidia-smi exists and succeeds, consider the driver healthy.
  if command -v nvidia-smi &>/dev/null && nvidia-smi; then
    ok "nvidia-smi succeeded."

    # Try to show which modules are loaded (informational only).
    if lsmod | grep -E -q '^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm)\b'; then
      ok "Kernel modules loaded: $(lsmod | awk '/^nvidia/ {print $1}' | paste -sd, -)"
    else
      # Don't warn—just note that module listing can be transient.
      log "NVIDIA modules not visible in lsmod right now; this can be transient (persistence daemon off)."
      log "If you want them to stay resident: sudo systemctl enable --now nvidia-persistenced"
    fi
    return 0
  fi

  # nvidia-smi missing or failed -> real problem
  if ! command -v nvidia-smi &>/dev/null; then
    warn "nvidia-smi not found in PATH."
  else
    warn "nvidia-smi returned non-zero; driver may not be active."
  fi

  # Check modules to aid debugging
  if lsmod | grep -E -q '^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm)\b'; then
    ok "Some NVIDIA modules are loaded: $(lsmod | awk '/^nvidia/ {print $1}' | paste -sd, -)"
  else
    warn "NVIDIA kernel modules are not currently loaded."
  fi
}

fedora_enable_rpmfusion() {
  local ver; ver=$(. /etc/os-release; echo "$VERSION_ID")
  if ! rpm -q rpmfusion-free-release &>/dev/null; then
    install_step "RPM Fusion (free)" bash -lc 'dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-'${ver}'.noarch.rpm" || dnf -y install "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-'${ver}'.noarch.rpm"'
  else ok "RPM Fusion (free) already enabled"; fi
  if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
    install_step "RPM Fusion (nonfree)" bash -lc 'dnf -y install "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-'${ver}'.noarch.rpm" || dnf -y install "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-'${ver}'.noarch.rpm"'
  else ok "RPM Fusion (nonfree) already enabled"; fi
}

fedora_install_nvidia() {
  if [[ -x /usr/bin/mokutil ]] && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Secure Boot is ENABLED. NVIDIA modules may not load unless you enroll a MOK or disable Secure Boot."
  fi
  if fedora_nvidia_installed; then ok "NVIDIA driver already present."; fedora_show_nvidia_info; return; fi
  install_step "kernel headers & dev tools" dnf install -y kernel-devel kernel-headers gcc make dkms acpid libglvnd-glx libglvnd-opengl libglvnd-devel pkgconf-pkg-config
  if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
    log "Applying open kernel module macro for RTX 4000+ GPUs..."; sh -c 'echo "%_with_kmod_nvidia_open 1" > /etc/rpm/macros.nvidia-kmod'; ok "Open kernel module macro applied."
  fi
  install_step "NVIDIA driver (akmod + CUDA userspace)" dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
  # Wait for akmods to complete (so the rest of the script runs with a built module)
  fedora_wait_for_akmods
  # Show status after build (if it’s already available)
  fedora_show_nvidia_info
}

fedora_post_install() {
  log "Running Fedora post-install commands..."
  log "Upgrading core group..."; dnf group upgrade core -y; ok "Core group upgraded."
  log "Checking updates..."; dnf check-update || true; ok "Check complete."
  log "Applying updates..."; dnf update -y || true; ok "System updated."
  if dnf history | grep -qi kernel; then
    read -rp "Kernel update may have occurred. Reboot now? (y/n): " r; [[ "$r" =~ ^[Yy]$ ]] && reboot || warn "Please reboot manually later."
  fi
  ok "Fedora post-install completed."
}

fedora_flatpak_setup() {
  install_step "Remove Fedora Flatpak remote" bash -lc 'flatpak remote-delete fedora >/dev/null 2>&1 || true'
  install_step "Add Flathub Flatpak remote" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
}

# Media: choose apps by DE; ensure full ffmpeg stack first to avoid conflicts
fedora_media_setup() {
  # Core + common codecs via FFmpeg bridge
  install_step "GStreamer (base + good + libav)" \
    dnf -y install gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-libav

  # Multimedia and sound groups (no bad plugins)
  install_step "Multimedia group" dnf -y group install multimedia
  install_step "Sound & video group" dnf -y group install sound-and-video

  # Desktop-specific media players
  if [[ "$DESKTOP_ENV" == "kde" ]]; then
    install_step "KDE media players (mpc + mpc-qt)" dnf -y install mpc mpc-qt
  else
    install_step "GNOME media players (Celluloid + MPV)" dnf -y install celluloid mpv
  fi
}

fedora_hwaccel_setup() {
  install_step "VA-API libs" dnf install -y libva libva-utils
  install_step "NVIDIA VAAPI driver" bash -lc 'dnf -q repolist | grep -q rpmfusion-nonfree && dnf -y install nvidia-vaapi-driver || { echo "[WARN] rpmfusion-nonfree missing; skipping nvidia-vaapi-driver"; true; }'
}

fedora_archive_support() {
  install_step "Archive tools (7zip + unrar)" dnf install -y p7zip p7zip-plugins unrar
}

# KDE bloat prune (last step)
fedora_prune_kde_bloat() {
  [[ "$DESKTOP_ENV" != "kde" ]] && return 0
  log "KDE detected — pruning optional apps…"

  # 1) Remove any installed LibreOffice packages (resolve real names first)
  mapfile -t lo_pkgs < <(rpm -qa 'libreoffice*' || true)
  if ((${#lo_pkgs[@]})); then
    log "Removing LibreOffice packages: ${lo_pkgs[*]}"
    dnf remove -y "${lo_pkgs[@]}" || true
  else
    log "No LibreOffice packages found."
  fi

  # 2) Remove specific KDE apps if present
  local pkgs=(kmahjongg kmines kpat kolourpaint skanpage akregator kmail krdc krdp neochat krfb ktnef dragon elisa-player kamoso qrca)
  for p in "${pkgs[@]}"; do
    if rpm -q "$p" &>/dev/null; then
      dnf remove -y "$p" || true
    fi
  done

  ok "KDE optional apps pruned."
}

run_fedora() {
  if ! fedora_detect; then
    err "OS mismatch: You selected Fedora, but this system does not appear to be Fedora. Aborting."; exit 1
  fi
  log "Starting Fedora flow..."
  fedora_update_base                 # 1) system update FIRST
  fedora_enable_rpmfusion            # 2) repos
  fedora_install_nvidia              # 3) drivers
  fedora_post_install                # 4) remaining post-install items
  fedora_flatpak_setup               # 5) flatpak
  fedora_media_setup                 # 6) media (DE-aware) + ffmpeg swap
  fedora_hwaccel_setup               # 7) hwaccel (no ffmpeg-libs here)
  fedora_archive_support             # 8) archives
  fedora_prune_kde_bloat             # 9) KDE prune (LAST)
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

# Start with a real system update
arch_update_base() {
  log "Refreshing package databases & upgrading (pacman -Syu)…"
  pacman -Syu --noconfirm
  ok "System updated."
}

arch_nvidia_installed() { if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then return 0; fi; return 1; }

arch_show_nvidia_info() {
  command -v nvidia-smi &>/dev/null && nvidia-smi || true
  if lsmod | grep -qE '^nvidia'; then ok "Kernel modules loaded: $(lsmod | awk '/^nvidia/ {print $1}' | paste -sd, -)"; else warn "nvidia kernel modules are not currently loaded"; fi
}

arch_install_nvidia() {
  if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
    install_step "NVIDIA (open) + utils + lib32" pacman -S --noconfirm --needed nvidia-open nvidia-utils lib32-nvidia-utils
  else
    install_step "NVIDIA (proprietary) + utils + lib32" pacman -S --noconfirm --needed nvidia nvidia-utils lib32-nvidia-utils
  fi
  arch_show_nvidia_info
}

arch_post_install() {
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

  local pkg
  pkg=$(ls -t /home/"$invu"/yay/*.pkg.tar.* 2>/dev/null | head -n1 || true)
  if [[ -n "$pkg" ]]; then
    install_step "Install yay package" pacman -U --noconfirm "$pkg"
  else
    err "Failed to locate built yay package for installation."; exit 1
  fi
}

arch_flatpak_setup() { install_step "Flatpak" pacman -S --noconfirm --needed flatpak; }

# Media: choose apps by DE
arch_media_setup() {
  install_step "GStreamer (Arch)" pacman -S --noconfirm --needed gst-libav gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gstreamer-vaapi
  if [[ "$DESKTOP_ENV" == "kde" ]]; then
    install_step "KDE media players (mpc + mpc-qt)" pacman -S --noconfirm --needed mpc mpc-qt
  else
    install_step "GNOME media players (Celluloid + MPV)" pacman -S --noconfirm --needed celluloid mpv
  fi
}

arch_hwaccel_setup() { install_step "NVIDIA VAAPI driver" pacman -S --noconfirm --needed libva-nvidia-driver; }

arch_archive_support() { install_step "Archive tools (tar, zip, 7zip)" pacman -S --noconfirm --needed tar gzip zip unzip p7zip; }

# KDE bloat prune (last step)
arch_prune_kde_bloat() {
  [[ "$DESKTOP_ENV" != "kde" ]] && return 0
  log "KDE detected — pruning optional apps…"
  # Remove libreoffice* if present
  pacman -Qq | grep -E '^libreoffice' >/dev/null 2>&1 && \
    pacman -Rns --noconfirm $(pacman -Qq | grep -E '^libreoffice') || true
  # Remove specific apps (ignore if not installed)
  local pkgs=(kmahjongg kmines kpat kolourpaint skanpage akregator kmail krdc krdp neochat krfb ktnef dragon elisa kamoso qrca)
  for p in "${pkgs[@]}"; do
    pacman -Rns --noconfirm "$p" || true
  done
  ok "KDE optional apps pruned."
}

run_arch() {
  if ! arch_detect; then
    err "OS mismatch: You selected Arch, but this system does not appear to be Arch Linux. Aborting."; exit 1
  fi
  log "Starting Arch flow..."
  arch_update_base             # 1) system update FIRST
  arch_install_nvidia          # 2) drivers
  arch_post_install            # 3) dev tools + yay
  arch_flatpak_setup           # 4) flatpak
  arch_media_setup             # 5) media (DE-aware)
  arch_hwaccel_setup           # 6) hwaccel
  arch_archive_support         # 7) archives
  arch_prune_kde_bloat         # 8) KDE prune (LAST)
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
  log "Updating Ubuntu base system..."; apt update; ok "apt update complete.";
  log "Running dist-upgrade..."; apt dist-upgrade -y; ok "dist-upgrade complete.";
  install_step "software-properties-common" apt install -y software-properties-common
  log "Autoremoving unused packages..."; apt autoremove -y; ok "Autoremove complete.";
}

ubuntu_install_nvidia() {
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    ok "NVIDIA driver already present and working."
    nvidia-smi || true
    return
  fi

  log "Updating system (apt update && apt upgrade -y)..."
  apt update
  apt upgrade -y
  ok "System packages updated."

  install_step "Build tools + kernel headers" bash -lc 'apt install -y build-essential linux-headers-$(uname -r)'
  if ! command -v ubuntu-drivers &>/dev/null; then
    install_step "ubuntu-drivers-common" apt install -y ubuntu-drivers-common
  fi

  log "Probing available NVIDIA drivers..."
  local drv_list drv_nums latest ver pkg
  drv_list=$(ubuntu-drivers list 2>/dev/null || true)
  echo "$drv_list" | sed 's/^/[INFO]  /'

  if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
    drv_nums=$(echo "$drv_list" | grep -oE 'nvidia-driver-[0-9]+-open' | grep -oE '[0-9]+' | sort -n | uniq)
    latest=$(echo "$drv_nums" | tail -n1)
    if [[ -n "$latest" ]]; then ver="$latest"; pkg="nvidia-driver-${ver}-open"; fi
  else
    drv_nums=$(echo "$drv_list" | grep -oE 'nvidia-driver-[0-9]+( |$)' | grep -oE '[0-9]+' | sort -n | uniq)
    latest=$(echo "$drv_nums" | tail -n1)
    if [[ -n "$latest" ]]; then ver="$latest"; pkg="nvidia-driver-${ver}"; fi
  fi

  if [[ -z "${pkg:-}" ]]; then
    warn "Could not determine a specific driver package from ubuntu-drivers list. Falling back to autoinstall."
    install_step "Auto-detected NVIDIA driver" ubuntu-drivers autoinstall
  else
    install_step "NVIDIA driver ($pkg)" apt install -y "$pkg"
  fi

  if [[ -f /etc/default/grub ]]; then
    if ! grep -q 'nvidia-drm.modeset=1' /etc/default/grub; then
      log "Adding nvidia-drm.modeset=1 to GRUB_CMDLINE_LINUX_DEFAULT..."
      awk -v add='nvidia-drm.modeset=1' 'BEGIN{FS=OFS="\""} /^GRUB_CMDLINE_LINUX_DEFAULT=/ { if(index($2, add)==0){ $2=$2 " " add } } {print}' /etc/default/grub > /tmp/grub.new && mv /tmp/grub.new /etc/default/grub
      ok "Kernel cmdline updated."
      log "Updating GRUB..."; update-grub; ok "GRUB updated."
    else
      ok "GRUB already includes nvidia-drm.modeset=1"
    fi
  else
    warn "/etc/default/grub not found; skipping GRUB update."
  fi

  warn "Reboot may be required for modules to load and KMS to take effect."
}

ubuntu_post_install() { log "(Awaiting your UBUNTU_POST_INSTALL commands — currently empty)"; ok "Ubuntu post-install completed."; }

ubuntu_flatpak_setup() {
  log "Removing Snaps and switching to Flatpak..."
  TMP_SCRIPT="/tmp/snap-to-flatpak.sh"
  if [[ -f "$(dirname "$0")/snap-to-flatpak.sh" ]]; then
    install_step "snap-to-flatpak (local script)" cp "$(dirname "$0")/snap-to-flatpak.sh" "$TMP_SCRIPT"
  else
    install_step "snap-to-flatpak (download script)" curl -fsSL "https://raw.githubusercontent.com/MasterGeekMX/snap-to-flatpak/main/snap-to-flatpak.sh" -o "$TMP_SCRIPT"
  fi
  chmod +x "$TMP_SCRIPT"
  log "Executing snap-to-flatpak script..."; bash "$TMP_SCRIPT"; ok "Snap removal and Flatpak setup completed."

  log "Configuring Mozilla APT repo and installing Firefox..."
  install_step "Create /etc/apt/keyrings" install -d -m 0755 /etc/apt/keyrings
  install_step "wget" apt-get install -y wget
  install_step "Import Mozilla APT key" bash -lc 'wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc'
  log "Verifying key fingerprint (expect 35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3)..."
  bash -lc 'gpg --show-keys --with-fingerprint /etc/apt/keyrings/packages.mozilla.org.asc | sed -n "s/^ *Key fingerprint = //p"' || true
  install_step "Add Mozilla APT source" bash -lc 'echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | tee /etc/apt/sources.list.d/mozilla.list > /dev/null'
  install_step "Pin Mozilla origin" bash -lc 'printf "%s\n" "Package: *" "Pin: origin packages.mozilla.org" "Pin-Priority: 1000" | tee /etc/apt/preferences.d/mozilla > /dev/null'
  log "apt-get update..."; apt-get update; ok "apt-get update complete."
  install_step "Firefox (APT)" apt-get install -y firefox
}

ubuntu_media_setup() {
  install_step "Enable multiverse" add-apt-repository -y multiverse
  log "apt update..."; apt update; ok "apt update complete."
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
  detect_de
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
