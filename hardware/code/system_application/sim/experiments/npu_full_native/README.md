# Full native-controller NPU experiment

Run `python sim/experiments/npu_full_native/run.py` from instrec_fpga.
Combines the repaired full-chain candidate from ../npu_full_end with native controller, candidate arbiter, repaired bridge, experimental read aligner and full-address AXI model from ../npu_pingpong_native. Both successful baselines remain unchanged.

Assets are regenerated from the committed feature fixture and bit-level golden pipeline. Checks all conv/pool values, GAP256, FC1 128, FC2 first eight logits and padded sixteen output handshakes, softmax eight Q0.16 values, and natural top-level done. This is a behavioral native-controller interface simulation, not DDR PHY/CDC/PDS/board validation.

The production WDMA still needs explicit weight-region relocation and unaligned read adaptation. This experiment uses ../npu_pingpong_native/weight_read_aligner.v; no production change is implied. See that experiment README for address/index coverage and limits.

Validated 2026-11-01: natural done at 31,115,245 cycles, every checked value golden exact. Final count checks: conv1/2/3/4=792576/396288/196608/65536; pool1/2/3/4=198144/98304/49152/16384; GAP=256; FC1=128; FC2 padded output handshakes=16 (eight semantic logits checked); softmax probabilities=8. Evidence: build/sim/npu_full_native/run.log.

Final native command address observations: first weight=0x1003a0, last=0x1a8900, min=0x100200, max=0x1a8b40; activation A max=0x4307e0, B max=0x457fe0. Native bridge protocol error, controller timeout and arbiter address error assertions remained clear.
