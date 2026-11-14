# Laptop-side build: unit tests and the simulator. The device build uses PlatformIO (see README).
CXX      ?= c++
CXXFLAGS ?= -std=c++11 -Wall -Wextra -O1 -g
CORE_DIR := lib/earshot_core/src
CORE_SRC := $(wildcard $(CORE_DIR)/*.cpp)
CORE_HDR := $(wildcard $(CORE_DIR)/*.h)
# Opus: the same library the device build uses, compiled for the laptop. PlatformIO downloads
# it (`pio pkg install` or any `pio run`).
OPUS_DIR := .pio/libdeps/atom-voices3r/esp32_opus/src
OPUS_SRC := $(wildcard $(OPUS_DIR)/*.c)
OPUS_OBJ := $(patsubst $(OPUS_DIR)/%.c,build/opus/%.o,$(OPUS_SRC))
OPUS_WRAP := lib/earshot_opus/src
# The voice recording the firmware can play in place of a microphone (tools/make_voice_clip.py).
VOICE_DIR := lib/earshot_voice/src

# Tools that decode audio (the mock tablet's playback, the recorder) need PyAV. If the test
# environment exists it has it; otherwise plain python3 is used and playback is unavailable.
PYTHON   ?= $(shell [ -x build/codec-test-venv/bin/python ] && echo build/codec-test-venv/bin/python || echo python3)

.PHONY: test sim run e2e clean

build/voice_clip_data.o: $(VOICE_DIR)/voice_clip_data.c $(VOICE_DIR)/voice_clip_data.h
	@mkdir -p build
	@$(CC) -O1 -I$(VOICE_DIR) -c -o $@ $<

build/test_core: host_tests/test_core.cpp $(CORE_SRC) $(CORE_HDR) build/voice_clip_data.o
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -I$(CORE_DIR) -I$(VOICE_DIR) -o $@ host_tests/test_core.cpp $(CORE_SRC) build/voice_clip_data.o

build/opus/%.o: $(OPUS_DIR)/%.c
	@mkdir -p build/opus
	@$(CC) -O2 -w -I$(OPUS_DIR) -c -o $@ $<

build/libopus_host.a: $(OPUS_OBJ)
	@test -n "$(OPUS_SRC)" || (echo "Opus sources not found. Run: pio pkg install -e atom-voices3r" && false)
	@rm -f $@ && ar rcs $@ $(OPUS_OBJ)
	@echo "built $@ from $(words $(OPUS_OBJ)) Opus source files"

build/sim_clip: sim/sim_clip.cpp $(CORE_SRC) $(CORE_HDR) $(OPUS_WRAP)/opus_audio_encoder.cpp $(OPUS_WRAP)/opus_audio_encoder.h build/libopus_host.a build/voice_clip_data.o
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -I$(CORE_DIR) -I$(OPUS_WRAP) -I$(OPUS_DIR) -I$(VOICE_DIR) -o $@ sim/sim_clip.cpp $(CORE_SRC) \
	    $(OPUS_WRAP)/opus_audio_encoder.cpp build/libopus_host.a build/voice_clip_data.o

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
