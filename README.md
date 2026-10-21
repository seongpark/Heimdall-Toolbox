# Heimdall Toolbox (macOS)

Everything you need—Heimdall, adb, fastboot, lz4, and required libraries—is bundled inside the `.app`, so you just need to run the app after building.

## Features

| Tab | Description |
|---|---|
| **Devices** | Detects ADB / Fastboot / Download mode devices, reboots (System, Recovery, Download, Bootloader, Sideload), and runs ADB shell commands |
| **APK Install** | Drag & drop support, batch installation for multiple APKs, split APKs (`install-multiple`), and `-r -d -g -t` options (including debug/test APK installation) |
| **ADB Sideload** | Directly send ZIP files while in Recovery "Apply update from ADB" mode |
| **File Transfer** | Instantly copy files using `adb push` to desired directories like `/sdcard/Download` |
| **Odin Flash (Heimdall)** | Load BL/AP/CP/CSC `.tar.md5` files just like Odin: extracts archive $\rightarrow$ extracts `.lz4` $\rightarrow$ automatically maps partitions via PIT $\rightarrow$ flashes. Supports manual image addition, `--no-reboot`, `--resume`, and `--repartition` |

## Download

Get the ZIP file matching your Mac from [Releases](../../releases) (`arm64` = Apple Silicon, `x86_64` = Intel).

## Build from Source

**Requirements:** macOS 13 or later, Xcode Command Line Tools, Homebrew (only required during the build process)

```bash
cd HeimdallToolbox
chmod +x build.sh
./build.sh
```

## Structure

```
Heimdall Toolbox.app/Contents
├── MacOS/HeimdallToolbox           
└── Resources
    ├── bin/  adb, fastboot, heimdall, lz4 (+ platform-tools)
    ├── lib/  libusb, liblz4 etc
    └── AppIcon.icns
```

Heimdall is licensed under the MIT License, and Android platform-tools follow Google's Terms of Service.
