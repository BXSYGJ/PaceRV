# Experimental activation row store

Not connected to mainline RTL or any PDS build set. No synthesis, routing or board evidence.

Run from instrec_fpga:

    python sim/experiments/activation_store/protocol_model.py
    python sim/experiments/activation_store/run.py

Python model passes complete real geometries (H,W,C): (32,129,48), (16,64,96), (8,32,192). RTL Verilator passes small geometry (2,3,48), 10 writes + 10 reads, 288 bytes exact; the preceding C32 version passed 6 writes + 6 reads, 192 bytes.

Producer order is row/group/column/lane. Storage and replay order is row/column/channel. DDR row stride is ceil(W*C/32)*32, with deterministic zero padding. Commands are abstract byte addresses, one 32-byte beat per command. Writes have separate command and data acceptance. R has no ready port: a read command reserves a complete beat in the row RAM; only one command is outstanding. Whole-row credit gates the next row fetch. It must be generated from consumer line-bank ownership, which is not implemented here. Output supports ready and holds data stable when stalled.

One row RAM blocks input while flushing DDR, so producer MUST honor in_ready. The existing pool producer has no ready and cannot be connected directly. No bridge to native ddr3_ctrl_axi, dummy-write protocol, real 37-bit command packing, shared weight arbiter or DDR error recovery is implemented. Native adapter must translate byte addresses consistently and wait for transaction completion at the specified native handshake.

Memory is expressed as 32 independent 8-bit lane banks with synchronous reads and one write per lane/cycle; the read port is shared between DDR output prefetch and canonical replay. This removes the original wide asynchronous RAM read structure but DOES NOT prove physical DRM inference or efficient packing. That requires compile/synthesis after the current unique PDS process finishes. Geometry requires CHANNELS a multiple of 16, HEIGHT/WIDTH positive, 32-byte aligned BASE, and a valid reserved DDR range.

TB checks command/data stalls, delayed R, output stalls, no read before credit, padded row boundary, transaction counts and exact canonical bytes. It does not prove integration, large-geometry RTL, zero-latency R, arbitrary DDR fault response, or repeated inference sequencing.

## Dynamic shared-row candidate

    python sim/experiments/activation_store/run_dynamic.py

`activation_row_store_dynamic` adds cfg_layer[1:0], cfg_base[31:0] and replay_row[15:0]. Configuration is sampled only on start. cfg_layer 0 selects pool1 W129/C48/H32, 1 pool2 W64/C96/H16, 2 pool3 W32/C192/H8. Invalid layer3 or unaligned base latches protocol_error and does not begin a transfer. replay_row is the row awaiting credit or being fetched/emitted; the next consumer supplies row_credit from its actual row-bank ownership. A granted row may finish even if credit later deasserts. The memory is shared at maximum194 packed beats and rows use padded strides6208/6144/6144 bytes respectively. Addresses advance from the latched base by stride without a runtime row multiplication.

Full real-geometry RTL round trips all passed in one run, with actual pool group/column/lane ingress and canonical column/channel replay:

| Layer | Frame bytes checked | Write commands | Read commands |
|---|---:|---:|---:|
| pool1 | 198144 | 6208 | 6208 |
| pool2 | 98304 | 3072 | 3072 |
| pool3 | 49152 | 1536 | 1536 |

The TB changes live configuration to invalid values after start and confirms the active transaction remains latched. It includes command/data stalls, delayed R, output stalls, initial credit withholding and replay_row checks. Log: build/sim/activation_row_store_dynamic/run.log. This remains an abstract DDR protocol test, without native-controller/top integration or synthesis/physical mapping evidence.

`activation_row_store_narrow.v` is an isolated inference candidate with bounded unsigned counters, explicit constant-32 address slices, and one canonical write per RAM bank. `run_narrow.py` passes cycle-by-cycle output comparison against the original while executing all three full-size reorder tests (198144 / 98304 / 49152 bytes). `prepare_narrow.py` reconstructs this candidate from the unchanged original.

`prepare_map_probe.py` prepares frozen original/narrow single-store PDS mapping probes, each with an identical I/O observation wrapper, clock constraint, hashed manifest and serial-only launch. It never launches PDS. These probes stop after dev_map and estimate RAM inference/resource cost only; they do not validate production functionality, routing or board behavior. See `reports/activation_store_resource_review_20261101.md` for evidence and limits.

## Direct immediate-R and start/error boundaries

`python sim/experiments/activation_store/run_boundaries.py` passes all three
full geometries with 10816 immediate read responses and an original/narrow
cycle miter. It checks nine busy-time start pulses (FILL/CREDIT/EMIT for each
geometry), unsolicited/duplicate R sticky error, reset clearing, and a fresh
post-reset CREDIT wait. Existing delayed-R logs remain separate. Log:
`build/sim/activation_store_boundaries/run.log`. These are abstract row-store
checks; reset during an outstanding native transaction and automatic retry
are not validated. See `reports/activation_repeated_boundary_review_20261101.md`.
