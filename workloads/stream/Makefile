NUM_CORES ?= $(shell nproc)
RESERVED_CORES ?= 2
WORKLOAD_CORES ?= $(shell expr $$(nproc) - $(RESERVED_CORES))
ifeq ($(shell test $(WORKLOAD_CORES) -le 0; echo $$?),0)
    WORKLOAD_CORES := $(NUM_CORES)
endif

# High memory footprint: 800M elements * 8 bytes * 3 arrays = 19.2 GB memory footprint
STREAM_ARRAY_SIZE ?= 800000000ULL
NTIMES ?= 40

CC = gcc
CFLAGS = -O3 -fopenmp -mcmodel=medium -DSTREAM_ARRAY_SIZE=$(STREAM_ARRAY_SIZE) -DNTIMES=$(NTIMES) -DNUM_THREADS=$(WORKLOAD_CORES)

FC = gfortran
FFLAGS = -O3 -fopenmp -mcmodel=medium -DSTREAM_ARRAY_SIZE=$(STREAM_ARRAY_SIZE) -DNTIMES=$(NTIMES)

TARGETS = stream stream_hot stream_phases stream_c.exe

all: $(TARGETS)

stream: stream.c
	$(CC) $(CFLAGS) stream.c -o stream

stream_hot: stream_hot.c
	$(CC) -O3 -fopenmp -mcmodel=medium -DNUM_THREADS=$(WORKLOAD_CORES) stream_hot.c -o stream_hot

stream_phases: stream_phases.c
	$(CC) -O3 -fopenmp -mcmodel=medium -DNUM_THREADS=$(WORKLOAD_CORES) stream_phases.c -o stream_phases

stream_c.exe: stream.c
	$(CC) $(CFLAGS) stream.c -o stream_c.exe

stream_f.exe: stream.f mysecond.o
	@if command -v $(FC) >/dev/null 2>&1; then \
		$(CC) $(CFLAGS) -c mysecond.c; \
		$(FC) $(FFLAGS) -c stream.f; \
		$(FC) $(FFLAGS) stream.o mysecond.o -o stream_f.exe; \
	else \
		echo "Notice: gfortran not found, skipping Fortran build (stream_f.exe)"; \
	fi

clean:
	rm -f $(TARGETS) stream_f.exe *.o
