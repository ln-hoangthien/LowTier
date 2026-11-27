// SPDX-License-Identifier: GPL-2.0
// tierinit - Emulate a lower memory tier on Node 1 for Linux 7.x AutoNUMA
//
// Moves FARMEM_NUMA (Node 1) out of the default DRAM tier into a slower memory
// tier (FARMEM_ADISTANCE) and rebuilds demotion targets using kprobes-resolved
// mm/memory-tiers.c symbols.

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/mutex.h>
#include <linux/kprobes.h>
#include <linux/memory-tiers.h>
#include <linux/device.h>
#include <linux/rcupdate.h>
#include <linux/list.h>
#include <linux/nodemask.h>

#define FARMEM_ADISTANCE	(MEMTIER_ADISTANCE_DRAM * 10)
#define FARMEM_NUMA		1
#define LOCAL_NUMA		0

/* Private layouts matching Linux 7.3 mm/memory-tiers.c */
struct node_memory_type_map {
	struct memory_dev_type *memtype;
	int map_count;
};

struct memory_tier {
	struct list_head list;
	struct list_head memory_types;
	int adistance_start;
	struct device dev;
	nodemask_t lower_tier_mask;
};

typedef unsigned long (*kallsyms_lookup_name_t)(const char *name);
typedef struct memory_tier *(*set_node_memory_tier_t)(int node);
typedef void (*establish_demotion_targets_t)(void);
typedef bool (*node_is_toptier_t)(int node);
typedef int (*next_demotion_node_t)(int node, const nodemask_t *allowed_mask);

static struct memory_dev_type *farmem_type;
static struct mutex *k_memory_tier_lock;
static struct memory_dev_type **k_default_dram_type;
static int *k_top_tier_adistance;
static struct node_memory_type_map *k_node_memory_types;
static set_node_memory_tier_t k_set_node_memory_tier;
static establish_demotion_targets_t k_establish_demotion_targets;
static node_is_toptier_t k_node_is_toptier;
static next_demotion_node_t k_next_demotion_node;
static void **k_node_demotion;

static const char * const establish_candidates[] = {
	"establish_demotion_targets",
	"establish_demotion_targets.part.0",
	"establish_demotion_targets.constprop.0",
	"establish_demotion_targets.isra.0",
};

static unsigned long kprobe_addr(const char *name)
{
	struct kprobe kp = { .symbol_name = name };
	unsigned long addr;

	if (register_kprobe(&kp) < 0)
		return 0;
	addr = (unsigned long)kp.addr;
	unregister_kprobe(&kp);
	return addr;
}

static int resolve_symbols(void)
{
	kallsyms_lookup_name_t lookup;
	int i;

	lookup = (kallsyms_lookup_name_t)kprobe_addr("kallsyms_lookup_name");
	if (!lookup) {
		pr_err("tierinit: cannot resolve kallsyms_lookup_name\n");
		return -ENOENT;
	}

	k_memory_tier_lock     = (void *)lookup("memory_tier_lock");
	k_default_dram_type    = (void *)lookup("default_dram_type");
	k_top_tier_adistance   = (void *)lookup("top_tier_adistance");
	k_node_memory_types    = (void *)lookup("node_memory_types");
	k_set_node_memory_tier = (void *)lookup("set_node_memory_tier");
	k_node_is_toptier      = (void *)lookup("node_is_toptier");
	k_next_demotion_node   = (void *)lookup("next_demotion_node");
	k_node_demotion        = (void *)lookup("node_demotion");

	for (i = 0; i < ARRAY_SIZE(establish_candidates); i++) {
		k_establish_demotion_targets =
			(void *)lookup(establish_candidates[i]);
		if (k_establish_demotion_targets)
			break;
	}

	if (!k_memory_tier_lock || !k_default_dram_type ||
	    !k_top_tier_adistance || !k_node_memory_types ||
	    !k_set_node_memory_tier || !k_establish_demotion_targets ||
	    !k_node_is_toptier || !k_next_demotion_node || !k_node_demotion) {
		pr_err("tierinit: failed to resolve required memory-tier symbols\n");
		return -ENOENT;
	}

	return 0;
}

static void call_establish_demotion_targets(void)
{
	if (*k_node_demotion)
		k_establish_demotion_targets();
}

static void do_clear_memory_tier(int node)
{
	pg_data_t *pgdat = NODE_DATA(node);
	struct memory_tier *memtier;

	mutex_lock(k_memory_tier_lock);
	if (pgdat) {
		memtier = rcu_dereference_protected(pgdat->memtier,
						    lockdep_is_held(k_memory_tier_lock));
		if (memtier) {
			struct memory_dev_type *memtype;

			rcu_assign_pointer(pgdat->memtier, NULL);
			synchronize_rcu();
			memtype = k_node_memory_types[node].memtype;
			node_clear(node, memtype->nodes);
			if (nodes_empty(memtype->nodes)) {
				list_del_init(&memtype->tier_sibling);
				if (list_empty(&memtier->memory_types)) {
					list_del(&memtier->list);
					device_unregister(&memtier->dev);
				}
			}
		}
	}
	call_establish_demotion_targets();
	mutex_unlock(k_memory_tier_lock);
}

static void do_init_memory_tier(int node)
{
	struct memory_tier *memtier;

	mutex_lock(k_memory_tier_lock);
	memtier = k_set_node_memory_tier(node);
	if (!IS_ERR(memtier))
		call_establish_demotion_targets();
	mutex_unlock(k_memory_tier_lock);
}

static int __init tierinit_init(void)
{
	int top_adist, ret;

	ret = resolve_symbols();
	if (ret)
		return ret;

	pr_info("tierinit: demotion[%d]=%d (before)\n", LOCAL_NUMA,
		k_next_demotion_node(LOCAL_NUMA, &node_states[N_MEMORY]));

	farmem_type = alloc_memory_type(FARMEM_ADISTANCE);
	if (IS_ERR(farmem_type)) {
		pr_err("tierinit: failed to allocate memory type\n");
		return PTR_ERR(farmem_type);
	}

	do_clear_memory_tier(FARMEM_NUMA);
	clear_node_memory_type(FARMEM_NUMA, NULL);
	init_node_memory_type(FARMEM_NUMA, farmem_type);
	do_init_memory_tier(FARMEM_NUMA);

	top_adist = round_down((*k_default_dram_type)->adistance,
			       MEMTIER_CHUNK_SIZE) + MEMTIER_CHUNK_SIZE - 1;
	WRITE_ONCE(*k_top_tier_adistance, top_adist);

	pr_info("tierinit: demotion[%d]=%d, node %d toptier=%d\n", LOCAL_NUMA,
		k_next_demotion_node(LOCAL_NUMA, &node_states[N_MEMORY]),
		FARMEM_NUMA, k_node_is_toptier(FARMEM_NUMA));
	return 0;
}

static void __exit tierinit_exit(void)
{
	do_clear_memory_tier(FARMEM_NUMA);
	clear_node_memory_type(FARMEM_NUMA, farmem_type);
	do_init_memory_tier(FARMEM_NUMA);
	put_memory_type(farmem_type);
	pr_info("tierinit: unloaded (node %d toptier=%d)\n",
		FARMEM_NUMA, k_node_is_toptier(FARMEM_NUMA));
}

module_init(tierinit_init);
module_exit(tierinit_exit);
MODULE_AUTHOR("LowTier");
MODULE_DESCRIPTION("Initialize NUMA memory tiering for Linux 7.x AutoNUMA");
MODULE_LICENSE("GPL");
