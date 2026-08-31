VERILATOR ?= verilator
VFLAGS = --binary --timing -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY
TEST_OBJ = obj_dir/tests
VCO_FIXTURE ?= tmp/mame-vco-35.hex
PALETTE_FIXTURE ?= tmp/mame-palette-35.hex
ROM_IMAGE ?= roms/topland.rom
MAIN_CYCLES ?= 1200000000
MAIN_GAMEPLAY_CYCLES ?= 1200000000
AUDIO_CAPTURE_CYCLES ?= 96000000
AUDIO_CAPTURE_PREFIX ?= tmp/topland-game-audio
AUDIO_DIAGNOSTIC_PREFIX ?= tmp/topland-rom-audio-diagnostic
AUDIO_MAIN_TRACE ?= tmp/topland-main-sound.log

.PHONY: test test-unit test-tc0140syt test-ddr-rom test-video \
	test-video-sprite-window test-vco-ram \
	test-polygon test-muldiv test-c25-ops test-cadence-telemetry \
	test-audio-line-cache test-flight-controls test-throttle-overlay \
	test-dip-switches test-download-control test-ascal-linf-ram \
	test-dsp-program test-video-budget \
	test-telemetry-tools \
	test-sound test-rom \
	test-main test-main-input-trace test-main-gameplay-trace trace-main-audio test-captures capture-audio \
	capture-rom-audio-diagnostic

test: test-unit

test-unit: test-tc0140syt test-ddr-rom test-video test-video-sprite-window \
	test-vco-ram test-polygon \
	test-muldiv test-c25-ops test-cadence-telemetry test-audio-line-cache \
	test-flight-controls test-throttle-overlay test-dip-switches \
	test-download-control test-ascal-linf-ram test-dsp-program \
	test-telemetry-tools

test-telemetry-tools:
	@python3 tools/summarize_hardware_telemetry.py \
		tests/fixtures/telemetry-18-word.log >tmp/test-telemetry-18-word.out
	@grep -q "polygon_hold_max_clocks=60" tmp/test-telemetry-18-word.out
	@grep -q "polygon_hold_max_us=1.875" tmp/test-telemetry-18-word.out
	@grep -q "cpu_blocked_last=30" tmp/test-telemetry-18-word.out
	@grep -q "cpu_unsafe_cache_hits_last=5" tmp/test-telemetry-18-word.out
	@python3 -m py_compile tools/summarize_hardware_telemetry.py \
		tools/summarize_quartus_reports.py
	@python3 tests/test_summarize_quartus_reports.py
	@echo "PASS telemetry/report tools"

$(TEST_OBJ)/ascal_linf_ram/Vtb_ascal_linf_ram: tests/tb_ascal_linf_ram.sv sys/ascal_linf_ram.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_ascal_linf_ram \
		--Mdir $(TEST_OBJ)/ascal_linf_ram $^

test-ascal-linf-ram: $(TEST_OBJ)/ascal_linf_ram/Vtb_ascal_linf_ram
	$<

$(TEST_OBJ)/dsp_program/Vtb_dsp_program: tests/tb_dsp_program.sv rtl/tas_dsp_program.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_dsp_program \
		--Mdir $(TEST_OBJ)/dsp_program $^

test-dsp-program: $(TEST_OBJ)/dsp_program/Vtb_dsp_program
	$<

$(TEST_OBJ)/download_control/Vtb_download_control: tests/tb_download_control.sv rtl/tas_download_control.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_download_control \
		--Mdir $(TEST_OBJ)/download_control $^

test-download-control: $(TEST_OBJ)/download_control/Vtb_download_control
	$<

$(TEST_OBJ)/dip_switches/Vtb_dip_switches: tests/tb_dip_switches.sv rtl/tas_dip_switches.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_dip_switches \
		--Mdir $(TEST_OBJ)/dip_switches $^

test-dip-switches: $(TEST_OBJ)/dip_switches/Vtb_dip_switches
	$<

JT10_SOURCES = $(wildcard rtl/third_party/jt12/hdl/*.v) \
	$(wildcard rtl/third_party/jt12/hdl/mixer/*.v) \
	$(wildcard rtl/third_party/jt12/hdl/adpcm/*.v) \
	$(wildcard rtl/third_party/jt12/jt49/hdl/*.v)
TV80_SOURCES = rtl/third_party/tv80/tv80s.v \
	rtl/third_party/tv80/tv80_alu.v rtl/third_party/tv80/tv80_reg.v \
	rtl/third_party/tv80/tv80_core.v rtl/third_party/tv80/tv80_mcode.v

$(TEST_OBJ)/sound/Vtb_sound: tests/tb_sound.sv rtl/tas_sound.sv \
	rtl/tas_audio_line_cache.sv \
	rtl/tas_tc0140syt.sv $(TV80_SOURCES) $(JT10_SOURCES)
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_sound --Mdir $(TEST_OBJ)/sound $^

test-sound: $(TEST_OBJ)/sound/Vtb_sound
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	$< +ROM=$(ROM_IMAGE) +SAMPLE_DELAY=3
	$< +ROM=$(ROM_IMAGE) +SAMPLE_DELAY=24
	$< +ROM=$(ROM_IMAGE) +SAMPLE_DELAY=72

capture-audio: $(TEST_OBJ)/sound/Vtb_sound
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	test -s "$(AUDIO_MAIN_TRACE)" || { echo "missing main sound trace: $(AUDIO_MAIN_TRACE) (run make trace-main-audio first)" >&2; exit 1; }
	mkdir -p $(dir $(AUDIO_CAPTURE_PREFIX))
	$< +ROM=$(ROM_IMAGE) +SAMPLE_DELAY=24 \
		+MAIN_TRACE=$(AUDIO_MAIN_TRACE) \
		+CAPTURE_CYCLES=$(AUDIO_CAPTURE_CYCLES) \
		+PCM=$(AUDIO_CAPTURE_PREFIX).s16le \
		+YM_LOG=$(AUDIO_CAPTURE_PREFIX)-ym.log
	python3 tools/raw_pcm_to_wav.py --require-audio \
		$(AUDIO_CAPTURE_PREFIX).s16le $(AUDIO_CAPTURE_PREFIX).wav
	python3 tools/summarize_ym_trace.py --require-key-on --require-audio-route \
		$(AUDIO_CAPTURE_PREFIX)-ym.log

capture-rom-audio-diagnostic: $(TEST_OBJ)/sound/Vtb_sound
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	mkdir -p $(dir $(AUDIO_DIAGNOSTIC_PREFIX))
	$< +ROM=$(ROM_IMAGE) +SAMPLE_DELAY=24 +ROM_AUDIO_ONLY \
		+CAPTURE_CYCLES=$(AUDIO_CAPTURE_CYCLES) \
		+PCM=$(AUDIO_DIAGNOSTIC_PREFIX).s16le \
		+YM_LOG=$(AUDIO_DIAGNOSTIC_PREFIX)-ym.log
	python3 tools/raw_pcm_to_wav.py \
		$(AUDIO_DIAGNOSTIC_PREFIX).s16le $(AUDIO_DIAGNOSTIC_PREFIX).wav
	python3 tools/summarize_ym_trace.py $(AUDIO_DIAGNOSTIC_PREFIX)-ym.log

$(TEST_OBJ)/cadence_telemetry/Vtb_cadence_telemetry: tests/tb_cadence_telemetry.sv rtl/tas_cadence_telemetry.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_cadence_telemetry \
		--Mdir $(TEST_OBJ)/cadence_telemetry $^

test-cadence-telemetry: $(TEST_OBJ)/cadence_telemetry/Vtb_cadence_telemetry
	$<

$(TEST_OBJ)/audio_line_cache/Vtb_audio_line_cache: tests/tb_audio_line_cache.sv rtl/tas_audio_line_cache.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_audio_line_cache \
		--Mdir $(TEST_OBJ)/audio_line_cache $^

test-audio-line-cache: $(TEST_OBJ)/audio_line_cache/Vtb_audio_line_cache
	$<
	@mkdir -p tmp
	@ulimit -c 0; if $< +DUPLICATE_FILL >tmp/test-audio-duplicate-fill.log 2>&1; then \
		echo "duplicate audio-cache fill unexpectedly passed" >&2; exit 1; \
	fi
	@grep -q "duplicate audio-cache fill tag=" tmp/test-audio-duplicate-fill.log || { \
		cat tmp/test-audio-duplicate-fill.log >&2; \
		echo "duplicate fill failed for the wrong reason" >&2; exit 1; \
	}
	@echo "PASS tb_audio_line_cache duplicate-fill contract"

$(TEST_OBJ)/flight_controls/Vtb_flight_controls: tests/tb_flight_controls.sv rtl/tas_flight_controls.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_flight_controls \
		--Mdir $(TEST_OBJ)/flight_controls $^

test-flight-controls: $(TEST_OBJ)/flight_controls/Vtb_flight_controls
	$<

$(TEST_OBJ)/throttle_overlay/Vtb_throttle_overlay: tests/tb_throttle_overlay.sv rtl/tas_throttle_overlay.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_throttle_overlay \
		--Mdir $(TEST_OBJ)/throttle_overlay $^

test-throttle-overlay: $(TEST_OBJ)/throttle_overlay/Vtb_throttle_overlay
	$<

$(TEST_OBJ)/tc0140syt/Vtb_tc0140syt: tests/tb_tc0140syt.sv rtl/tas_tc0140syt.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_tc0140syt --Mdir $(TEST_OBJ)/tc0140syt $^

test-tc0140syt: $(TEST_OBJ)/tc0140syt/Vtb_tc0140syt
	$<

$(TEST_OBJ)/ddr_rom/Vtb_ddr_rom: tests/tb_ddr_rom.sv rtl/tas_ddr_rom.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_ddr_rom --Mdir $(TEST_OBJ)/ddr_rom $^

test-ddr-rom: $(TEST_OBJ)/ddr_rom/Vtb_ddr_rom
	$<

$(TEST_OBJ)/video/Vtb_video: tests/tb_video.sv rtl/tas_video.sv \
	rtl/tas_throttle_overlay.sv rtl/tas_polygon.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_video --Mdir $(TEST_OBJ)/video $^

test-video: $(TEST_OBJ)/video/Vtb_video
	$<

$(TEST_OBJ)/video_frame/Vtb_video_frame: tests/tb_video_frame.sv \
	rtl/tas_video.sv rtl/tas_throttle_overlay.sv \
	rtl/tas_polygon.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_video_frame \
		--Mdir $(TEST_OBJ)/video_frame $^

$(TEST_OBJ)/video_sprite_window/Vtb_video_sprite_window: \
	tests/tb_video_sprite_window.sv \
	rtl/tas_video.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_video_sprite_window \
		--Mdir $(TEST_OBJ)/video_sprite_window $^

test-video-sprite-window: $(TEST_OBJ)/video_sprite_window/Vtb_video_sprite_window
	$<

$(TEST_OBJ)/vco_ram/Vtb_vco_ram: tests/tb_vco_ram.sv rtl/tas_vco_ram.sv rtl/tas_ram.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_vco_ram --Mdir $(TEST_OBJ)/vco_ram $^

test-vco-ram: $(TEST_OBJ)/vco_ram/Vtb_vco_ram
	$<

$(TEST_OBJ)/polygon/Vtb_tas_polygon: tests/tb_tas_polygon.sv rtl/tas_polygon.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_tas_polygon --Mdir $(TEST_OBJ)/polygon $^

test-polygon: $(TEST_OBJ)/polygon/Vtb_tas_polygon
	$<
	$< +FULL_WIDTH_PAINT
	$< +BANK_SWAP_RACE
	$< +FRAME_ATOMIC_PUBLISH
	$< +DMA_COMMANDS
	$< +CAPACITY_RECLAIM
	$< +OCCLUSION_RECLAIM
	$< +CROSSING_EDGES
	$< +LIST_MARKERS

$(TEST_OBJ)/muldiv/Vtb_muldiv: tests/tb_muldiv.sv sys/math.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_muldiv --Mdir $(TEST_OBJ)/muldiv $^

test-muldiv: $(TEST_OBJ)/muldiv/Vtb_muldiv
	$<

$(TEST_OBJ)/c25_ops/Vtb_tms320c25_ops: tests/tb_tms320c25_ops.sv rtl/cpu/tms320c25/tas_tms320c25.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_tms320c25_ops \
		--Mdir $(TEST_OBJ)/c25_ops $^

test-c25-ops: $(TEST_OBJ)/c25_ops/Vtb_tms320c25_ops
	$<

$(TEST_OBJ)/c25_boot/Vtb_tms320c25_boot: tests/tb_tms320c25_boot.sv rtl/cpu/tms320c25/tas_tms320c25.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_tms320c25_boot --Mdir $(TEST_OBJ)/c25_boot $^

$(TEST_OBJ)/dsp_boot/Vtb_tas_dsp_boot: tests/tb_tas_dsp_boot.sv rtl/cpu/tms320c25/tas_tms320c25.sv rtl/tas_dsp.sv rtl/tas_ram.sv sys/math.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_tas_dsp_boot --Mdir $(TEST_OBJ)/dsp_boot $^

test-rom: $(TEST_OBJ)/c25_boot/Vtb_tms320c25_boot \
	$(TEST_OBJ)/dsp_boot/Vtb_tas_dsp_boot $(TEST_OBJ)/sound/Vtb_sound
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	$(TEST_OBJ)/c25_boot/Vtb_tms320c25_boot +ROM=$(ROM_IMAGE)
	$(TEST_OBJ)/dsp_boot/Vtb_tas_dsp_boot +ROM=$(ROM_IMAGE)
	$(TEST_OBJ)/sound/Vtb_sound +ROM=$(ROM_IMAGE) +SAMPLE_DELAY=3
	$(TEST_OBJ)/sound/Vtb_sound +ROM=$(ROM_IMAGE) +SAMPLE_DELAY=24
	$(TEST_OBJ)/sound/Vtb_sound +ROM=$(ROM_IMAGE) +SAMPLE_DELAY=72

MAIN_SOURCES = tests/tb_main.sv \
	rtl/cpu/fx68k/uaddrPla.sv rtl/cpu/fx68k/fx68kAlu.sv \
	rtl/cpu/fx68k/fx68k.sv rtl/cpu/tms320c25/tas_tms320c25.sv \
	rtl/tas_vco_ram.sv rtl/tas_dsp.sv rtl/tas_tc0140syt.sv \
	rtl/tas_sound_boot_stub.sv rtl/tas_flight_controls.sv \
	rtl/tas_main.sv rtl/tas_polygon.sv \
	rtl/tas_ram.sv sys/math.sv

$(TEST_OBJ)/main/Vtb_main: $(MAIN_SOURCES)
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --noassert -Wno-UNSIGNED -Wno-CMPCONST \
		-Wno-BLKANDNBLK -CFLAGS -O3 -Irtl/cpu/fx68k --top-module tb_main \
		--Mdir $(TEST_OBJ)/main $(MAIN_SOURCES)

test-main: $(TEST_OBJ)/main/Vtb_main
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	cd rtl/cpu/fx68k && $(abspath $<) \
		+ROM=$(abspath $(ROM_IMAGE)) +ROM_DELAY=1 +CYCLES=$(MAIN_CYCLES)

test-main-input-trace: $(TEST_OBJ)/main/Vtb_main
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	cd rtl/cpu/fx68k && $(abspath $<) \
		+ROM=$(abspath $(ROM_IMAGE)) +ROM_DELAY=1 +CYCLES=1000000 \
		+INPUT_TRACE=$(abspath tests/fixtures/main-input-smoke.trace)

test-main-gameplay-trace: $(TEST_OBJ)/main/Vtb_main
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	cd rtl/cpu/fx68k && $(abspath $<) \
		+ROM=$(abspath $(ROM_IMAGE)) +ROM_DELAY=1 \
		+CYCLES=$(MAIN_GAMEPLAY_CYCLES) \
		+INPUT_TRACE=$(abspath tests/fixtures/main-gameplay.trace)

trace-main-audio: $(TEST_OBJ)/main/Vtb_main
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	mkdir -p $(dir $(AUDIO_MAIN_TRACE))
	cd rtl/cpu/fx68k && $(abspath $<) \
		+ROM=$(abspath $(ROM_IMAGE)) +ROM_DELAY=1 +CYCLES=$(MAIN_CYCLES) \
		+SOUND_LOG=$(abspath $(AUDIO_MAIN_TRACE))
	python3 tools/summarize_main_sound_trace.py $(AUDIO_MAIN_TRACE)

$(TEST_OBJ)/video_budget/Vtb_video_budget: tests/tb_video_budget.sv \
	rtl/tas_video.sv rtl/tas_throttle_overlay.sv rtl/tas_polygon.sv \
	rtl/tas_ddr_rom.sv
	mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) --top-module tb_video_budget --Mdir $(TEST_OBJ)/video_budget $^

test-video-budget: $(TEST_OBJ)/video_budget/Vtb_video_budget
	test -r "$(VCO_FIXTURE)" || { echo "missing required VCO fixture: $(VCO_FIXTURE)" >&2; exit 1; }
	$< +VCO=$(VCO_FIXTURE) +GFX_DELAY=12

test-captures: $(TEST_OBJ)/video_budget/Vtb_video_budget \
	$(TEST_OBJ)/video_frame/Vtb_video_frame
	test -r "$(VCO_FIXTURE)" || { echo "missing required VCO fixture: $(VCO_FIXTURE)" >&2; exit 1; }
	test -r "$(PALETTE_FIXTURE)" || { echo "missing required palette fixture: $(PALETTE_FIXTURE)" >&2; exit 1; }
	test -r "$(ROM_IMAGE)" || { echo "missing required ROM image: $(ROM_IMAGE)" >&2; exit 1; }
	# Delay 12 makes the former two-bank renderer drop 16 lines in this
	# captured dense-dashboard scene; the four-bank queue must absorb it.
	$< +VCO=$(VCO_FIXTURE) +GFX_DELAY=12
	# Eight-line sound bursts at a rate far above measured gameplay exercise
	# cache-hit concurrency without modeling an impossible permanent miss.
	$< +VCO=$(VCO_FIXTURE) +GFX_DELAY=12 +BACKGROUND_STRESS=1
	# A paced requester checks low ADPCM latency above the game's measured load.
	$< +VCO=$(VCO_FIXTURE) +GFX_DELAY=12 +BACKGROUND_STRESS=2
	$(TEST_OBJ)/video_frame/Vtb_video_frame +VCO=$(VCO_FIXTURE) \
		+PALETTE=$(PALETTE_FIXTURE) +ROM=$(ROM_IMAGE) \
		+OUTPUT=tmp/test-cloud-window.ppm +NO_BG0 +NO_BG1 \
		+SPRITE_FIRST=68 +SPRITE_LAST=94 +EXPECT_CLOUD_WINDOW \
		+EXPECT_TOPLAND_NO_COCKPIT
	$(TEST_OBJ)/video_frame/Vtb_video_frame +VCO=$(VCO_FIXTURE) \
		+PALETTE=$(PALETTE_FIXTURE) +ROM=$(ROM_IMAGE) \
		+OUTPUT=tmp/test-noncloud-cockpit.ppm +NO_BG0 +NO_BG1 \
		+SPRITE_FIRST=41 +SPRITE_LAST=42 +EXPECT_NONCLOUD_BELOW
	# Relocate Top Landing's internally wrapped BG0 palette-$00d mask to the
	# true left edge while proving that BG1 panel/menu content overwrites it.
	$(TEST_OBJ)/video_frame/Vtb_video_frame +VCO=$(VCO_FIXTURE) \
		+PALETTE=$(PALETTE_FIXTURE) +ROM=$(ROM_IMAGE) \
		+OUTPUT=tmp/test-left-edge.ppm +NO_SPRITES \
		+EXPECT_TOPLAND_BG0_EDGE_MASK
