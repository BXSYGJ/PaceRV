# Complete abstract DDR NPU candidate

Run from instrec_fpga: `python sim/experiments/npu_full_end/run.py`.

The runner regenerates all golden vectors from the tracked weight image, layer contract, mel tables and npu_conv1 feature fixture. It does not need build/npu_full assets. The test follows the natural NPU sequencer through four convolution/pool pairs, GAP, FC1, FC2 and softmax; no forced done or skipped layer is used. Every output is compared against golden, with exact output-count assertions at done. FC2 emits 8 real and 8 padded lanes; only the real logits feed softmax.

Initial natural run passed at 30,757,679 cycles. The case uses an abstract DDR model and does not establish native DDR, synthesis, routing or board correctness.

Candidate fixes isolated here:
- Capture FC bias/M/shift concurrently with input-vector loading. Clear on layer start and stop at COUT; do not discard early parameters or count repeated WDMA group contracts.
- Wait for all COUT parameters; the original COUT-1 simultaneous test deadlocked with serialized parameter streams.
- Reload the FC weight cache when its consuming engine advances a group, rather than when the producer advances early.

Failure evidence is preserved under build/sim/npu_full_end: fc1_timeout_original.log, fc1_mismatch_after_count_fix.log, fc1_mismatch_after_group_fix.log, fc1_input_weight_guards.log, fc1_parameter_guard_failure.log, fc1_M82_misalignment.log. These are local diagnostic artifacts. Production RTL remains unchanged.
