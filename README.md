# 🧊 Post-Linux — Universal Linux Post-Install Script

A fully automated **post-install script** that configures your system for production and creative workflows across **Fedora**, **Arch**, **Ubuntu**, **Linux Mint**, and **Debian**.

> 🎯 Includes NVIDIA drivers, Flatpak setup, media codecs, hardware acceleration, archive utilities, and more — with clean progress feedback.

---

## 🚀 Features

- 🧠 Detects your OS (**Fedora**, **Arch**, **Ubuntu**, **Linux Mint**, or **Debian**)
- ⚙️ Installs the latest **NVIDIA** drivers (open or proprietary)
- 🧩 Replaces **Snap with Flatpak** on Ubuntu
- 🌱 Prepares **Linux Mint** with i386 support, latest NVIDIA drivers, and curated multimedia defaults
- 🌐 Reinstalls Firefox via Mozilla’s official APT repository
- 🎬 Enables media codecs, **Celluloid + MPV for GNOME**, **MPC-QT + MPV for KDE Plasma**, and GPU acceleration
- 🗜️ Adds archive tools (`7zip`, `rar`, `file-roller`, etc.)
- 🧱 Clean `Installing... / Installed.` feedback for every step

---

## 🧩 Supported Distros

| Distro | NVIDIA | Flatpak | Codecs | Archive |
|:--|:--:|:--:|:--:|:--:|
| ![Fedora](https://img.shields.io/badge/Fedora-40%2B-0A6CF5?logo=fedora&logoColor=white&style=flat-square) | ✅ akmod + CUDA | ✅ Flatpak | ✅ GStreamer + ffmpeg | ✅ |
| ![Arch Linux](https://img.shields.io/badge/Arch_Linux-Rolling-1793D1?logo=archlinux&logoColor=white&style=flat-square) | ✅ open/proprietary | ✅ Flatpak | ✅ GStreamer | ✅ |
| ![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%2B-E95420?logo=ubuntu&logoColor=white&style=flat-square) | ✅ Auto-detects latest NVIDIA open / proprietary driver | ✅ Snap→Flatpak | ✅ Multiverse + Extras | ✅ |
| ![Linux Mint](https://img.shields.io/badge/Linux_Mint-22%2B-87CF3E?logo=linux-mint&logoColor=white&style=flat-square) | ✅ graphics-drivers PPA (open / proprietary) | ✅ Flatpak | ✅ mint-meta-codecs | ✅ |
| ![Debian](https://img.shields.io/badge/Debian-13_Trixie-A81D33?logo=debian&logoColor=white&style=flat-square) | ✅ open/proprietary (kernel DKMS) | ✅ Flatpak | ✅ Full A/V codecs | ✅ |

---

## 🧊 Fedora-Specific Features

Fedora users benefit from a streamlined, fully native NVIDIA and multimedia setup:

- ⚙️ **Automatic NVIDIA driver installation**  
  Installs the latest available `akmod-nvidia` package with CUDA support, ensuring your GPU drivers are rebuilt automatically across kernel updates.

- 🧩 **Open kernel module for RTX 4000+**  
  For **RTX 4000 series and newer GPUs**, Fedora needs a build macro to enable the open NVIDIA kernel module **before** installing the driver.  
  The script sets this automatically. Manually, you can run:

  ```bash
  # Set open kernel module macro (one-time step for RTX 4000+)
  sudo sh -c 'echo "%_with_kmod_nvidia_open 1" > /etc/rpm/macros.nvidia-kmod'
  ```

  After this is set, `akmods` will build using the open NVIDIA kernel module.

- 🎬 **Full multimedia stack**  
  Installs `gstreamer1-plugins-*`, `ffmpeg`, and related codecs to unlock playback support in all major apps.

- 🧱 **Archive utilities**  
  Installs common compression tools such as `7zip`, `unrar`, and `file-roller`.

- 🌐 **Flatpak + Flathub**  
  Ensures Flatpak is enabled and Flathub is configured as the primary source for desktop applications.

Together, these ensure a smooth Fedora experience with open driver support, media acceleration, and production-ready utilities.

---

## 🧊 Arch Cinnamon Enhancements

When the script detects **Arch Linux running the Cinnamon desktop**, it layers on a tailored experience to bring Mint-like polish to the stock Arch install:

- 🧰 **Desktop essentials preinstalled** — `ristretto`, `papers`, `gedit`, `gnome-calculator`, `papirus-icon-theme`, `file-roller`, and `nemo-fileroller` are installed in one shot so the desktop feels ready immediately.
- 🗜️ **Clean file manager integration** — automatically removes `engrampa` to avoid duplicate archive handlers and lets `nemo-fileroller` take over compression/extraction duties.
- 🎨 **Mint artwork bundle (AUR)** — builds the large `mint-artwork` package via `paru` with a quiet spinner + log file so the terminal stays tidy while themes, icons, sounds, and LightDM slick greeter assets install.
- 🔐 **LightDM configured automatically** — once the artwork lands, `/etc/lightdm/lightdm.conf` is patched to use `lightdm-slick-greeter`, matching the Mint visual style right at login.
- 🎬 **Cinnamon media stack** — installs GNOME Showtime plus `gstreamer`, `gstreamer-vaapi`, and the full GST plugin families, then adds `ffmpegthumbnailer` for rich file previews.

These additions only run on Arch+Cinnamon systems; other Arch desktops continue to receive the lean, DE-aware defaults.

---

## 🧊 Linux Mint-Specific Features

Linux Mint 22+ systems are prepped for gaming and creative work with minimal manual intervention:

- 🧱 **Enables 32-bit (i386) architecture and updates immediately**  
  Adds the i386 architecture if missing, then runs a full `apt update && apt upgrade -y` so your base system is current before drivers land.

- ⚙️ **Installs NVIDIA drivers via the graphics-drivers PPA**  
  Adds the official Graphics Drivers PPA, installs `linux-headers-$(uname -r)`, `build-essential`, and `dkms`, then picks the right driver:  
  - RTX 4000/5000 → latest `nvidia-driver-###-open`  
  - RTX 3000 and older → latest `nvidia-driver-###`  
  Falls back to `ubuntu-drivers autoinstall` if detection ever fails.

- 💾 **Optimizes memory and filesystem tooling**  
  Sets `vm.swappiness=10` (runtime + persistent) so RAM is preferred over swap, then installs `unzip`, `ntfs-3g`, `p7zip`, `curl`, `bzip2`, `tar`, `exfat-fuse`, `wget`, `unrar`, and `gstreamer1.0-vaapi`.

- 🎬 **Maximizes multimedia support**  
  Ensures the `mint-meta-codecs` bundle is installed so H.264, HEVC, and other formats play instantly.

- 🚀 **Enables NVIDIA VAAPI playback**  
  Installs `nvidia-vaapi-driver` so compatible players can tap the GPU for decoding workloads.

- 📺 **Installs GNOME Showtime from Flathub**  
  Verifies Flatpak is present, then installs `org.gnome.Showtime` for a modern video playback experience.

---

## 🧊 Ubuntu-Specific Features

Ubuntu users get a clean, optimized, and GPU-ready setup automatically:

- 🧹 **Removes Snap packages completely**  
  The script purges Snap and related services using the included `snap-to-flatpak.sh` helper.

- 🔄 **Switches to Flatpak**  
  After Snap removal, Flathub is added as the default Flatpak remote.

- ⚙️ **Installs NVIDIA drivers intelligently**  
  The script detects your GPU generation and installs the latest compatible driver:  

  - For **RTX 4000 series and newer** → Installs the **latest available NVIDIA Open Kernel Module driver** (e.g., `nvidia-driver-580-open`).  
  - For **RTX 3000 series and earlier** → Installs the **latest proprietary NVIDIA driver** automatically.  
  - If detection fails for any reason, it falls back to:

  ```bash
  sudo ubuntu-drivers autoinstall
  ```

- 🌐 **Restores Firefox from Mozilla’s official repository (no PPA)**  
  Removing Snap removes the Snap-based Firefox, so the script reinstalls Firefox from **Mozilla’s official APT repository** (with GPG + pinning) to get a native `.deb`:

  ✅ **Verified GPG Key Fingerprint:**  
  ```
  35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3
  ```

Together, this ensures a Flatpak-friendly Ubuntu with a native, GPU-optimized system and up-to-date Firefox.

---

## 🧊 Debian-Specific Features

Debian 13 (Trixie) systems get a modernized desktop with sane defaults out of the box:

- 🔄 **Full update + repo refresh** — runs `apt update && apt full-upgrade -y`, backs up and comments your stock `/etc/apt/sources.list`, then writes the Trixie `main contrib non-free non-free-firmware` sources and refreshes apt.
- 📦 **extrepo enabled with contrib/non-free** — installs `extrepo` and uncomments `contrib` and `non-free` in `/etc/extrepo/config.yaml` so you can easily add third-party repos.
- ⚙️ **NVIDIA headers + drivers (open or proprietary)** — installs `linux-headers-amd64`, then picks `nvidia-open-kernel-dkms` for RTX 4000/5000 or `nvidia-kernel-dkms` for older GPUs, plus `nvidia-driver` and `firmware-misc-nonfree`.
- 🎬 **Hardware acceleration** — adds `nvidia-vaapi-driver` for GPU-backed decoding.
- 🌐 **Flatpak + Flathub + desktop tooling** — installs Flatpak, adds Flathub, and installs Flatseal + Bazaar for managing and browsing Flatpaks.
- 🗜️ **Essential tools + codecs + fonts** — installs CLI essentials (`git`, `curl`, `wget`, `fastfetch`, `htop`, `ffmpeg`, build tools, archive utils, NTFS support), Microsoft core fonts, and Noto (Latin + CJK).
- 🧩 **GNOME niceties (GNOME desktops only)** — installs GNOME Tweaks, GNOME Shell Extension Manager, and the GNOME Software Flatpak plugin.

These steps aim to keep Debian close to upstream while enabling common multimedia, GPU, and desktop conveniences with minimal manual effort.

---

## 🧮 Usage

```bash
git clone https://github.com/ArcticLatent/post-linux.git
cd post-linux
chmod +x post_linux.sh
./post_linux.sh
```

Follow the interactive prompts to choose your distro and GPU series.

---

## ♻️ Updating the Script

- `./post_linux.sh --check-update` — see if a newer release is available.
- `./post_linux.sh --update` — download the latest copy and rerun automatically.
- `./post_linux.sh --version` — print the currently installed version.
- Set `POST_LINUX_SOURCE` to point at an alternate raw URL if you host your own fork.

The script compares its local `SCRIPT_VERSION` against the remote source and offers to self-update before running the main workflow.

---

## ⚡ Requirements

- Internet connection  
- `sudo` privileges  
- Recommended: reboot after first full update

---

## 🧊 Author

Burce Boran 🎥 Asset Supervisor / VFX Artist | 🐧 Arctic Latent

[![YouTube – Arctic Latent](https://img.shields.io/badge/YouTube-%40ArcticLatent-FF0000?logo=youtube&logoColor=white)](https://youtube.com/@ArcticLatent)
[![Patreon – Arctic Latent](https://img.shields.io/badge/Patreon-Arctic%20Latent-FF424D?logo=patreon&logoColor=white)](https://patreon.com/ArcticLatent)
[![Hugging Face – Arctic Latent](https://img.shields.io/badge/HuggingFace-Arctic%20Latent-FFD21E?logo=huggingface&logoColor=white)](https://huggingface.co/arcticlatent)

---

## 📜 License

MIT License © 2025 Burce Boran  
Contributions welcome — open a PR or issue!
