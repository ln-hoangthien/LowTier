# kswapdrst (Colloid-tpp)

kswapd-reset helper for the Colloid-tpp baseline: keeps `kswapd` from
permanently backing off so demotion does not stall. Build against the patched
v6.3 kernel tree (see [`../README.md`](../README.md)):

```bash
make                  # -> kswapdrst.ko
sudo insmod kswapdrst.ko
```
