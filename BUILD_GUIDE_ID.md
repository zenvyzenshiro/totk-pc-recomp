# Panduan Build Singkat (Ryzen 5 7500F + RX 6700 XT, TotK 1.4.3)

Branch `feature/rdna2-zen4`. Build resmi: [docs/building.md](docs/building.md). Catatan teknis fork ini:
[docs/rdna2-zen4.md](docs/rdna2-zen4.md).

## 1. Pasang toolchain (sekali)

| Tool | Cara |
|---|---|
| MSYS2 UCRT64 | installer msys2.org ke `C:\msys64`, lalu di shell UCRT64 jalankan `pacman -Syuu` (dua kali) dan perintah `pacman -S ...` dari docs/building.md |
| Visual Studio Build Tools | `winget install Microsoft.VisualStudio.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive"` |
| .NET SDK 10, uv, Git | sudah terpasang di PC ini |
| Vulkan SDK | opsional |

Cek semuanya tanpa mem-build:

```powershell
powershell -ExecutionPolicy Bypass -File .\BUILD_ME.ps1 -CheckOnly
```

## 2. Build

```powershell
powershell -ExecutionPolicy Bypass -File .\BUILD_ME.ps1
```

- Membaca `config.local.toml` (sudah dibuat, diabaikan Git): XCI, update NSP 1.4.3 (v720896) dan `prod.keys` di
  `E:\Games\ProjectZelda`. File game hanya dibaca.
- Ekstraksi butuh ~60 GB di drive E: (sekali; dilewati bila sudah terverifikasi).
- Hasil: **`E:\Games\ProjectZelda\TOTK-RDNA2-Fork\build\v143\totk.exe`**.
- `build\v143\totk.ini` dibuat hanya jika belum ada: `amd_preset = 1` (vk_recorder 0, astc cpu), 2560x1440, 60 FPS.
- `-SkipShaders` melewati persiapan shader (game akan stutter sampai cache terisi).

## 3. Mod Bahasa Indonesia

```powershell
powershell -ExecutionPolicy Bypass -File .\INSTALL_INDONESIAN_MOD.ps1
```

- Sumber: `E:\Games\ProjectZelda\zelda_totk_indonesian_v1.0` (atau ZIP mod di folder induk). Folder mod tidak diubah.
- Memeriksa hash RomFS 1.4.3, SHA-256 file asli, ukuran dekompresi (11.428.456 byte), dan konflik dengan
  `romfs-patches`, lalu menulis overlay ke `build\v143\mods\indonesian` dengan `manifest.tsv`.
- Mod tidak membawa `manifest.tsv` sendiri; manifest dibuat oleh `tools\make_romfs_mod.py`.
- Mod berisi nama `Product.100/121/142`. Bila 1.4.3 memakai nomor lain, arsip yang sama dipetakan hanya jika ukuran
  dekompresinya sama dengan file asli; jika tidak, instalasi berhenti tanpa mengubah apa pun.
- Menambahkan `romfs_mods = ...` dan `lang = en-US` ke `totk.ini` (cadangan `totk.ini.bak`).
- Copot: `.\INSTALL_INDONESIAN_MOD.ps1 -Uninstall`.

## 4. Pengaturan F1

- **Advanced → AMD compatibility preset**: mengisi kunci yang belum diatur dengan `vk_recorder = 0`, `astc = cpu`.
  Nilai yang Anda atur sendiri selalu menang.
- **Advanced → Vulkan → Vulkan recorder thread**: ON/OFF jalur recorder (penyebab potensial `VK_ERROR_DEVICE_LOST`;
  aktifkan lagi hanya untuk pengujian).
- **Screen → Graphics → 3D render scale**: kini memberi nama mode FSR: 50 % Performance, 59 % Balanced,
  67 % Quality, 77 % Ultra Quality (FSR 1 bawaan game).
- **Upscaler: AMD FSR 1** tetap sebagai upscaler ke ukuran jendela.

## 5. Keterbatasan (jujur)

- **FSR 2/3.1 temporal dan Frame Generation FSR 3.1 belum diimplementasikan**, sehingga tidak ada toggle-nya di F1.
  Keduanya butuh motion vector, depth, dan jitter dari game; renderer ini memutar ulang perintah NVN dan belum punya
  data itu. Detail di docs/rdna2-zen4.md.
- FSR 4 / FG berbasis ML khusus RX 9000 tidak dipakai.
- Belum ada perubahan yang diuji di game: build, jalankan, dan laporkan log `totk.log` bila ada masalah.

## Save dan instalasi lama

Save di `build\profile-v143` (format sama dengan upstream). Instalasi lama di
`E:\Games\The Legend of Zelda Tears of the Kingdom` tidak disentuh; untuk memakai save lama, salin manual folder
profile-nya ke `build\profile-v143` setelah membuat cadangan.
