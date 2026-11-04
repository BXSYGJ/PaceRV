# Experimental NPU lifecycle and activation DDR map

No mainline/PDS edits. Run from instrec_fpga:

    python sim/experiments/npu_lifecycle/run_gap.py
    python sim/experiments/npu_lifecycle/run_pool.py
    python sim/experiments/npu_lifecycle/run_regions.py

## GAP repeated inference: reproduced blocker

The real original gap_unit accumulates the first pool4 frame from reset S_ACC. A gap_start only after pool4 is late: in S_CONV it does nothing; after completing first results it stays S_DONE. It ignores the entire next input frame until that frame's late gap_start. The two-frame TB drives full16384-byte frames of31 then79: original/late-arm produces256 outputs and1 done; candidate/early-arm produces512 exact outputs and2 done. This is a real RTL counterexample of the current producer/start relationship, without forced completion.

Minimal top wiring: arm GAP on conv4_start before any p4 input. Do not re-arm on the subsequent GAP wait state. Latch gap_done until consumed or the next inference/conv4 begins. Candidate gap_unit.v also makes layer_start a priority restart from every state, clearing coordinates and conversion index. This makes aborted/restarted partial frames deterministic; complete-frame early-arm is the essential top fix.

## Pool reset and completion

Arm the shared pool on each producing conv_start, not in the subsequent POOL wait state. Only reset when the old pool FIFO is drained; never reset a live output pipeline. Capture accepted last (p_valid && p_ready && p_last) into the producing stage's sticky bit. Clear only on the next inference or the next start of that producer. Layer_finished for POOLn reads that sticky bit. npu_stage_lifecycle.v supplies pool_arm, gap_arm and sticky completion state.

The pool lifecycle TB uses real pooling, backpressure and two exact128-byte frames; it demonstrates raw p_last is cleared by a late reset while sticky completion survives. It does not claim a complete original npu_top pool state timeout was reproduced: exact sequencer/settle ordering can consume the old sticky pool indication before reset. The helper removes that timing dependence and is necessary with a handshake p_last FIFO token.

Direct integration sketch:

- conv_start={conv4_start,conv3_start,conv2_start,conv1_start}.
- shared pool.layer_start=|pool_arm.
- gap.layer_start=gap_arm; remove old gap_start connection to the unit.
- pool_last_accepted[n]=pool_p_valid && pool_p_ready && pool_p_last && pool_seln.
- layer_finished at L_POOLn uses pool_complete[n]; at L_GAP uses gap_complete.
- Preserve layer selection until accepted output last; producer done is already delayed by conv FIFO drain.

## Authoritative map and new scratch proposal

Authority: docs/sdd/design.md559-563 and src/ddr3/ddr3_arbiter.v127-143. Existing windows, inclusive byte ranges:

| Owner | Start | End |
|---|---|---|
| PCM left | 0x000000 | 0x083fff |
| PCM right archive | 0x084000 | 0x0c5fff |
| Weights | 0x100000 | 0x1b7fff |
| Spectrum snapshot | 0x200000 | 0x20ffff |
| Self-test | 0x300000 | 0x30ffff |

Using0x200000 for pool1 corrupts the spectrum area and extends to0x2307ff, beyond its original64KiB region. No original window is spare scratch space of the required capacity. The following are NEW experimental allocations, requiring the design memory map and arbiter whitelist to be adopted together; they are not already-authorized original regions.

| Scratch | Reserved inclusive range | Actual stored frame range |
|---|---|---|
| A,256KiB | 0x400000..0x43ffff | pool1 0x400000..0x4307ff (198656 padded bytes); pool3 0x400000..0x40bfff (49152 bytes) |
| B,128KiB | 0x440000..0x45ffff | pool2 0x440000..0x457fff (98304 bytes) |

A/B are mutually disjoint and above all five original windows. A is reused for pool3 only after conv2 has fully consumed pool1; B contains pool2 while conv3 emits pool3. RAM row dimensions do not replace full-frame DDR ownership/lifetime tracking.

Candidate ddr3_arbiter.v adds those regions ONLY for m1, len0, aligned addresses up to region_end-31; all original window behavior is preserved. Region TB passes17 cases including first/last legal beats, padding area, wrong master, unaligned address, multi-beat activation command and original spectrum/weight/audio regions.

Important existing behavior: arbiter addr_err is diagnostic only; illegal commands are NOT blocked. A whitelist error can coexist with actual memory traffic. Models that ignore addr_err can therefore hide an invalid board integration. This candidate intentionally preserves the existing diagnostic contract; runtime address protection is a separate change.

No native-controller integration, synthesis or board result is claimed by these unit tests.
