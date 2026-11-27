# GPU lab investigation — the GRID K2 verdict (2026-11-26/27)

Outcome: **the GRID K2 has no usable 2026 stack — pull the cards.** This
file preserves the evidence so the conclusion doesn't need re-deriving.

## The hardware

| Fact | Value |
|---|---|
| Card(s) | 2× NVIDIA GK104GL **GRID K2** GPUs (`10de:11bf`), 4 GB GDDR5 each |
| Compute capability | sm_30 (Kepler, 2012) |
| Headless | no display ports (GRID cards have none) |

## The evidence chain (all measured)

1. **Driver ceiling** — kernel-confirmed on three attempts:
   - driver 470.256.02: `NVRM: ... supported through the NVIDIA 367.xx
     Legacy drivers. The 470.256.02 NVIDIA driver will ignore this GPU.`
   - driver 390.157: `The 390.157 NVIDIA driver will ignore this GPU.`
   - driver 384.130: `The 384.130 NVIDIA driver will ignore this GPU.`
   The card tops out at **driver 367.xx (2016) → CUDA 8.0**.
2. **CUDA 8.0 era = the ecosystem floor of 2016.** Everything modern
   floors higher: Ollama ≥ CC 5.0, llama.cpp CUDA ≥ 6.0, PyTorch ≥ 1.4
   needs driver ≥ 418, SD 1.5 needs torch ≥ 1.4. **LLM inference, SD
   generation, and modern training are impossible on this card.**
3. **367.57 build on xenial (4.4.0-210 ESM kernel)** — the .run installer
   fails: the ESM kernel backported the 4.10-era `get_user_pages` API
   change, breaking `nvidia-drm`. Manual `NV_EXCLUDE_KERNEL_MODULES`
   build attempts hit follow-on build-system failures (archheaders,
   parallel-make races). No community patch set covers 4.4-ESM + 367.
4. **CUDA 8 survivors** (all pinned to the 2016 stack — torch 0.4.1 /
   TF 1.3 / cupy-cuda80): chess-bot training of tiny policy nets,
   YOLOv2-tiny detection, NVENC H.264 (ffmpeg with legacy nvenc headers).
   Each is buildable only after further driver patching — and each is
   matched or beaten by the R730's 32 Broadwell threads on modern stacks.

## Why the 2060 works and the K2 doesn't (the operator's question)

Not card age — **driver floor**. The 2060 (Turing) sits inside every
modern support floor (current driver → CUDA 12 → all wheels). The K2 sits
below even the oldest EOL wheel (torch 1.13/cu117 needs driver 515).

## Deployment saga (lessons recorded)

- jammy cloud images are **UEFI-only** — SeaBIOS reports "not a bootable
  disk"; OVMF shows a boot menu on fresh efidisk0 (one-time; `sendkey ret`
  via the monitor, VGA device attached, selects the disk and persists).
- A failed `qm create` followed by `qm set --scsi0 local-zfs:64` creates a
  **new blank disk instead of resizing the cloned one** — the OS disk fell
  to `unused0` and the VM silently booted an empty disk. Always
  `qm config` after scripted disk changes.
- xenial is **still on archive.ubuntu.com** (ESM until 2026-04), NOT
  old-releases — switching sources breaks apt.
- The tenant-host restarts (this box's current instability) interrupted
  every long apt/dkms/driver step at least once; long guest setup must run
  detached from the controlling session.

## Current state of VM 150 `gpu-lab` (192.168.0.131)

Running Ubuntu 16.04.7, 8 vCPU / 16 GiB / 64 GiB, both GPUs passed
through (vfio-pci on hosting01, persisted via driverctl +
/etc/modprobe.d/vfio-gpu.conf), driver 367.57 installed but **non-
functional** (no usable module). The guest is otherwise a working
CPU-only VM.

### Options

1. **Pull the cards** (recommended: −150 W, −heat, −2 PCIe slots; CPU
   inference and transcode cover the estate's needs). Requires first:
   `qm set 150 --delete hostpci0 --delete hostpci1` or VM 150 won't start.
2. Keep the VM as a plain CPU compute guest (current state minus driver).
3. NVENC archaeology (ffmpeg + nv-codec-headers ≤ 8.1 against driver 367)
   — possible, not recommended: hours of pinning for a transcoder the
   CPUs already cover.

## What the estate actually uses instead

- Clawdius LLM inference: **CPU** (Ollama-class on 32 Broadwell threads)
  or API providers — on VM 140 when provisioned.
- Chess-bot training: the workstation's RTX 2060 (10-20× the K2, modern
  stack).
- Tradebot strategy sweeps: CPU (vectorized numpy is already fast);
  a 2060-class GPU later if sweeps grow.
- Video transcode: CPU, or a future modern GPU with NVENC.
