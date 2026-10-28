# Measurements and reproducibility

## Qualified operating point

Both complete systems target Pango Logos2 PG2L200H-6FBB676, with a 27 MHz board input and a configured processor clock of 145.125 MHz. Timing uses 0.150 ns setup uncertainty. All timing sections in the included reports must pass. The reported slack already accounts for uncertainty.

| Configuration / firmware | Iterations | Cycles | Retired instructions | CoreMark/MHz | CoreMark/MHz/kLUT |
|---|---:|---:|---:|---:|---:|
| Base / V0 performance | 6,000 | 1,743,221,870 | 1,649,428,429 | 3.441903 | 0.564524 |
| Retained / V0 performance | 6,000 | 1,743,134,699 | 1,649,428,429 | 3.442075 | 0.559687 |
| Base / V1 validation | 6,000 | 1,746,239,851 | 1,649,775,527 | 3.435954 | 0.563548 |
| Retained / V1 validation | 6,000 | 1,746,155,845 | 1,649,775,527 | 3.436119 | 0.558719 |

Machine-readable measurements are in each release's `PERFORMANCE.json`. CoreMark equals `iterations * configured_clock_hz / cycles`; CoreMark/MHz equals `iterations * 1,000,000 / cycles`. Resource efficiency equals CoreMark/MHz divided by LUTs in thousands. Each row describes its own measured complete system; the two layouts are not a paired marginal-area estimate of a single mechanism.

## Benchmark configuration

Firmware uses RV32IMC/ILP32, GCC 10.2.0, `-O3`, `-funroll-loops`, and a 2,000-byte CoreMark data size. V0 and V1 are separate performance and validation builds. Full compiler options, linker script, source bindings, and firmware hashes are in `recipe.json` and `firmware/V*/`. Each image has three archived cold-start UART captures and a frozen full-system simulation reference. CRC validation and exact START-to-FINISHED byte comparison are required.

## Verification layers

1. `scripts/Test-PaceRV.ps1` verifies release hashes, simulation source bindings, image/firmware identities, twelve complete archived board frames, measured counters, resources, and four timing reports.
2. `scripts/Test-RTL.ps1` executes the focused multiplier and core tests using Icarus Verilog, independently of PDS.
3. Portable scripts prepare or build a PDS physical project, rebuild firmware, compile/run native timed-memory simulation, and collect a fresh board frame.

Offline archive audits and core-level tests are distinct from new place-and-route or a new live board measurement. The archived reports and captures identify the measured implementation; a changed implementation gets its own timing report and capture.

## Byte identity and external models

RTL, firmware, bitstreams, UART references, and raw timing reports preserve their source bytes. Public recipes omit workstation-specific provenance fields. Proprietary Pango model files are external dependencies with pinned hashes. No PDS library or installer is redistributed.

The source manifest records the public file hashes. The original development checkout and the camera-ready manuscript are not modified by this release.
