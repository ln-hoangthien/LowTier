/*
 * kswapdrst - Periodically reset kswapd's per-node failure counter so the
 * reclaim/demotion daemon does not permanently back off under sustained
 * tiering pressure.
 *
 * Derived from the Colloid memory-tiering artifact:
 *   "Tiered Memory Management: Access Latency is the Key!"
 */


#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/delay.h>
#include <linux/workqueue.h>

#define LOCAL_NUMA	0
#define CORE		8
#define INTERVAL_MS	5000

static void kswapd_reset_fn(struct work_struct *work);

static struct workqueue_struct *wq;
static DECLARE_DELAYED_WORK(reset_work, kswapd_reset_fn);
static int terminate;

static void kswapd_reset_fn(struct work_struct *work)
{
	struct pglist_data *pgdat = NODE_DATA(LOCAL_NUMA);

	WRITE_ONCE(pgdat->kswapd_failures, 0);

	if (!READ_ONCE(terminate))
		queue_delayed_work_on(CORE, wq, &reset_work,
				      msecs_to_jiffies(INTERVAL_MS));
}

static int __init kswapdrst_init(void)
{
	struct pglist_data *pgdat = NODE_DATA(LOCAL_NUMA);

	pr_info("kswapdrst: kswapd_failures=%d\n", pgdat->kswapd_failures);

	wq = alloc_workqueue("kswapdrst", WQ_HIGHPRI | WQ_CPU_INTENSIVE, 0);
	if (!wq)
		return -ENOMEM;

	WRITE_ONCE(terminate, 0);
	queue_delayed_work_on(CORE, wq, &reset_work,
			      msecs_to_jiffies(INTERVAL_MS));
	return 0;
}

static void __exit kswapdrst_exit(void)
{
	WRITE_ONCE(terminate, 1);
	msleep(INTERVAL_MS);
	flush_workqueue(wq);
	destroy_workqueue(wq);
	pr_info("kswapdrst: unloaded\n");
}

module_init(kswapdrst_init);
module_exit(kswapdrst_exit);
MODULE_AUTHOR("Colloid");
MODULE_DESCRIPTION("Periodic kswapd failure counter reset");
MODULE_LICENSE("GPL");
