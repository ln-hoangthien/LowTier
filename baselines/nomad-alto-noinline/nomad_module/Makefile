# KERNEL_SRC must point at the linux-5.13-rc6 source tree that the running
# kernel was built from (it provides the private mm/internal.h header).
# Override on the command line, e.g.:
#   make KERNEL_SRC=/path/to/linux-5.13-rc6
KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build

obj-m += async_promote.o
async_promote-objs := async_promote_main.o buffer_ring.o

# Add the kernel tree to the header search path so `#include "mm/internal.h"`
# resolves without an absolute path baked into the source.
ccflags-y += -I$(KERNEL_SRC)

all:
	make -C $(KERNEL_SRC) M=$(PWD) modules
clean:
	make -C $(KERNEL_SRC) M=$(PWD) clean