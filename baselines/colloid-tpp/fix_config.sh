#!/bin/bash
cd /home/c425/thienle/LowTier/baselines/colloid-tpp/linux
./scripts/config --disable KERNEL_ZSTD
./scripts/config --disable KERNEL_LZ4
./scripts/config --disable KERNEL_BZIP2
./scripts/config --disable KERNEL_LZMA
./scripts/config --disable KERNEL_XZ
./scripts/config --disable KERNEL_LZO
./scripts/config --enable KERNEL_GZIP
