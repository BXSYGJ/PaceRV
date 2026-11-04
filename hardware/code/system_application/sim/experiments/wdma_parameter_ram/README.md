# Corrected WDMA parameter RAM experiment

Run from `instrec_fpga/`:

```powershell
python sim/experiments/wdma_parameter_ram/run.py
```

This experiment compares two experimental modules cycle by cycle for layers
0 through 5, 350,000 cycles each, with randomized DDR response gaps and
weight ready stalls. It compares command, weight and parameter valid/data,
group-start, busy and done. Input bytes are an address-dependent synthetic
pattern; no weight hex is required or copied.

`wdma_corrected.v` is the corrected scalar-RAM WDMA (renamed module) from the
handshake experiment. `wdma_wide_fixed.v` changes only parameter storage:
bias/M accept a whole 256-bit beat at index `cfg_idx[7:3]` (M adds 32);
shift accepts a beat at index `cfg_idx[7:5]`. Reads use `pa[8:3]` for bias/M
and `pa[7:5]` for shift; lane and table selection are captured on that same
edge, preserving the one-cycle scalar read latency.

An earlier wide-RAM experiment was equivalent to defective original WDMA;
that evidence could not establish corrected parameter addressing. This new
test compares corrected behavior to corrected wide behavior. Its initial
build-only run passed all six bounded comparisons. It proves equivalence in
the tested scenarios, not original correctness or reduced implementation
resources. No synthesis has confirmed RAM mapping or FF/LUT savings.

Production RTL, existing runner suites, and the active PDS run are unchanged.
Full conv1 golden validation of the wide candidate is a separate experiment.
