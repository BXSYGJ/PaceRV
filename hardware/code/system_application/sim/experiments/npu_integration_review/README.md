# Native M1 transaction owner candidate

`npu_m1_owner.v` is an isolated owner wrapper for the snapshot integration boundary. It locks one loader or NPU request, latches the command, masks the other client, and does not release ownership when native `done` arrives until all read beats have been accepted by the selected client and its request valid is low. Requests are limited to 16 beats (`len <= 15`). Native abort and invalid requests fail closed until reset.

Verification: `python sim/experiments/npu_integration_review/run_owner.py`

PASS coverage: simultaneous loader/NPU requests, loader policy change and busy variation after acceptance, early native done, four-beat read backpressure and drain, abort routing, reset recovery, and 16-beat boundary plus 17-beat rejection. Loader-facing done is delayed until all expected FIFO beats are actually accepted, since the real loader immediately withdraws read-ready on done. Abort suppresses data delivery and loader completion.

`python sim/experiments/npu_integration_review/run_loader_owner.py` also passes the real production `weight_loader` plus this owner against an early-done native responder: four 256-byte chunks, complete `KKKKWOK 42851062\n`, exact readback digest, all 32 read beats, corrupt CRC rejection, and reset recovery (10 checks). The native responder reports done before the first read delivery. The unchanged loader source is used. This is not synthesis or hardware evidence.

`python sim/experiments/npu_integration_review/run_loader_native.py` uses the real loader, owner, production `ddr3_ctrl_axi`, candidate arbiter, and full-address native AXI model at the snapshot's weight base `0x100000`. It passes the same upload/readback/CRC/reset checks and confirms four native read-done pulses precede loader completion (11 checks). `--timeout` withholds AW ready and verifies native timeout becomes a sticky owner fault, no `K`/frame increment/weight success occurs, delivery remains disabled, and reset recovers. Loader completion requires a registered native done observation because the controller's timeout sticky flag appears one cycle after its done pulse. Invalid loader commands also fail closed without a false completion. Loader has no explicit abort input, so faults require reset rather than a UART NAK recovery.

`--read-timeout` also passes: one real upload succeeds, then the AXI model withholds read data. The native controller times out, the owner locks the failing M1 path, no WOK or new frame acknowledgement is generated, and reset clears the fault. This test uses the stable owner unchanged.

`python sim/experiments/npu_integration_review/run_contention.py` passes concurrent four-master traffic through the production controller, candidate arbiter and full native AXI model: M0 PCM write/read, M2 Mel reads, M3 self-test write/read, and M1 weight reads plus activation write/read. It checks each delivered payload against its own expected address/sequence, all four requests pending together, one-hot completion/data routing, and exact native completion counts M0/M1/M2/M3 = 4/4/3/4. A second phase suppresses only M1 AW ready: only bit 1 of the timeout vector sets, the M1 owner fails closed, other masters complete their reads/writes, weights and existing activation remain intact, and the timed-out activation write leaves memory untouched. This exercises native transaction contention, not the full NPU/audio/Mel production modules together. No PDS or board claim follows from it.


Frozen candidate workflow (never edits mainline RTL):

```
python sim/experiments/npu_integration_review/prepare_snapshot.py
python sim/experiments/npu_integration_review/check_snapshot_structure.py build/npu_production_candidate/NAME
python sim/experiments/npu_integration_review/check_snapshot_structure.py build/npu_production_candidate/NAME --top instrec_top
python scripts/check_rtl.py --src build/npu_production_candidate/NAME/src
python sim/experiments/npu_integration_review/run_snapshot_native.py build/npu_production_candidate/NAME
python sim/experiments/npu_integration_review/prepare_snapshot_gate.py build/npu_production_candidate/NAME
```

Use only a newly generated snapshot after both repeat-inference fixes are present
(top FC layer-valid gating and FC engine parameter-counter retirement). Older
snapshots 20261101-213818, 213930, 214315 and 214435 are diagnostic historical
artifacts and must not be promoted. The complete native runner checks two golden
inferences through the actual frozen M1 owner with loader and other masters
idle. It does not run the complete production top or physical DDR PHY. Structural
checks stub audio_pll/ddr3_wrapper (also hdmi_tx_if for instrec_top). Gate preparation
is not synthesis: it never launches PDS. Parent must coordinate the single PDS
slot and review functional evidence before launching the generated launch.ps1.
All board/PHY/timing and real loader contention claims require separate evidence.


After promotion, verify the actual mainline paths with:

```
python sim/experiments/npu_integration_review/run_snapshot_native.py build/npu_production_candidate/20261101-215059 --production
```

This mode refuses any DUT file whose bytes differ from the frozen snapshot,
then uses actual `src/` files for all17 DUT modules plus the frozen full-address
AXI model. Inputs and hashes are under `build/sim/npu_production_native/NAME/`;
the simulation build/log directory is `build/sim/npu_production_native_NAME/`.
It still inserts the real owner with loader/other masters idle, so this is a
complete NPU/native-chain test rather than full production-top or board proof.
# Distinct-frame repeat regression

Run `python sim/experiments/npu_integration_review/run_snapshot_native.py build/npu_production_candidate/20261101-215059 --production --ab-inputs`
to preserve DUT/native DDR state while changing every feature byte before
the second inference. Frame B is `255-A` with independently generated golden
arrays. Assets and their hashes are retained under
`build/sim/npu_production_native_ab/20261101-215059/`.
The run passed all intermediate and final golden comparisons for both
31141202-cycle frames. See
`reports/activation_repeated_boundary_review_20261101.md` for evidence and
remaining fault/reset coverage limits.
