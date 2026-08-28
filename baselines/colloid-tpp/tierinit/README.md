# tierinit (Colloid-tpp)

Tier-initialization helper for the Colloid-tpp baseline: registers the far NUMA
node as the slow tier and provides `offline_cpus.sh` / `online_cpus.sh` to take
the slow-tier node's CPUs offline (CXL emulation) and back. Build against the
patched v6.3 kernel tree (see [`../README.md`](../README.md)):

```bash
make                 # -> tierinit.ko
sudo insmod tierinit.ko
sudo ./offline_cpus.sh   # take the slow-tier node's CPUs offline
```
