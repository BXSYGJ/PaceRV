# Validated candidate to production integration plan

Scope: read-only assessment, 2026-11-01. No production/PDS/downloader changes.
Baseline: `python sim/experiments/npu_full_native/run.py` PASS natural done 31,115,245 cycles; all conv/pool/GAP/FC/softmax values checked against golden. This tests one committed feature fixture, one inference and one AXI service configuration, with m0/m2/m3 idle. It is not a production top-level or board test. A later two-inference regression FAILED on second-inference FC2 output 0 (29 instead of 202); the FC parameter lifecycle is under repair. Therefore the baseline is single-inference-only until a new complete two-run PASS is recorded.

Generate the actual runner manifest and port delta with:
`python sim/experiments/npu_integration_review/inspect_manifest.py`
Output: `build/sim/npu_integration_review/manifest.json`, including SHA256 for all 17 RTL inputs. This reads AST RTL expressions from the runner; it does not maintain a second hand-copied source list. No source writes, PDS or board interaction.

## Exact module changes

| Module | Validated candidate | Production port delta / required behavior |
|---|---|---|
| conv_engine | npu_full_end/conv_engine_candidate.v | Add output x0_ingress_max_row[15:0], input y_ready. Reserve whole requant burst, buffer outputs, defer final done until accepted. |
| pool_engine | npu_full_end/pool_engine_candidate.v | Add output y_ready, input p_ready. Buffer results, advance geometry only on input handshake, clear stale pipeline at arm. |
| npu_top | npu_full_end/npu_top_candidate.v | Add nine act_* ports (command valid/write/address/ready, write valid/data/ready, read valid/data). Wire two row stores, mux, direct replay_row credit, accepted-last lifecycle, GAP early arm, FC group advance. |
| fc_engine | npu_full_end/fc_engine.v | Add output grp_advance. Capture bias/M/shift independently during input loading; saturating COUT counters; use FC completion to rearm wbuf. |
| wbuf | npu_full_end/wbuf.v | Same ports. Synchronous read lookahead and suppress stale valid on rearm. |
| wdma | wdma_parameter_ram/wdma_wide_fixed.v | Same ports. Wide synchronous parameter RAM, per-beat address advance, shift/group stride and handshake fixes. Offset addressing remains intentional until aligner. |
| activation_row_store_dynamic | activation_store/activation_row_store_dynamic.v | New production module; two instances, runtime geometries, serialized native-sized beats, RAM scatter/replay and row credit. |
| activation_store_mux | activation_store/activation_store_mux.v | New production module; one outstanding command, write buffer acceptance permits a new pending command but downstream ready must still hold it. |
| npu_stage_lifecycle | npu_lifecycle/npu_stage_lifecycle.v | New module; arm pool/GAP at producer start, retain completion until sequencer reaches stage. |
| weight_read_aligner_hardened | weight_read_aligner_hardened/weight_read_aligner_hardened.v | New module outside npu_top; maps relative image offsets to 0x100000, reads aligned chunks <=16 beats, buffers <=17, shifts output, supports upstream readiness and abort/error reporting. |
| npu_m1_bridge | npu_m1_bridge/npu_m1_bridge.v | New module outside npu_top; combine aligned weight requests and activation requests on m1. ACT_DATA stages write before native issue; wait for both native done and read delivery; abort is explicit failure. |
| ddr3_arbiter | npu_lifecycle/ddr3_arbiter.v | Same ports. Allow m1 len0 activation windows A 0x400000..0x43ffe0, B 0x440000..0x45ffe0. |
| ddr3_ctrl_axi | src/ddr3/ddr3_ctrl_axi.v | Already production module; unchanged in PASS. |
| gap_unit, requant_unit, softmax_top | src/npu/*.v | Already production modules; unchanged in PASS. |
| ddr3_axi_model_full | npu_pingpong_native/ddr3_axi_model_full.sv | Simulation ONLY; full address index, 8MiB memory. Never add to PDS/source globs. |

Candidate paths in table are relative to sim/experiments/ unless prefixed src/.

## Minimal executable integration order

1. Preserve current route artifact and input hashes. Save a production-source/constraint snapshot, run git status/diff. Do not mutate source inputs while a PDS run is active. Keep frozen candidate baselines intact.
2. Copy corrected six compute modules as a coherent set (conv/pool/top/fc/wbuf/wdma), renaming candidate files to their module names. Add row store, activation mux and lifecycle under src/npu. Update all changed-port instantiations, including diagnostic tops/tests. Keep the board NPU start gated during staging. Run check_rtl, Python checks, abstract full_end and native full_native; additionally rebuild the same TB against the *new production paths* to prevent candidate-only PASS claims.
3. Promote the hardened weight aligner and bridge under src/npu; hardened alignment already implements readiness, abort/reset and synthesizable protocol errors. Keep its configurable relocation base consistent with the loader. Keep one relocation only: WDMA emits relative offset, aligner adds 0x100000. Set weight_loader.BASE_ADDR=0x100000 so uploaded image agrees. Adapt smoke/readback tests to common map; do not relocate existing WDMA and also retain aligner relocation.
4. Replace instrec_top's direct NPU->m1 path with NPU weight->aligner->bridge, and NPU act_*->bridge. Bridge m1 outputs feed existing controller; return controller rd_data_1/rd_valid[1]/done[1]/cmd_to_err[1]/wready_beat[1] to bridge. Replace m1_wdata=wl_wdata with owner-selected loader or bridge write data. Controller rd_ready[1] must select wl_rd_ready or bridge.m1_rd_ready; currently it always uses loader rd_ready. Drive the currently undriven npu_rd_ready_u (fixed 1 is the validated DMA drain mode); it is not native command-ready. In the validated TB the aligner drains to WDMA at one beat/cycle with readiness high.
5. Make loader/bridge ownership transaction-safe: latch ownership until native completion and remaining read FIFO delivery, do not asynchronously switch on wl_busy. Gate new inference until calibration/weights ready and loader idle; reject/defer loading during NPU active or retain a request until safe idle. Gate done/read/write-ready/abort signals to their owner. Route bridge sticky error and transaction_failed into top debug/status and terminate/mark a failed inference; do not silently publish probabilities after failure. Add active-m1/m0/m2/m3 competing-client integration TB and injected read/write timeout tests.
6. Copy activation whitelist change to production arbiter only after address-map review. Run production-source complete native TB with loader upload/readback and competing PCM/mel/self-test traffic, plus two consecutive inferences (row-store lifecycle reuse). Run check_rtl=0, required Python checks and PowerShell dry run. PDS full sources already glob src/npu/*.v and src/ddr3/*.v; new synthesizable files there should be found without adding sim files. Confirm module=file names and no duplicate module sources.
7. Only after source freeze, one PDS compile/route process. Check synthesis RAM/resource inference (two 32-lane row buffers + <=17beat aligner storage), WNS and input manifest. Download only new matching bitstream, validate weights load/readback and actual NPU completion/probabilities, then preserve evidence and update STATUS/CHANGELOG/memory/commit.

## Production gaps found during assessment

* src/ctrl/instrec_top.v still uses the old direct m1 path, does not connect any activation ports, m1 write data always comes from weight_loader, and rd_ready[1] always uses wl_rd_ready.
* npu_rd_ready_u is declared and consumed but never assigned in current instrec_top. Native candidate avoids this by draining at fixed readiness 1. This must be made explicit before enabling production inference.
* Current production weight_loader defaults BASE_ADDR=0 and top does not override it. Current WDMA also emits image-relative offsets. Zero-based reads can pass the arbiter because its generic PCM window permits them, so a clean addr_err does NOT prove weight/PCM isolation. Native candidate explicitly moves the uploaded image to 0x100000 in its preload and aligner.
* First parameter offset=944 (16-byte but not 32-byte aligned); conv1 group stride144 repeats this issue. Merely adding the base does not fix alignment. Direct native experiment failed addr_err[1] at 135ns until read aligner was inserted.
* Original AXI model indexes addr[20:5], so MEM_BEATS alone cannot eliminate 0x400000 alias. Full native test uses a separate full-index model and separate activation regions. Never infer address isolation from the old model.
* Bridge/aligner error propagation, transaction ownership with real loader, contention, repeated inference, reset mid-command, PHY/calibration and physical timing are not established by single-fixture full native PASS.
* Compute candidate headers contain stale historical comments; rewrite accurately when promoting. Integer-heavy row-store indexing, variable shift and large RAM/bus mux logic need PDS compile/resource/timing review. The old baseline aligner contains a test assertion and is obsolete for promotion; snapshots use the hardened synthesizable readiness/abort/error implementation. Hardened directed PASS does not establish production-top failure recovery.
* 31,115,245 cycles = 248.922ms at125MHz, 259.294ms at120MHz. This exceeds the historical200ms budget despite satisfying the50M watchdog. User has prioritized completion over performance; report measured latency honestly, not as meeting200ms.


## Frozen-source validation tools

`prepare_snapshot.py` creates a unique production-named source tree under
`build/npu_production_candidate/`; it never edits mainline source. It records
all file hashes and candidate overrides. Both top_rv_core and instrec_top are
patched with hardened alignment, native activation bridge, fixed loader base,
read readiness and transaction ownership. Snapshot build_sets is frozen too.

`check_snapshot_structure.py <snapshot> [--top instrec_top]` checks frozen hashes
and elaborates the true top using only explicit vendor wrapper stubs. This
is structural evidence, not a functional clock/PHY/HDMI test.

`run_snapshot_native.py <snapshot>` resolves all complete-native DUT inputs from
the snapshot and inserts the frozen npu_m1_owner between bridge and controller.
It runs two complete golden inferences without reset. Loader is idle and m0,
m2,m3 are idle, so real upload/readback and active-client contention remain gaps.
`--manifest-only` records frozen input paths/hashes without simulation.

`prepare_snapshot_gate.py <snapshot> [--set full]` prepares compile/synthesize/
dev_map TCL without starting PDS. Actual source/constraint files come only from
the frozen tree, including CPU sources. IP companion files are copied into the
separate gate directory and hashed. The launcher rejects any changed input or
an existing pds_shell; the parent coordinates the single build slot. Gate
preparation or structural PASS must never be described as synthesis success.

Latest owner directed regression covers held ownership, frozen commands, early
native done plus delayed FIFO delivery, loader completion qualification, native
abort/no leakage, and illegal burst fail-closed behavior. Normal loader RX is
blocked during NPU busy; simultaneous new SOF/start drops the upload byte and
the host must retry when idle. Sticky native errors require reset.

Continuous inference status: FC-only layer-valid gating was insufficient
(second FC2 output0=6, expected202). A second candidate also retires FC
parameter counters in S_DONE, forcing the next epoch to await its own contract;
this candidate requires a new full two-inference PASS before promotion.


## Promotion file checklist (no automatic mainline write)

Replace `src/npu/{conv_engine,pool_engine,npu_top,fc_engine,wbuf,wdma}.v`
and `src/ddr3/ddr3_arbiter.v` from the final snapshot as one coherent set.
Add `src/npu/{activation_row_store_dynamic,activation_store_mux,
npu_stage_lifecycle,weight_read_aligner_hardened,npu_m1_bridge,npu_m1_owner}.v`.
Apply frozen `src/ctrl/{top_rv_core,instrec_top,top_core_only}.v`; all three
require the new weight/native activation and owner/ready/base/error plumbing.
CPU historical RTL remains read-only and is not a promotion target.

`src/diag/top_npu_conv1_test.v` also instantiates conv_engine; tie its new
`y_ready` input to 1 and connect `x0_ingress_max_row` to a named unused wire.
`sim/tb_conv_engine.sv` and `sim/tb_conv_layer.sv` need the same readiness
adaptation. `sim/tb_npu_completion.sv` needs the new nine act ports serviced
by an activation memory model before it can claim complete-NPU behavior.
`sim/tb_npu_chain.sv` has two FC instances; connect new grp_advance outputs
to named unused wires if the test does not consume them, then rerun because
FC parameter lifecycle semantics changed. The full-native golden runner must
resolve production paths after promotion; experiment-only source PASS is
insufficient. Frozen historical experiments should remain unchanged.

Final candidate 20261101-215059 includes both repeat fixes and final M1 owner
73593FA9861AF3DC2D73C185431FA67CDE013A3F467D324AF35B38747AB2DE75
(before nonfunctional module header addition). All three production tops passed
structural expansion, and candidate src lint checked59 files with0 violations.
An extra masked lexical scan found no nested generate or decimal parameter-base
literal. These are source checks; the exact-source two-round native+owner
functional result and subsequent PDS gate remain separate evidence.


Final 20261101-215059 exact-source full native+owner regression is PASS:
`build/sim/npu_snapshot_native_20261101-215059/run.log` records two complete
inferences without reset, each31,141,202 cycles. All conv/pool/GAP/FC outputs
and softmax probabilities match golden with exact output counts. External
`build/sim/npu_snapshot_native/20261101-215059/validation.json` binds snapshot,
18-input manifest and log SHA256; it supersedes the snapshot metadata's stale
pre-validation single-inference description without modifying frozen files.
At125MHz this measured latency is249.130ms; owner overhead is25,957 cycles
relative to the no-owner repeat baseline. The exact resource gate is prepared
at `build/resource_gate/native-20261101-215359-012687` (not launched here).


After parent promotion, `run_snapshot_native.py .../20261101-215059 --production`
also PASSED two complete golden native+owner inferences at31,141,202 cycles each.
The18-input manifest records17 actual mainline `src/` DUT files (each verified
byte-identical to snapshot) and the frozen full-address AXI model. Evidence:
`build/sim/npu_production_native_20261101-215059/run.log` and hash-bound
`build/sim/npu_production_native/20261101-215059/validation.json`. The actual
parent-launched gate is `build/resource_gate/native-20261101-215404-522126`;
215359 remains an unlaunched prepared gate. Production-top structural expansion
and this direct native-chain functional test have distinct scopes.
