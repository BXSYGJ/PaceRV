# Native-controller four-convolution experiment

Independent follow-up to `../npu_pingpong`; the abstract DDR baseline is unchanged.
Run from instrec_fpga: `python sim/experiments/npu_pingpong_native/run.py`.
Evidence: `build/sim/npu_pingpong_native/run.log`.

The chain is candidate npu_top + activation mux + repaired ACT_DATA bridge + production ddr3_ctrl_axi + candidate activation-region arbiter + behavioral Pango AXI model. No PDS or board success is implied.

The experimental AXI model copies sim/ddr3_axi_model.sv but indexes the complete 28-bit byte address divided by 32, with 262144 beats (8 MiB). Both read/write ranges are asserted. This removes the original model's addr[20:5] alias; merely increasing MEM_BEATS would not fix it. Store A is 0x400000..0x43ffe0 and B 0x440000..0x45ffe0. Native command range and distinct weight/activation indices are checked; layer transitions print first/last/min/max weight addresses and highest activation addresses.

IMPORTANT INTEGRATION BLOCKER: production src/npu/wdma.v and candidate WDMA currently emit zero-based offsets and some requests are only 16-byte aligned (first bias offset 944, conv1 group stride 144). Native DDR requires 32-byte aligned addresses; the weight region is 0x100000. The experimental weight_read_aligner explicitly relocates by 0x100000, rounds down each command, fetches up to 17 aligned beats in chunks <=16, and reconstructs the requested byte stream. This adapter is NOT merged into production. Passing this experiment cannot establish that the current production WDMA address path is correct.

The aligner buffers a complete request and then supplies continuous output beats to WDMA. The test uses readiness always high for this output. Native controller FIFO/bridge correctness is still exercised. AXI memory is simulation only; PHY/calibration, CDC and physical timing require separate hardware validation.

Validated 2026-11-01: all four convolution outputs and pool1..3 activation replays match golden, 31,106,081 cycles. The result stops at conv4 completion; GAP/FC/softmax are not covered by this PASS. No production RTL or PDS input changed.

Initial direct-offset run failed at 135 ns with native addr_err=0010 on first unaligned parameter address. The experiment then added the explicit read aligner. This earlier failure is diagnostic evidence of the production integration blocker, not a numerical mismatch.
