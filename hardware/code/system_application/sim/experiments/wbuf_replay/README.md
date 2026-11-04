# WBUF replay and group-load boundary experiment

The RTL snapshots are experimental, not production RTL. Both define `wbuf`;
compile only one at a time. The runner depends solely on the tracked source
files here and `sim/run_sim.py`, not on any source under ignored `build/`.

Run from `instrec_fpga/`:

```powershell
python sim/experiments/wbuf_replay/run.py fixed
python sim/experiments/wbuf_replay/run.py baseline
```

Fixed must pass 10,797 accepted tap comparisons. Baseline deliberately fails
and returns exit 1 on stale valid during the first 1 -> 9 group reload.
Output logs live in `build/sim/wbuf_replay_experiment_{fixed,baseline}/`.

Step4 baseline includes the synchronous read look-ahead repair over mainline.
Step8 additionally gates valid by replay state and group-start, clears the
valid register at reset/group-start, and uses actual valid/ready for both
pointer advancement and look-ahead.

The test covers active lengths 1/9/1728, continuous/random consumption,
multiple wraps and group reload sequence 1 -> 9 -> 1728 -> 9 -> 1. It asserts
ready throughout loading and independently forbids `load_active && rd_valid`.
The earlier temporary test's 10,797-data PASS missed this boundary because
ready/checking were disabled during loading; the baseline is therefore a
counterexample to that test's coverage, not a production-ready candidate.

Full evidence and preserved diffs/SHA values are in
`reports/wbuf_candidate_validation_20261101.md`. This unit test does not prove
full NPU golden correctness, FPGA timing, RAM inference or board behavior.
