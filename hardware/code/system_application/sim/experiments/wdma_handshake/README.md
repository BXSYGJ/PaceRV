# Isolated WDMA handshake experiment

These are experimental snapshots, not the production `src/npu/wdma.v`.
Do not add both RTL snapshots to the same elaboration: each defines `wdma`.
No production runner suite is changed by this experiment.

Run from `instrec_fpga/`:

```powershell
python sim/experiments/wdma_handshake/run.py fixed
python sim/experiments/wdma_handshake/run.py baseline
```

`fixed` must pass. `baseline` is deliberately expected to fail and return 1;
it reproduces the registered-output handshake defect. Both commands build
their own case directories beneath `build/sim/`. The runner generates a
temporary byte hex from tracked `scripts/outputs/weights_image.bin`; no weight
hex is copied into this experiment. Existing shared runtime is not cleared.

`wdma_step6_baseline.v` is the prior build step6 candidate, not pristine
mainline. It already includes per-DDR-beat bias/M/shift parameter indexing,
shift RAM address correction, channel group stride 16, last partial-beat tap
completion, earlier `grp_start`, and the parameter read `S_PRIME` state.

`wdma_fixed.v` adds only the weight output handshake correction to step6:
derive `w_valid` and `w_data` combinationally from the current FIFO pointer,
sub-tap and emitting state. Keep pointer advancement synchronous and gated by
the actual valid/ready transfer. This makes a stalled tap stay current and
ensures that the next tap is presented immediately after acceptance. The old
version registered the old pointer's data while advancing on the current
ready signal, allowing the previous tap to be accepted twice after a stall.

The test compares every accepted word against the real weight image. It
forces 40 cycles of backpressure before the first tap of every group, then
uses deterministic random ready (xorshift32 seed `0x89171ab5`). Coverage:

- conv1: 7 groups x 9 taps; half-beat odd groups and row rollover.
- conv2: 3 groups x 432 taps; multiple DDR bursts.
- conv4: 2 groups x 1728 taps; deepest active group.
- fc2: 1 group x 128 taps; 8-byte taps with zero upper 64 bits.

The build-only precursor produced **4943 comparisons, zero mismatch** for
the fixed candidate. The step6 baseline failed at layer 0, group 0, tap 1
(repeated tap 0). See `reports/wdma_handshake_validation_20261101.md` for
archived result text. This test does not check parameter value correctness,
full NPU correctness, synthesis timing, RAM mapping or board operation.
