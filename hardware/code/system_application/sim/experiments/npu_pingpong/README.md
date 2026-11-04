# Four convolution pingpong experiment

The independent candidate uses two dynamic row stores: store A holds pool1 and pool3, and store B holds pool2. The mux serializes abstract DDR commands and data. It runs all four convolution layers and checks each conv output plus pool1..pool3 canonical replay against the bit-level golden pipeline.

Validated 2026-11-01: all conv1..conv4 outputs and activation replays exact, 30,750,042 cycles. Evidence: `build/sim/npu_pingpong/run.log`. The test uses the abstract row-store command interface, not native 37-bit DDR or board constraints. It is an integration candidate only; no synthesis or hardware result is implied.

Store A uses 0x00400000 for pool1/pool3 and store B uses 0x00440000 for pool2. These are candidate regions and require the native arbiter whitelist before mainline use.
