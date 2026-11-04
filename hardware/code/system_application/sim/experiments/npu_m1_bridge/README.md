# Experimental native m1 transaction bridge

Run from `instrec_fpga/`:

```powershell
python sim/experiments/npu_m1_bridge/run.py
```

The bridge shares DDR controller master 1 between the existing WDMA command
stream and the activation row store's abstract single-beat interface.
Production top, DDR controller and production arbiter remain unchanged.

- Weight side: `wgt_cmd_valid/cmd[36:0]` are held until `wgt_done`.
  `wgt_rd_ready` is read pacing toward native DDR, not command acceptance.
  `wgt_rd_data/valid` and done are routed only while weight owns the port.
- Activation side: `act_cmd_valid/write/addr[31:0]/ready` accepts one local
  command. Reads route `act_rd_valid/data` with no backpressure.
  Writes first wait for `act_wr_valid/data`, latch data, then issue the
  native write command. `act_wr_ready` is high in ACT_DATA and accepts the
  data into the one-beat staging buffer; it does not indicate DDR completion.
  The client holds valid/data until this handshake. Later commands wait until
  the native transaction has completed. A later abort reports sticky failure
  even if the write data was already accepted locally.
- Native side: `m1_cmd_valid/cmd[36:0]/wdata/rd_ready` outputs connect to
  controller master 1; `m1_wready/rdata/rvalid/done` are controller responses.
  There is no native command-ready signal. The chosen command is held through
  native completion and cannot be preempted. Native read done may precede
  upstream FIFO data: the bridge drops command valid at native done but keeps
  ownership until all `len+1` read beats have been consumed. It counts only
  `m1_rvalid && m1_rd_ready`; native `rd_valid` is not itself ready-gated.
  Weight done is reported only after both native completion and data delivery.
  Weight completion is followed by a
  wait for the old weight request to drop, preventing duplicate submission.
- Arbitration: initially weight wins a simultaneous request; after every
  completed transaction the other client has priority if both are pending.
  Transaction round robin prevents continuous weight bursts starving rowstore.
- Failure side: `m1_abort` must identify a controller abort/error for the
  current transaction. It terminates command submission, pulses
  `transaction_failed`, latches `protocol_error`, and holds a quiescent FAULT
  state until reset. It never fabricates successful weight done or activation
  data for a truncated read. Local write-buffer acceptance is not a guarantee
  of later DDR commit. An integration must
  connect this error path and respond to `protocol_error`; tying abort low
  cannot recover a watchdog that delivers fewer than the requested read beats.

The single-beat activation address must be 32-byte aligned and fit in 28 bits;
an invalid pending address latches `protocol_error` and is not accepted.
Weights are assumed read-only. The bridge does not assign memory regions or
replace the outer arbiter whitelist. Experiments use activation base
`0x00400000`; pool1 cannot share the existing 64KiB spectrum window at
`0x00200000` because its padded footprint is 198656 bytes.

The unit test runs simultaneous clients with random native service delays:
30 weight bursts of 16 beats, 20 activation writes delayed seven cycles after
command acceptance, and 20 matching readbacks. It checks held requests,
command stability through completion, no write issue before data, no replayed
transaction, route exclusivity and pending-client wait bounds. Read completion
is tested before upstream data, with last `rd_valid`, and several cycles later;
write completion coincides with its single accepted write beat. A final
truncated-read abort checks explicit failure, no successful done and a sticky
quiescent FAULT state.

This is an isolated protocol regression. Full rowstore/NPU integration,
real-controller error wiring, synthesis, timing and board validation are
separate requirements. The real controller's `done` alone does not distinguish
watchdog abort from success; do not infer that distinction from done timing.
