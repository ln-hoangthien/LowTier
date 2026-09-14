CXX = g++-11
CXXFLAGS ?= -O3 -Wall -fPIC -g
LDFLAGS ?= -shared -ldl -lpthread -lnuma
TARGET_EXE_NAME ?= pr

all: hook.so hook_huge.so

hook.so: hook.cpp
	$(CXX) $(CXXFLAGS) hook.cpp -o hook.so $(LDFLAGS) -DHYBRIDTIER_REGULAR -DFAST_MEMORY_SIZE_GB=16 -DTARGET_EXE_NAME=\"$(TARGET_EXE_NAME)\"

hook_huge.so: hook.cpp
	$(CXX) $(CXXFLAGS) hook.cpp -o hook_huge.so $(LDFLAGS) -DHYBRIDTIER_HUGE -DFAST_MEMORY_SIZE_GB=16 -DTARGET_EXE_NAME=\"$(TARGET_EXE_NAME)\"

clean:
	rm -f hook.so hook_huge.so
