#!/usr/bin/env bash
# Unified OS post-install + NVIDIA checker/installer
# v1.3 — baseline with self-update support, DE detection, DE-aware media,
# Fedora ffmpeg stack conflict fixed (swap early; no ffmpeg-libs in VA-API),
# RPM Fusion fallback mirror, quieter Flatpak remote removal, minor hardening.

set -Eeuo pipefail

SCRIPT_VERSION="1.3"
SCRIPT_SOURCE_URL_DEFAULT="https://raw.githubusercontent.com/ArcticLatent/post-linux/main/post_linux.sh"
SCRIPT_SOURCE_URL="${POST_LINUX_SOURCE:-$SCRIPT_SOURCE_URL_DEFAULT}"

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

wait_with_spinner() { # usage: wait_with_spinner <pid> "Message"
  local pid="$1" msg="$2" spin='|/-\\' i=0
  printf '%s ' "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s %s' "$msg" "${spin:i++%${#spin}:1}"
    sleep 0.2
  done
  wait "$pid"
  local status=$?
  printf '\r%s %s\n' "$msg" "done"
  return $status
}

# ---------- Self-update helpers ----------
print_usage() {
  cat <<'EOF'
Usage: post_linux.sh [--update] [--check-update] [--version]
  --update        Download and apply the latest script, then restart.
  --check-update  Check whether a newer script version is available.
  --version       Print the current script version.
  --help          Show this message and exit.
EOF
}

resolve_script_path() {
  local script="$1" resolved=""
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$script" 2>/dev/null || true)"
  elif command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$script" 2>/dev/null || true)"
  fi

  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  if [[ "$script" == */* ]]; then
    (
      cd "$(dirname "$script")" >/dev/null 2>&1 || return 1
      printf '%s/%s\n' "$(pwd)" "$(basename "$script")"
    )
  else
    printf '%s/%s\n' "$(pwd)" "$script"
  fi
}

fetch_latest_version() {
  local remote_contents="" version_line=""

  if [[ -z "${SCRIPT_SOURCE_URL:-}" ]]; then
    warn "SCRIPT_SOURCE_URL is not defined; skipping update check."
    return 1
  fi

  if command -v curl >/dev/null 2>&1; then
    if ! remote_contents="$(curl -fsSL "$SCRIPT_SOURCE_URL" 2>/dev/null)"; then
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! remote_contents="$(wget -qO- "$SCRIPT_SOURCE_URL" 2>/dev/null)"; then
      return 1
    fi
  else
    warn "Cannot check for updates automatically because neither curl nor wget is available."
    return 1
  fi

  version_line="$(printf '%s\n' "$remote_contents" | grep -m1 '^SCRIPT_VERSION=' || true)"
  if [[ -z "$version_line" ]]; then
    return 1
  fi

  version_line="${version_line#SCRIPT_VERSION=}"
  version_line="${version_line#\"}"
  version_line="${version_line#\'}"
  version_line="${version_line%\"}"
  version_line="${version_line%\'}"

  if [[ -z "$version_line" ]]; then
    return 1
  fi

  printf '%s\n' "$version_line"
}

download_remote_script() {
  local url="$1" dest="$2"

  if [[ -z "$url" ]]; then
    return 1
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest" 2>/dev/null || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url" 2>/dev/null || return 1
  else
    warn "Cannot download updates because neither curl nor wget is available."
    return 1
  fi
}

perform_self_update() {
  local new_version="$1"
  shift || true
  local remaining_args=("$@")
  local script_path temp_file original_uid="" original_gid=""

  script_path="$(resolve_script_path "$0")" || script_path="$0"
  if [[ -z "$script_path" ]]; then
    err "Unable to resolve script path for self-update."
    return 1
  fi

  if [[ -e "$script_path" ]] && command -v stat >/dev/null 2>&1; then
    original_uid="$(stat -c '%u' "$script_path" 2>/dev/null || true)"
    original_gid="$(stat -c '%g' "$script_path" 2>/dev/null || true)"
  fi

  if [[ ! -w "$script_path" ]]; then
    err "Cannot self-update: insufficient permissions to modify $script_path."
    return 1
  fi

  temp_file="$(mktemp "${TMPDIR:-/tmp}/post_linux.sh.XXXXXX")" || {
    err "Unable to create temporary file for update."
    return 1
  }

  if ! download_remote_script "$SCRIPT_SOURCE_URL" "$temp_file"; then
    rm -f "$temp_file"
    err "Failed to download latest script from $SCRIPT_SOURCE_URL."
    return 1
  fi

  chmod +x "$temp_file" 2>/dev/null || true
  if mv "$temp_file" "$script_path"; then
    local ownership_spec="" invoking_user="" invoking_group=""
    if [[ -n "$original_uid" ]]; then
      ownership_spec="$original_uid"
      if [[ -n "$original_gid" ]]; then
        ownership_spec+=":$original_gid"
      fi
      if ! chown "$ownership_spec" "$script_path" 2>/dev/null; then
        warn "Updated script installed but ownership restoration to $ownership_spec failed."
      fi
    elif [[ $EUID -eq 0 ]]; then
      invoking_user="$(get_invoking_user)"
      if [[ -n "$invoking_user" && "$invoking_user" != "root" ]]; then
        invoking_group="$(id -gn "$invoking_user" 2>/dev/null || true)"
        if [[ -n "$invoking_group" ]]; then
          if ! chown "$invoking_user:$invoking_group" "$script_path" 2>/dev/null; then
            warn "Updated script installed but ownership change to $invoking_user:$invoking_group failed."
          fi
        elif ! chown "$invoking_user" "$script_path" 2>/dev/null; then
          warn "Updated script installed but ownership change to $invoking_user failed."
        fi
      fi
    fi
    ok "Script updated to version ${new_version:-unknown}."
    exec "$script_path" "${remaining_args[@]}"
  else
    rm -f "$temp_file"
    err "Failed to replace existing script at $script_path."
    return 1
  fi
}

check_for_updates() {
  local remote_version=""

  remote_version="$(fetch_latest_version)" || return 0
  if [[ -z "$remote_version" || "$remote_version" == "$SCRIPT_VERSION" ]]; then
    return 0
  fi

  warn "A new script version is available (${SCRIPT_VERSION} → ${remote_version})."
  read -rp "Would you like to update now? (y/n): " update_choice || {
    warn "No response received; continuing with current version $SCRIPT_VERSION."
    return 0
  }

  if [[ "$update_choice" =~ ^[Yy]$ ]]; then
    if ! perform_self_update "$remote_version" "$@"; then
      warn "Self-update failed; continuing with current version $SCRIPT_VERSION."
    fi
  else
    log "Continuing with current version $SCRIPT_VERSION."
  fi
}

# ---------- CLI flags ----------
POSITIONAL_ARGS=()
UPDATE_REQUESTED=0
CHECK_UPDATE_ONLY=0

handle_cli_args() {
  POSITIONAL_ARGS=()
  UPDATE_REQUESTED=0
  CHECK_UPDATE_ONLY=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update)
        UPDATE_REQUESTED=1
        shift
        ;;
      --check-update)
        CHECK_UPDATE_ONLY=1
        shift
        ;;
      --version)
        echo "$SCRIPT_VERSION"
        exit 0
        ;;
      --help|-h)
        print_usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          POSITIONAL_ARGS+=("$1")
          shift
        done
        break
        ;;
      -*)
        err "Unknown option: $1"
        print_usage
        exit 1
        ;;
      *)
        POSITIONAL_ARGS+=("$1")
        shift
        ;;
    esac
  done

  if ((${#POSITIONAL_ARGS[@]})); then
    err "This script does not accept positional arguments: ${POSITIONAL_ARGS[*]}"
    print_usage
    exit 1
  fi
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
  elif [[ "$lc" == *"cinnamon"* ]]; then
    DESKTOP_ENV="cinnamon"
  else
    if command -v loginctl &>/dev/null; then
      local sid; sid="$(loginctl | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1; exit}')" || true
      [[ -n "$sid" ]] && lc="$(loginctl show-session "$sid" -p Desktop 2>/dev/null | tr '[:upper:]' '[:lower:]')" || true
      if [[ "$lc" == *"gnome"* ]]; then DESKTOP_ENV="gnome"
      elif [[ "$lc" == *"kde"* || "$lc" == *"plasma"* ]]; then DESKTOP_ENV="kde"
      elif [[ "$lc" == *"cinnamon"* ]]; then DESKTOP_ENV="cinnamon"
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
  echo "  4) Linux Mint"
  echo "  5) Debian"
  read -rp "Enter number [1-5]: " ans
  case "$ans" in
    1) OS_SEL="ubuntu" ;;
    2) OS_SEL="fedora" ;;
    3) OS_SEL="arch" ;;
    4) OS_SEL="mint" ;;
    5) OS_SEL="debian" ;;
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

# ===================== NVIDIA akmods build helpers (Fedora) =====================
# List all installed kernel NEVRs like "6.17.4-200.fc42.x86_64"
fedora_list_installed_kernels() {
  rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -u
}

# Ensure kernel-devel is present for a given kernel (NEVR string)
fedora_ensure_kernel_devel_for() {
  local k="$1"
  if [[ ! -e "/lib/modules/${k}/build" ]]; then
    log "Installing kernel-devel for ${k}"
    # Prefer the uname-r virtual provide; fall back to explicit NEVR
    dnf -y install "kernel-devel-uname-r == ${k}" || dnf -y install "kernel-devel-${k}" || {
      warn "Could not install kernel-devel for ${k} — skipping build for this kernel."
      return 1
    }
    ok "kernel-devel for ${k} installed."
  fi
}

# Build akmods (including NVIDIA) for *all installed kernels*
fedora_build_akmods_for_all_kernels() {
  local k; local had_fail=0
  systemctl daemon-reload || true

  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    fedora_ensure_kernel_devel_for "$k" || { had_fail=1; continue; }

    log "Building akmods for kernel ${k}…"
    if akmods --force --kernels "$k"; then
      ok "akmods build ok for ${k}"
    else
      had_fail=1
      err "akmods build failed for ${k}. Recent logs:"
      journalctl -u akmods -n 100 --no-pager || true
    fi
  done < <(fedora_list_installed_kernels)

  if (( had_fail )); then
    warn "Some akmods builds failed; they will rebuild on next boot for those kernels."
  else
    ok "akmods successfully built for all installed kernels."
  fi
}
# ===============================================================================

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

  if fedora_nvidia_installed; then
    ok "NVIDIA driver already present."
    fedora_show_nvidia_info
    return
  fi

  install_step "kernel headers & dev tools" dnf install -y kernel-devel kernel-headers gcc make dkms acpid libglvnd-glx libglvnd-opengl libglvnd-devel pkgconfig

  if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
    log "Applying open kernel module macro for RTX 4000+ GPUs..."
    sh -c 'echo "%_with_kmod_nvidia_open 1" > /etc/rpm/macros.nvidia-kmod'
    ok "Open kernel module macro applied."
  fi

  install_step "NVIDIA driver (akmod + CUDA userspace)" dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda

  # NEW: build akmods for *all installed kernels* (handles both current and newly updated kernels)
  fedora_build_akmods_for_all_kernels

  # Status
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
    dnf -y install gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-libav gstreamer1-plugin-gtk4

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

fedora_ensure_firefox() {
  if dnf list --installed firefox &>/dev/null; then
    ok "Firefox already installed."
  else
    install_step "Firefox" dnf install -y firefox
  fi
}

fedora_prune_gnome_apps() {
  [[ "$DESKTOP_ENV" == "gnome" ]] || return 0
  local candidates=(epiphany gnome-showtime showtime gnome-maps htop gnome-snapshot snapshot simple-scan vim vim-enhanced)
  local remove=()
  local pkg
  for pkg in "${candidates[@]}"; do
    if rpm -q "$pkg" &>/dev/null; then
      remove+=("$pkg")
    fi
  done
  if ((${#remove[@]})); then
    log "Removing GNOME extras via dnf: ${remove[*]}"
    dnf remove -y "${remove[@]}"
    ok "GNOME extras removed."
  else
    ok "No GNOME extras to prune."
  fi
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
  fedora_ensure_firefox              # 9) browser
  fedora_prune_gnome_apps            # 10) GNOME prune (if needed)
  fedora_prune_kde_bloat             # 11) KDE prune (LAST)
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
  if lsmod | grep -qE '^nvidia'; then
    ok "Kernel modules loaded: $(lsmod | awk '/^nvidia/ {print $1}' | paste -sd, -)"
  fi
}

arch_using_custom_kernel() {
  # Treat non-stock kernels (zen/hardened/rt/etc.) as custom and prefer DKMS builds.
  local k
  k="$(uname -r | tr '[:upper:]' '[:lower:]')"
  if [[ "$k" == *-zen* || "$k" == *-hardened* || "$k" == *-ck* || "$k" == *-rt* || "$k" == *-xanmod* || "$k" == *-tkg* ]]; then
    return 0
  fi

  # If neither stock kernel package is present, assume an alternate/custom build.
  if ! pacman -Qq linux >/dev/null 2>&1 && ! pacman -Qq linux-lts >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

arch_install_nvidia() {
  local use_custom_kernel=0
  if arch_using_custom_kernel; then
    use_custom_kernel=1
    log "Custom/alt kernel detected ($(uname -r)); using DKMS NVIDIA packages."
  fi

  if (( use_custom_kernel )); then
    if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
      install_step "NVIDIA (open DKMS) + utils + lib32" pacman -S --noconfirm --needed nvidia-open-dkms nvidia-utils lib32-nvidia-utils
    else
      install_step "NVIDIA (DKMS) + utils + lib32" pacman -S --noconfirm --needed nvidia-dkms nvidia-utils lib32-nvidia-utils
    fi
  else
    if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
      install_step "NVIDIA (open) + utils + lib32" pacman -S --noconfirm --needed nvidia-open nvidia-utils lib32-nvidia-utils
    else
      install_step "NVIDIA (proprietary) + utils + lib32" pacman -S --noconfirm --needed nvidia nvidia-utils lib32-nvidia-utils
    fi
  fi
  arch_show_nvidia_info
}

arch_enable_pacman_candy() {
  local pacman_conf="/etc/pacman.conf"
  if [[ ! -f "$pacman_conf" ]]; then
    warn "pacman.conf not found at $pacman_conf; skipping candy tweaks."
    return 0
  fi

  local changed=0
  if grep -Eq '^[[:space:]]*Color\b' "$pacman_conf"; then
    log "pacman Color already enabled."
  elif grep -Eq '^[[:space:]]*#\s*Color\b' "$pacman_conf"; then
    log "Uncommenting Color in pacman.conf..."
    sed -i '0,/^[[:space:]]*#\s*Color\b/s//Color/' "$pacman_conf"
    changed=1
  else
    log "Color option missing; appending to pacman.conf..."
    printf '\nColor\n' >> "$pacman_conf"
    changed=1
  fi

  if grep -Eq '^[[:space:]]*ILoveCandy\b' "$pacman_conf"; then
    log "ILoveCandy already present in pacman.conf."
  else
    log "Adding ILoveCandy below Color in pacman.conf..."
    local color_line tmpfile
    color_line="$(grep -n '^[[:space:]]*Color\b' "$pacman_conf" | head -n1 | cut -d: -f1 || true)"
    if [[ -n "$color_line" ]]; then
      tmpfile="$(mktemp)"
      awk -v insert_line="$color_line" '
        NR==insert_line { print; print "ILoveCandy"; next }
        { print }
      ' "$pacman_conf" > "$tmpfile"
      cat "$tmpfile" > "$pacman_conf"
      rm -f "$tmpfile"
    else
      printf '\nILoveCandy\n' >> "$pacman_conf"
    fi
    changed=1
  fi

  if (( changed )); then
    ok "Enabled pacman color candy mode."
  else
    ok "pacman.conf already configured for candy mode."
  fi
}

arch_configure_paru() {
  local paru_conf="/etc/paru.conf"
  if [[ ! -f "$paru_conf" ]]; then
    warn "paru.conf not found at $paru_conf; skipping BottomUp tweak."
    return 0
  fi

  if grep -Eq '^[[:space:]]*BottomUp\b' "$paru_conf"; then
    ok "paru BottomUp already enabled."
    return 0
  fi

  if grep -Eq '^[[:space:]]*#\s*BottomUp\b' "$paru_conf"; then
    log "Uncommenting BottomUp in paru.conf..."
    sed -i '0,/^[[:space:]]*#\s*BottomUp\b/s//BottomUp/' "$paru_conf"
  else
    log "BottomUp option missing; appending to paru.conf..."
    printf '\nBottomUp\n' >> "$paru_conf"
  fi
  ok "paru BottomUp enabled."
}

arch_post_install() {
  install_step "rustup (required for paru build)" pacman -S --needed --noconfirm rustup
  install_step "base-devel + git" pacman -S --needed --noconfirm base-devel git

  if command -v paru &>/dev/null; then
    ok "paru already installed; skipping build."
  else
    local invu; invu=$(get_invoking_user)
    if [[ -z "$invu" || "$invu" == "root" ]]; then
      err "Cannot determine a non-root user to build paru. Please run this script with sudo from your regular user."; exit 1
    fi

    log "Ensuring Rust toolchain for paru build (as $invu)..."
    run_as_user "$invu" "if ! rustup show >/dev/null 2>&1; then rustup default stable; fi"

    log "Preparing paru sources (as $invu)..."
    run_as_user "$invu" "cd ~; if [[ -d paru/.git ]]; then cd paru && git fetch origin master && git checkout -f master && git reset --hard origin/master; else git clone https://aur.archlinux.org/paru.git paru; fi"
    ok "paru sources ready."

    log "Building and installing paru (as $invu)..."
    run_as_user "$invu" "cd ~/paru && makepkg -si --noconfirm"
    ok "paru installed."
  fi

  arch_configure_paru
}

arch_firewall_setup() {
  if pacman -Q ufw &>/dev/null; then
    ok "UFW already installed."
  else
    install_step "UFW firewall" pacman -S --noconfirm --needed ufw
  fi

  local status="inactive"
  status="$(ufw status 2>/dev/null | awk 'NR==1 {print $2}')"

  if [[ "$status" != "active" ]]; then
    log "Applying baseline UFW policy (deny incoming, allow outgoing)..."
    ufw default deny incoming
    ufw default allow outgoing
    if systemctl cat sshd.service >/dev/null 2>&1; then
      log "Allowing OpenSSH through UFW..."
      if ufw app info OpenSSH >/dev/null 2>&1; then
        ufw allow OpenSSH
      else
        warn "UFW profile 'OpenSSH' not found; allowing tcp/22 instead."
        ufw allow 22/tcp
      fi
    fi
    ufw --force enable
    ok "UFW enabled."
  else
    ok "UFW already active; leaving existing rules in place."
  fi

  log "Ensuring UFW systemd unit is enabled..."
  systemctl enable --now ufw
  ok "UFW systemd unit enabled."
}

arch_flatpak_setup() { install_step "Flatpak" pacman -S --noconfirm --needed flatpak; }

arch_install_mpc_qt() {
  if pacman -Q mpc-qt-bin &>/dev/null; then
    ok "mpc-qt-bin already installed."
    return
  fi

  local invu; invu=$(get_invoking_user)
  if [[ -z "$invu" || "$invu" == "root" ]]; then
    err "Cannot determine a non-root user to build mpc-qt-bin. Please run this script with sudo from your regular user."; exit 1
  fi

  log "Preparing mpc-qt-bin AUR sources (as $invu)..."
  run_as_user "$invu" "cd ~; if [[ -d mpc-qt-bin/.git ]]; then cd mpc-qt-bin && git fetch origin mpc-qt-bin && git checkout -f mpc-qt-bin && git reset --hard origin/mpc-qt-bin; else git clone --branch mpc-qt-bin --single-branch https://github.com/archlinux/aur.git mpc-qt-bin; fi"
  ok "mpc-qt-bin sources ready."

  log "Building and installing mpc-qt-bin (as $invu)..."
  run_as_user "$invu" "cd ~/mpc-qt-bin && makepkg -si --noconfirm"
  ok "mpc-qt-bin installed."
}

# Media: choose apps by DE
arch_media_setup() {
  if [[ "$DESKTOP_ENV" == "cinnamon" ]]; then
    install_step "Cinnamon media stack" pacman -S --noconfirm --needed showtime gstreamer gstreamer-vaapi gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav
  else
    install_step "GStreamer (Arch)" pacman -S --noconfirm --needed gst-libav gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gstreamer-vaapi gst-plugin-gtk
  fi
  if [[ "$DESKTOP_ENV" == "kde" ]]; then
    install_step "MPV (video player)" pacman -S --noconfirm --needed mpv
    arch_install_mpc_qt
  else
    install_step "GNOME media players (Celluloid + MPV)" pacman -S --noconfirm --needed celluloid mpv
  fi
  install_step "Video thumbnailer" pacman -S --noconfirm --needed ffmpegthumbnailer
}

arch_hwaccel_setup() { install_step "NVIDIA VAAPI driver" pacman -S --noconfirm --needed libva-nvidia-driver; }

arch_archive_support() { install_step "Archive tools (tar, zip, 7zip)" pacman -S --noconfirm --needed tar gzip zip unzip p7zip; }

arch_ensure_firefox() {
  if pacman -Q firefox &>/dev/null; then
    ok "Firefox already installed."
  else
    install_step "Firefox" pacman -S --noconfirm --needed firefox
  fi
}

arch_prune_gnome_apps() {
  [[ "$DESKTOP_ENV" == "gnome" ]] || return 0
  local candidates=(epiphany gnome-web epiphany-browser gnome-showtime showtime gnome-maps htop gnome-snapshot snapshot simple-scan vim)
  local remove=()
  local pkg
  for pkg in "${candidates[@]}"; do
    if pacman -Qi "$pkg" &>/dev/null; then
      remove+=("$pkg")
    fi
  done
  if ((${#remove[@]})); then
    log "Removing GNOME extras via pacman: ${remove[*]}"
    pacman -Rsn --noconfirm "${remove[@]}"
    ok "GNOME extras removed."
  else
    ok "No GNOME extras to prune."
  fi
}

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

arch_cinnamon_setup() {
  install_step "Cinnamon desktop essentials" \
    pacman -S --noconfirm --needed ristretto papers gedit gnome-calculator papirus-icon-theme file-roller nemo-fileroller

  if pacman -Q engrampa &>/dev/null; then
    log "Removing engrampa in favor of nemo-fileroller integration..."
    pacman -Rsn --noconfirm engrampa
    ok "engrampa removed."
  fi

  local invu; invu=$(get_invoking_user)
  if [[ -z "$invu" || "$invu" == "root" ]]; then
    err "Cannot determine a non-root user to build mint-artwork. Please run this script with sudo from your regular user."; exit 1
  fi

  local log_file; log_file="$(mktemp /tmp/mint-artwork.XXXX.log)"
  log "Installing Mint artwork package (themes, icons, Cinnamon sounds). This may take a bit — logs: $log_file"
  run_as_user "$invu" "paru -S --noconfirm --needed mint-artwork" >"$log_file" 2>&1 &
  local paru_pid=$!
  if ! wait_with_spinner "$paru_pid" "Mint artwork install"; then
    err "mint-artwork installation failed. Check $log_file for details."
    return 1
  fi
  rm -f "$log_file"
  ok "mint-artwork installed."

  local lightdm_conf="/etc/lightdm/lightdm.conf"
  if [[ -f "$lightdm_conf" ]]; then
    log "Configuring LightDM to use lightdm-slick-greeter..."
    if grep -Eq '^#?greeter-session' "$lightdm_conf"; then
      sed -i 's/^#\?greeter-session.*/greeter-session=lightdm-slick-greeter/' "$lightdm_conf"
    else
      printf '\n[Seat:*]\n' >> "$lightdm_conf"
      echo 'greeter-session=lightdm-slick-greeter' >> "$lightdm_conf"
    fi
    ok "LightDM greeter set to lightdm-slick-greeter."
  else
    warn "LightDM config not found at $lightdm_conf; skipping greeter setup."
  fi
}

run_arch() {
  if ! arch_detect; then
    err "OS mismatch: You selected Arch, but this system does not appear to be Arch Linux. Aborting."; exit 1
  fi
  log "Starting Arch flow..."
  arch_update_base             # 1) system update FIRST
  arch_enable_pacman_candy     # 1b) pacman niceties
  arch_install_nvidia          # 2) drivers
  arch_post_install            # 3) dev tools + paru
  arch_firewall_setup          # 4) firewall
  arch_flatpak_setup           # 5) flatpak
  arch_media_setup             # 6) media (DE-aware)
  arch_hwaccel_setup           # 7) hwaccel
  arch_archive_support         # 8) archives
  if [[ "$DESKTOP_ENV" == "cinnamon" ]]; then
    arch_cinnamon_setup        # Cinnamon-specific tasks (pending package list)
  fi
  arch_ensure_firefox          # 9) browser
  arch_prune_gnome_apps        # 10) GNOME prune (if needed)
  arch_prune_kde_bloat         # 11) KDE prune (LAST)
}

# ========================= LINUX MINT =========================
mint_detect() {
  if [[ -f /etc/os-release ]]; then
    if grep -qiE '^ID=linuxmint' /etc/os-release || grep -qiE '^ID_LIKE=.*linuxmint' /etc/os-release || grep -qi 'Linux Mint' /etc/os-release; then
      return 0
    fi
  fi
  if [[ -f /etc/lsb-release ]] && grep -qi 'linuxmint' /etc/lsb-release; then
    return 0
  fi
  return 1
}

mint_update_base() {
  log "Ensuring 32-bit (i386) architecture support..."
  if ! dpkg --print-foreign-architectures | grep -qx 'i386'; then
    dpkg --add-architecture i386
    ok "i386 architecture enabled."
  else
    ok "i386 architecture already enabled."
  fi
  log "Updating package lists..."; apt update; ok "apt update complete.";
  log "Upgrading packages..."; apt upgrade -y; ok "apt upgrade complete.";
  install_step "software-properties-common" apt install -y software-properties-common
}

mint_install_nvidia() {
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    ok "NVIDIA driver already present and working."
    nvidia-smi || true
    return
  fi

  install_step "graphics-drivers PPA" add-apt-repository -y ppa:graphics-drivers/ppa
  log "Refreshing package lists after adding PPA..."; apt update; ok "apt update complete."

  install_step "Kernel headers, build-essential, dkms" bash -lc 'apt install -y "linux-headers-$(uname -r)" build-essential dkms'
  if ! command -v ubuntu-drivers &>/dev/null; then
    install_step "ubuntu-drivers-common" apt install -y ubuntu-drivers-common
  fi

  log "Detecting available NVIDIA drivers..."
  local drv_list ver pkg
  drv_list=$(ubuntu-drivers devices 2>/dev/null || true)
  echo "$drv_list" | sed 's/^/[INFO]  /'

  if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
    ver=$(printf '%s\n' "$drv_list" | awk '
      {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^nvidia-driver-[0-9]+-open$/) {
            split($i, parts, "-")
            if (parts[3] + 0 > max) { max = parts[3] + 0 }
          }
        }
      }
      END { if (max != "") { printf "%d", max } }
    ')
    if [[ -n "$ver" ]]; then pkg="nvidia-driver-${ver}-open"; fi
  else
    ver=$(printf '%s\n' "$drv_list" | awk '
      {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^nvidia-driver-[0-9]+$/) {
            split($i, parts, "-")
            if (parts[3] + 0 > max) { max = parts[3] + 0 }
          }
        }
      }
      END { if (max != "") { printf "%d", max } }
    ')
    if [[ -n "$ver" ]]; then pkg="nvidia-driver-${ver}"; fi
  fi

  if [[ -z "${pkg:-}" ]]; then
    warn "Could not determine a specific driver package from ubuntu-drivers output. Falling back to autoinstall."
    install_step "Auto-detected NVIDIA driver" ubuntu-drivers autoinstall
  else
    if [[ "$pkg" == *"-open" ]]; then
      install_step "NVIDIA open driver ($pkg)" apt install -y "$pkg"
    else
      install_step "NVIDIA driver ($pkg)" apt install -y "$pkg"
    fi
  fi
}

mint_post_install() {
  log "Setting runtime swappiness to 10 (favor RAM over swap)..."
  sysctl vm.swappiness=10
  ok "Runtime swappiness set to 10."

  install_step "Persist swappiness=10" bash -lc "printf 'vm.swappiness=10\n' | tee /etc/sysctl.d/99-swappiness.conf > /dev/null"
  install_step "Mint core utilities" apt install -y unzip ntfs-3g p7zip curl bzip2 tar exfat-fuse wget unrar gstreamer1.0-vaapi libgtk-4-media-gstreamer
  ok "Linux Mint post-install tweaks applied."
}

mint_media_setup() {
  if dpkg-query -W -f='${Status}' mint-meta-codecs 2>/dev/null | grep -q "install ok installed"; then
    ok "mint-meta-codecs already installed."
  else
    install_step "mint-meta-codecs" apt install -y mint-meta-codecs
  fi

  if ! command -v flatpak &>/dev/null; then
    install_step "Flatpak" apt install -y flatpak
  fi

  local invu
  invu="$(get_invoking_user)"
  install_step "Showtime (Flatpak)" run_as_user "$invu" "flatpak install -y --or-update flathub org.gnome.Showtime"
}

mint_hwaccel_setup() { install_step "NVIDIA VAAPI driver" apt install -y nvidia-vaapi-driver; }

mint_ensure_firefox() {
  if dpkg-query -W -f='${Status}' firefox 2>/dev/null | grep -q "install ok installed"; then
    ok "Firefox already installed."
  else
    install_step "Firefox" apt install -y firefox
  fi
}

run_mint() {
  if ! mint_detect; then
    err "OS mismatch: You selected Linux Mint, but this system does not appear to be Linux Mint. Aborting."; exit 1
  fi
  log "Starting Linux Mint flow..."
  mint_update_base
  mint_install_nvidia
  mint_post_install
  mint_media_setup
  mint_hwaccel_setup
  mint_ensure_firefox
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
  install_step "ubuntu-restricted-extras" apt install -y ubuntu-restricted-extras libgtk-4-media-gstreamer
  install_step "Video players (Celluloid + MPV)" apt install -y celluloid mpv
}

ubuntu_hwaccel_setup() { install_step "NVIDIA VAAPI driver" apt install -y nvidia-vaapi-driver; }

ubuntu_archive_support() { install_step "Archive tools (7zip, file-roller, rar)" apt install -y 7zip file-roller rar; }

ubuntu_prune_gnome_apps() {
  [[ "$DESKTOP_ENV" == "gnome" ]] || return 0
  local candidates=(epiphany-browser gnome-web epiphany gnome-showtime showtime gnome-maps htop gnome-snapshot snapshot simple-scan vim)
  local remove=()
  local pkg
  for pkg in "${candidates[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      remove+=("$pkg")
    fi
  done
  if ((${#remove[@]})); then
    log "Removing GNOME extras via apt: ${remove[*]}"
    apt remove -y "${remove[@]}"
    ok "GNOME extras removed."
  else
    ok "No GNOME extras to prune."
  fi
}

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
  ubuntu_prune_gnome_apps
}

# ========================= DEBIAN =========================
debian_detect() {
  if [[ -f /etc/os-release ]]; then
    if grep -qiE '^ID=debian' /etc/os-release || grep -qiE '^ID_LIKE=.*debian' /etc/os-release || grep -qi 'Debian' /etc/os-release; then
      return 0
    fi
  fi
  return 1
}

debian_update_base() {
  log "Updating package lists (apt update)..."
  apt update
  ok "apt update complete."
  log "Applying full-upgrade..."
  apt full-upgrade -y
  ok "Full upgrade completed."
}

debian_ensure_sudo_privileges() {
  local invu; invu="$(get_invoking_user)"
  if [[ -z "$invu" || "$invu" == "root" ]]; then
    warn "Non-root invoking user not detected; skipping sudoers update."
    return 0
  fi

  if sudo -l -U "$invu" >/dev/null 2>&1; then
    ok "$invu already has sudo privileges."
    return 0
  fi

  local sudoers_file="/etc/sudoers.d/${invu}"
  log "Granting sudo privileges to $invu via $sudoers_file..."
  printf '%s ALL=(ALL:ALL) ALL\n' "$invu" > "$sudoers_file"
  chmod 0440 "$sudoers_file"
  if visudo -cf "$sudoers_file"; then
    ok "Sudo privileges granted to $invu."
  else
    err "visudo validation failed; removing $sudoers_file."
    rm -f "$sudoers_file"
    return 1
  fi
}

debian_enable_extra_repos() {
  local src="/etc/apt/sources.list"
  local backup="${src}.bak"
  local block="deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security/ trixie-security main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian-security/ trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware"

  if grep -Fqx 'deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware' "$src" 2>/dev/null; then
    ok "Extra Debian repositories already present in $src."
    return 0
  fi

  if [[ -f "$src" ]]; then
    cp "$src" "$backup"
    ok "Backed up $src to $backup."
    sed -i '/^[[:space:]]*#/! s/^/# /' "$src"
  else
    warn "$src not found; creating a fresh one."
  fi

  printf '\n%s\n' "$block" >> "$src"
  ok "Added Debian Trixie repositories to $src."

  log "Updating package lists after repository changes..."
  apt update
  ok "apt update completed with new repositories."
}

debian_post_repo_upgrade() {
  log "Running apt --update upgrade after repository changes..."
  apt --update upgrade -y
  ok "apt upgrade after repository changes completed."
}

debian_setup_extrepo() {
  install_step "extrepo" apt install -y extrepo

  local cfg="/etc/extrepo/config.yaml"
  if [[ ! -f "$cfg" ]]; then
    warn "$cfg not found; skipping extrepo config tweak."
    return 0
  fi

  sed -i 's/^[[:space:]]*#\s*-\s*contrib/- contrib/' "$cfg"
  sed -i 's/^[[:space:]]*#\s*-\s*non-free/- non-free/' "$cfg"

  if grep -Eq '^[[:space:]]*-\s*contrib' "$cfg" && grep -Eq '^[[:space:]]*-\s*non-free' "$cfg"; then
    ok "extrepo config updated to enable contrib and non-free."
  else
    warn "Could not confirm contrib/non-free were enabled in $cfg; please review manually."
  fi
}

debian_install_nvidia() {
  install_step "Kernel headers" apt install -y linux-headers-amd64

  if [[ "$GPU_SEL" == "ada_4000_plus" ]]; then
    install_step "NVIDIA (open) driver stack" apt install -y nvidia-open-kernel-dkms nvidia-driver firmware-misc-nonfree
  else
    install_step "NVIDIA driver stack" apt install -y nvidia-kernel-dkms nvidia-driver firmware-misc-nonfree
  fi
}

debian_flatpak_setup() {
  install_step "Flatpak" apt install -y flatpak
  install_step "Flathub remote" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

  local invu; invu="$(get_invoking_user)"
  if [[ -z "$invu" || "$invu" == "root" ]]; then
    warn "Non-root invoking user not detected; skipping user Flatpak app install."
    return 0
  fi

  install_step "Flatseal (Flatpak)" run_as_user "$invu" "flatpak install -y --or-update flathub com.github.tchx84.Flatseal"
  install_step "Bazaar (Flatpak)" run_as_user "$invu" "flatpak install -y --or-update flathub io.github.kolunmi.Bazaar"
}

debian_install_fonts() {
  install_step "Microsoft fonts and alternatives" apt install -y ttf-mscorefonts-installer fonts-crosextra-caladea fonts-crosextra-carlito
}

debian_hwaccel_setup() {
  install_step "NVIDIA VAAPI driver" apt install -y nvidia-vaapi-driver
}

debian_install_essentials() {
  install_step "Essential packages" apt install -y git curl wget fastfetch mpv gcc make python3 python3-pip unrar unzip cargo p7zip ntfs-3g htop ffmpeg fonts-noto fonts-noto-cjk
}

debian_gnome_extras() {
  [[ "$DESKTOP_ENV" == "gnome" ]] || return 0
  install_step "GNOME Tweaks + Extension Manager" apt install -y gnome-tweaks gnome-shell-extension-manager
  install_step "GNOME Software Flatpak plugin" apt install -y gnome-software-plugin-flatpak
}

run_debian() {
  if ! debian_detect; then
    err "OS mismatch: You selected Debian, but this system does not appear to be Debian. Aborting."; exit 1
  fi
  log "Starting Debian flow..."
  debian_update_base
  debian_ensure_sudo_privileges
  debian_enable_extra_repos
  debian_post_repo_upgrade
  debian_setup_extrepo
  debian_install_nvidia
  debian_hwaccel_setup
  debian_flatpak_setup
  debian_install_fonts
  debian_install_essentials
  debian_gnome_extras
  ok "Debian post-install completed."
}

# ------------------------------ Main ------------------------------
main() {
  local original_args=("$@")
  local remote_version=""

  handle_cli_args "$@"

  if (( UPDATE_REQUESTED )); then
    if ! remote_version="$(fetch_latest_version)"; then
      err "Unable to determine latest script version."
      exit 1
    fi
    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
      ok "Script is already up to date (version $SCRIPT_VERSION)."
      exit 0
    fi
    require_root "${original_args[@]}"
    if ! perform_self_update "$remote_version"; then
      exit 1
    fi
    exit 0
  fi

  if (( CHECK_UPDATE_ONLY )); then
    if ! remote_version="$(fetch_latest_version)"; then
      err "Unable to determine latest script version."
      exit 1
    fi
    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
      ok "Script version $SCRIPT_VERSION is up to date."
    else
      warn "Script update available: $SCRIPT_VERSION -> $remote_version"
    fi
    exit 0
  fi

  require_root "${original_args[@]}"
  check_for_updates "${original_args[@]}"
  detect_de
  choose_os
  choose_gpu
  case "$OS_SEL" in
    fedora) run_fedora ;;
    ubuntu) run_ubuntu ;;
    mint)   run_mint ;;
    arch)   run_arch ;;
    debian) run_debian ;;
  esac
  ok "All done for $OS_SEL."
}

main "$@"
