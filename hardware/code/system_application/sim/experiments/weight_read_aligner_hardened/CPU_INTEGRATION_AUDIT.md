# Frozen RV integration audit, 2026-11-01

Snapshot audited: `build/npu_production_candidate/20261101-215059`.
No production source was changed for this audit.

The RV core is instantiated and active in `src/ctrl/top_rv_core.v`:
`rv32_cpu_subsys` uses the existing rv32_core, reset vector 0, ENABLE_M=0,
ENABLE_PREDICTOR=0, and a real 8 KiB instruction ROM. This build is RV32I;
the historical core's optional M support is disabled for resources.

Default NPU_ENABLE=0 means firmware control is required. Firmware writes
NPU_CTRL at 0x80000024 with bit 0 set. The subsystem decodes the accepted
MMIO write into npu_soft_start. The top queues this as cpu_npu_pending and
launches the accelerator only on a completed Mel window, with sys_run,
DDR init/self-test, weights, idle accelerator and native ownership/fault
conditions satisfied. CPU start is therefore functional, rather than a
constant/unused pin. The pending request survives an upload or unready DDR.

NPU busy/done/probability/top1/cycle/timeout and DDR status are connected back
to CPU MMIO. Completed result payload and its cycle count are latched at
probability valid; firmware reads them, prints the result and writes CTRL
bit 1 to acknowledge stickies. A simultaneous new event wins over clear.
The software starts one inference and then reports events; it does not
reissue start after every result. Continuous CPU-triggered inference would
require a deliberate firmware change, which is outside this audit.

The main.c source was rebuilt in isolation using the installed native GCC
with --no-m / rv32i_zicsr_zifencei. Output is 2228 bytes / 557 words. The
rebuilt ROM equals the checked-in and frozen ROM byte-for-byte. Production
ROM was not overwritten; reconstruction artifacts are under
`build/sim/rv_firmware_audit`.

Run:

```powershell
python sim/experiments/weight_read_aligner_hardened/run_snapshot_cpu.py build/npu_production_candidate/20261101-215059
```

The runner first verifies all frozen source hashes against snapshot.json,
then boots the frozen CPU RTL and its own absolute-path ROM using the
established CPU TB. C1..C9 PASS: boot, MMIO ID, ISA test, cycle/instruction
measurement, returned NPU result, real CTRL[0] start pulse, DDR status,
CTRL[1] acknowledgement and result-cycle snapshot. Observed UART:

```text
RV32 BOOT
RV32 MMIO OK
RV32 ISA OK
RV32 BENCH cycles=460012 inst=180008 acc=0xf2d8888b
DDR OK STS 0x00000001
NPU GO
NPU t=3 p=87 c=12345
```

The NPU completion/result in this CPU test is injected after the firmware
start. Existing rv_top_ctrl tests separately exercise the exact source
launch slice; native full-NPU tests cover arithmetic/memory. This evidence
does not combine audio, CPU, vendor DDR PHY and NPU arithmetic into one
simulation and does not claim board inference success.

Frozen ROM SHA-256: `17c8f4c819c97d818112a08c822c240d896390ff34ba0216b1c98a08a1d863ff`.

CPU simulation log SHA-256: `20c783ac004d7963f76617107e89a4893cfe0b400924f7d018cca2e18d71f855`.
