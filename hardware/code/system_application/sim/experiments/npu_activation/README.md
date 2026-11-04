# Conv1 / pool1 / DDR / conv2 integration baseline

Run from `instrec_fpga`: `python sim/experiments/npu_activation/run.py`.

The real shared NPU convolution core executes complete conv1 and conv2 using
the tracked model weight image. Expected tensors are freshly computed by the
bit-level golden pipeline from `../npu_conv1/feat_u8.bin`. Conv1 output, pool1
output, canonical DDR replay and conv2 output are checked byte for byte; pool2
output is also checked while conv2 is running. Conv2's final byte ends this
baseline, so the pool2 tail is not claimed complete.

The candidate adds conv/pool elastic drain queues, starts pooling at its
producing convolution start, and stores pool1 as canonical row/column/channel
bytes with a single dynamic row cache. Its internal `replay_row` directly
generates credit against the convolution core's explicit maximum ingress row.
An assertion checks credit on every accepted DDR read command. Counting
`row_done` in top was proven one cycle late and caused row4 to overwrite row1;
the original failure is retained in `build/sim/npu_activation/run_maccheck.log`.

Validated build variant: **792576 conv1 + 198144 pool1 + 396288 conv2 bytes
golden exact**, **12242761 cycles**. Evidence is
`build/sim/npu_activation_dynamic/run.log`. The persistent runner adds credit
assertions and writes its own results to `build/sim/npu_activation/run.log`.

DDR here is an abstract one-command/32-byte model with command/write stalls
and delayed unbackpressured reads. It is not the native 37-bit controller or
shared m1 arbitration. Experimental pool1 base is 0x00400000, stride 6208,
32 rows, 198656 padded bytes. This address setting does not prove the mainline
region whitelist or display arbitration has been connected. No PDS or board
evidence is claimed, and conv3/4 plus repeated whole inference remain unproven.
