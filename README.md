# 🧊 Post-Linux — Universal Linux Post-Install Script

A fully automated **post-install script** that configures your system for production and creative workflows across **Fedora**, **Arch**, and **Ubuntu**.

> 🎯 Includes NVIDIA drivers, Flatpak setup, media codecs, hardware acceleration, archive utilities, and more — with clean progress feedback.

---

## 🚀 Features

- 🧠 Detects your OS (**Fedora**, **Arch**, or **Ubuntu**)
- ⚙️ Installs the latest **NVIDIA** drivers (open or proprietary)
- 🧩 Replaces **Snap with Flatpak** on Ubuntu
- 🌐 Reinstalls **Firefox** via Mozilla’s official APT repository
- 🎬 Enables media codecs, **Celluloid + MPV**, and GPU acceleration
- 🗜️ Adds archive tools (`7zip`, `rar`, `file-roller`, etc.)
- 🧱 Clean `Installing... / Installed.` feedback for every step

---

## 🧩 Supported Distros

| Distro | NVIDIA | Flatpak | Codecs | Archive |
|:--|:--:|:--:|:--:|:--:|
| **Fedora 40+** | ✅ akmod + CUDA | ✅ RPM Fusion | ✅ GStreamer + ffmpeg | ✅ |
| **Arch Linux** | ✅ open/proprietary | ✅ | ✅ GStreamer | ✅ |
| **Ubuntu 22.04+** | ✅ Driver 580 PPA | ✅ Snap→Flatpak | ✅ Multiverse + Extras | ✅ |

---

## 🧊 Ubuntu-Specific Features

Ubuntu users get a clean and modern setup automatically:

- 🧹 **Removes Snap packages completely**  
  The script purges Snap and all related services using the included `snap-to-flatpak.sh` helper script.

- 🔄 **Switches to Flatpak**  
  After Snap removal, Flathub is added as the default Flatpak remote, ensuring access to thousands of desktop apps.

- 🌐 **Restores Firefox via official APT repository**  
  Because removing Snap also removes the preinstalled Snap-based Firefox, the script:
  1. Adds Mozilla’s official APT repository and imports its GPG key  
  2. Pins it with high priority for future updates  
  3. Installs the latest **Firefox `.deb`** package system-wide  

  The imported key fingerprint is verified as:

35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3


Together, this ensures a fully open, Flatpak-friendly Ubuntu environment with a native, up-to-date Firefox browser.

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
