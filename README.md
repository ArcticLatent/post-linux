# 🧊 Post-Linux — Universal Linux Post-Install Script

A fully automated **post-install script** that configures your system for production and creative workflows across **Fedora**, **Arch**, and **Ubuntu**.

> 🎯 Includes NVIDIA drivers, Flatpak setup, media codecs, hardware acceleration, archive utilities, and more — with clean progress feedback.

---

## 🚀 Features

- 🧠 Detects your OS (Fedora / Arch / Ubuntu)
- ⚙️ Installs the latest **NVIDIA** driver (open & legacy paths)
- 🧩 Switches **Ubuntu from Snap → Flatpak**
- 🎬 Enables codecs, **Celluloid + MPV**, and GPU acceleration
- 🗜️ Adds archive tools (7-Zip / RAR / File-Roller)
- 🧱 Clean “Installing… / Installed.” feedback for every step

---

## 🧩 Supported Distros

| Distro | NVIDIA | Flatpak | Codecs | Archive |
|:--|:--:|:--:|:--:|:--:|
| **Fedora 40 +** | ✅ akmod + CUDA | ✅ RPM Fusion | ✅ GStreamer + ffmpeg | ✅ |
| **Arch Linux** | ✅ open/proprietary | ✅ | ✅ GStreamer | ✅ |
| **Ubuntu 22.04 +** | ✅ Driver 580 PPA | ✅ Snap→Flatpak | ✅ Multiverse + Extras | ✅ |

---

## 🧮 Usage

```bash
git clone https://github.com/<your_username>/post-linux.git
cd post-linux
chmod +x post_linux.sh
./post_linux.sh

Follow the interactive prompts to choose your distro and GPU series.
⚡ Requirements

    Internet connection

    sudo privileges

    For Fedora + Arch: recommended to run after first full update

📜 License

MIT License © 2025 Burce Boran
Contributions welcome — open a PR or issue!
<p align="center"> <img src="https://img.shields.io/badge/Linux-Post-Install-Script-blue?logo=linux&logoColor=white&style=for-the-badge" alt="Badge"/> <img src="https://img.shields.io/badge/NVIDIA-Ready-green?logo=nvidia&logoColor=white&style=for-the-badge" alt="NVIDIA Badge"/> </p> ```
