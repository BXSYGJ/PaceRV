# CPU and native NPU joint simulation

`run.py` runs the current production RTL and production ROM through real CPU
boot/MMIO/ISA, CPU pending request held until a modeled Mel safe window,
complete native NPU golden comparisons, result UART/MMIO and CTRL[1] ACK.
Use `--run-label unique-label` to preserve existing evidence.

## Two CPU requests with distinct frames

    python sim/experiments/cpu_native_joint/run_repeat.py --run-label unique-repeat-label

The current production firmware requests the next complete Mel window after
acknowledging each result. Verify its unchanged production ROM with:

    python sim/experiments/cpu_native_joint/run_repeat.py --production-rom --frame-major --run-label unique-continuous-label

This runs two different feature frames without resetting CPU, NPU or DDR. A
third CPU request remains pending after the second result; no third safe window
is supplied. Frame-major mode uses the actual Mel bank layout for both inputs.
The default mode retains an isolated firmware limited to exactly two requests,
for reproducing historical experiments. Existing run directories are refused.

Current production RTL, including the narrow row RAM template, passes both A/B
frames without DUT/DDR reset. B=255-A changes all 16512 feature bytes; all golden
arrays are independently recomputed and loaded before the second safe window.
Both frames complete in 31141202 accelerator cycles. The CPU reports each MMIO
snapshot as `NPU top1=0 last_class=7 last_p=0 c=31141201`, then acknowledges it.
Final counts are two CPU requests, two launches and two ACKs. Changed FC
accumulators and all intermediate comparisons distinguish the frames even though
their final top1 agrees.

Evidence: `reports/cpu_native_joint_repeat_ab_validation_20261101.json` with
source, candidate ROM/C, golden asset and log hashes. The successful log is
`build/sim/cpu_native_joint_narrow-repeat-ab-20261101-r3/run.log`; earlier
testbench failures are retained and described in the report.

DDR AXI memory, Mel safe windows and UART byte acceptance are modeled. Physical
DDR PHY, full audio/Mel frontend, board UART/JTAG, CDC and timing are excluded.
The historical evidence used an isolated firmware candidate. The production
continuous-ROM run is recorded separately in
`reports/cpu_native_continuous_validation_20261102.json`.

## Real Mel feature layout

`python sim/experiments/cpu_native_joint/check_mel_handoff.py` extracts the
actual NPU feature replay and actual Mel bank read mux/RAM. A known
frame-major pattern reproduces the old missing-transpose bug: at NPU stream
index 1, the old direct address reads mel1/time0 (13) rather than mel0/time1
(7). The new address concat `{feat_col,feat_row[5:0]}` passes all 16512 bytes
and all addresses form a bijection; Mel adds its physical +64 internally.

`npu_top.FEATURE_FRAME_MAJOR` defaults to 0 for existing mel-major fixture
RAMs. All three production tops set 1 for the real frame-major Mel bank.
The conv ingress order stays mel-major and its read-valid latency is unchanged.

Run the complete CPU/native inference in this mode with:

    python sim/experiments/cpu_native_joint/run.py --frame-major --run-label unique-frame-major-label

This stores the golden features as `feat.T` in the simulated RAM and sets
the real NPU parameter to 1. The production ROM/current RTL run passes all
intermediate and final golden checks in 31141202 cycles. Evidence:
`reports/mel_feature_handoff_validation_20261101.json`.

Features are unsigned bytes with zero point 49 throughout standardize, Mel
bank and NPU ingress. Conv uses signed 9-bit `(uint8-49)`; no signed-byte
reinterpretation or second zero-point addition is needed. Normal audio
cadence protects the single Mel bank in practice, but there is no explicit
NPU-busy lock against an arbitrarily early next window. Physical and complete
audio/Mel tests are separate from these bank-layout and native compute tests.
