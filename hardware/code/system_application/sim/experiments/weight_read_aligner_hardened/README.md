# Hardened native weight read adapter candidate

Run from `instrec_fpga/`:

```powershell
python sim/experiments/weight_read_aligner_hardened/run.py
python sim/experiments/weight_read_aligner_hardened/run_full_native.py
python sim/experiments/weight_read_aligner_hardened/run_repeat_native.py
python sim/experiments/weight_read_aligner_hardened/run_fc_epoch.py
```

Production WDMA commands contain byte offsets into the weight image, not
native DDR addresses. Conv1 bias/M/shift offsets 944/1136/1328 are 16-byte
aligned, whereas native commands require 32-byte alignment. Adding a base
alone does not repair this. Conv1 group stride is 144 bytes, not 432 bytes
(432 is its entire three-group weight payload).

This candidate adds `0x100000`, aligns down, reads one extra beat for a
nonzero offset, splits 17 physical beats into 16+1 native commands, buffers
the entire request, then reconstructs the original byte stream. It accepts
read commands only, lengths 1..16 beats (`cmd[7:4]` must be zero), and requests
whose entire requested byte span fits in image offsets `[0,0xb8000)`.
Invalid write/length/region commands cause no native traffic and latch a fault.

`dn_abort` must include the native transaction timeout and sticky master-1
address error. It suppresses success/valid immediately and puts an active
request into sticky FAULT. `transaction_failed` pulses once; `protocol_error`
remains set and no new request is accepted until reset. A missing or truncated
read without an abort can wait indefinitely; the native controller timeout
must remain connected. Data accepted before a later fault cannot be undone;
the upper inference must treat the sticky error as invalidating its result.

This is not an interface-identical replacement: use module name
`weight_read_aligner_hardened`, add `up_rd_ready`, `dn_abort`, `protocol_error`
and `transaction_failed`. Existing production WDMA cannot backpressure reads,
so tie `up_rd_ready` to 1. The independent TB additionally exercises output
stall stability. All clocks are the existing core domain; no CDC is added.
The legacy experimental aligner and its baseline runners remain unchanged.

Directed regression passes zero/16-byte offsets, 16+1 split, first/last legal
addresses, region overflow, invalid write/length, early native completion,
upstream stalls, in-flight abort and abort after a full request was buffered.
The separate full-native wrapper uses the existing golden fixture and changes
only the aligner instance and its failure wires. All conv/pool/GAP/FC/softmax
checks pass with natural done at 31,115,245 cycles (2026-11-01).
Evidence: `build/sim/weight_read_aligner_hardened/run.log` and
`build/sim/npu_full_native_hardened/run.log`. No PDS or board claim is made;
the 17x256 buffer and variable byte-selection mux require resource/timing
assessment before production adoption.

Repeated inference uncovered a separate FC lifecycle bug. The first complete
inference passed, but the original second inference produced FC2[0]=29
instead of 202. Both FC engines saw the shared weight valid without a layer
qualifier, and FC parameter counts remained complete after S_DONE. Thus FC2
could use a previous parameter epoch to leave S_C before its own next start.
Layer-valid gating alone still failed (FC2[0]=6), so it is not a valid fix.

The repeated candidate contains both changes: `npu_top_repeat_candidate.v`
qualifies FC1/FC2 weight valid with the selected layer, while
`fc_engine_repeat_candidate.v` clears b/m/s counts at S_DONE to retire the
completed parameter epoch. Input preload before the next layer_start remains
supported, but S_C must wait for the new independent parameter streams.
The shared wbuf ready already selects only the current layer through
conv_wready_mux; inactive FC ready cannot drain weights. This supports a
normal completed inference followed by start; abort/restart midway through
an FC layer is not claimed.

`run_repeat_native.py` uses those independent copies, preserves the original
single-run sources, resets only TB counters between starts, and checks all
golden values/counts, fresh busy/cycle count, idle completion, inactive FC
weight isolation and complete current FC contracts before each MAC.
Both runs PASS at 31,115,245 cycles each (2026-11-01); simulation wall time
113.681 seconds. Per run: conv outputs 792576/396288/196608/65536, pool
outputs 198144/98304/49152/16384, GAP 256, FC1 128, FC2 16 padded lanes
(first eight semantic logits), and eight probabilities.

`run_fc_epoch.py` separately preloads inputs before start for two rounds,
delays bias/M/shift independently, changes the second-round bias, asserts
ready remains low until all parameters arrive, and checks all 16 outputs.
The fix passes. `run_fc_epoch.py --baseline` deliberately selects the old
FC and fails in frame 1: stale/incomplete parameters armed MAC. This is an
expected regression-demonstration failure, not a passing command.

Evidence is in `build/sim/npu_repeat_native_hardened/run.log`, with the
original and gate-only failures preserved beside it as
`second_fc2_mismatch_original.log` and `second_fc2_gate_only_mismatch.log`.
Short-test logs are `build/sim/fc_parameter_epoch/run.log` and
`build/sim/fc_parameter_epoch_baseline/run.log`. Hashes and outcome summaries
are retained in `EVIDENCE.md` because build logs are intentionally ignored.
These are experiment-level simulation results; production integration,
PDS timing/resource closure and board inference remain separate gates.
