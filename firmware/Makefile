# Laptop-side build: unit tests and the simulator. The device build uses PlatformIO (see README).
CXX      ?= c++
CXXFLAGS ?= -std=c++11 -Wall -Wextra -O1 -g
CORE_DIR := lib/earshot_core/src
CORE_SRC := $(wildcard $(CORE_DIR)/*.cpp)
CORE_HDR := $(wildcard $(CORE_DIR)/*.h)
PYTHON   ?= python3

.PHONY: test sim run e2e clean

build/test_core: host_tests/test_core.cpp $(CORE_SRC) $(CORE_HDR)
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -I$(CORE_DIR) -o $@ host_tests/test_core.cpp $(CORE_SRC)

build/sim_clip: sim/sim_clip.cpp $(CORE_SRC) $(CORE_HDR)
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -I$(CORE_DIR) -o $@ sim/sim_clip.cpp $(CORE_SRC)

# Unit tests for the button, state machine, WebSocket client and consent gate.
test: build/test_core
	./build/test_core

sim: build/sim_clip

# Virtual clip + mock tablet in the browser at http://localhost:8765
run: sim
	$(PYTHON) sim/tablet.py

# Scripted end-to-end check: simulated clip against the mock tablet over a real socket.
e2e: sim
	$(PYTHON) sim/e2e_test.py

clean:
	rm -rf build
