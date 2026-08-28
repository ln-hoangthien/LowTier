# TPP (ASPLOS '23)

Transparent Page Placement, evaluated as a tiering baseline.

## Contents
- `tpp.patch` - kernel patch applied on top of Linux `v5.15`.
- `compile.sh` - checks out `v5.15` in a sibling `linux/` git tree, applies
  `tpp.patch`, builds, installs modules, runs `make install` and
  `update-grub`.

## Build
`compile.sh` expects a Linux git checkout in `./linux` (not bundled). Clone it
first, then build (kernel install + `update-grub` need root):

```bash
cd tpp
git clone https://github.com/torvalds/linux.git linux   # v5.15 is a mainline tag
sudo ./compile.sh
```

The script runs: `git checkout v5.15` → `git apply tpp.patch` →
`make olddefconfig` → `make -j` → `make modules_install` → `make install` →
`update-grub`.

## Running a workload
This directory ships the kernel patch only; there is no TPP-specific run
wrapper. Boot into the patched kernel, then drive a workload with your own
launcher (TPP operates transparently in the kernel once booted).
