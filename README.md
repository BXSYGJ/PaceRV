# PaceRV

**A single-issue, five-stage RV32IMC FPGA soft processor delivering 3.442 CoreMark/MHz.**

PaceRV studies how memory-request admission affects the reuse of arithmetic prepared ahead of execution. It combines a compressed-instruction front end, branch prediction, private instruction/data caches, machine-mode CSRs, and UART/GPIO peripherals in a complete FPGA system. The SystemVerilog implementation and its board-qualified Base and Retained configurations are released here under MIT; third-party components retain their own licenses.

**The 3.442 CoreMark/MHz result retains the complete SoC and its peripherals.** It is measured with instruction/data caches, backing RAM, UART, GPIO, a 64-bit timer, interrupts, machine CSRs, and live performance monitoring present in the implemented system.

## Complete system features

| Subsystem | Included functionality |
|---|---|
| Processor | Single-issue five-stage RV32IMC; hardware multiplication/division; compressed-instruction alignment; branch prediction |
| Memory | Instruction/data caches, shared BRAM backing memory, cache maintenance, memory-mapped peripheral interface |
| UART | Transmit/receive, FIFO buffering, status/error registers, interrupt controls |
| GPIO | 8-bit input/output, synchronized inputs, interrupt enable and pending registers |
| Timer and interrupts | 64-bit timer and compare registers; timer, software, and external interrupt inputs |
| Machine services | Writable `mtvec` and `mscratch`, trap state, ECALL/return handling, 64-bit cycle and retired-instruction counters |
| Live monitoring | Instruction/data cache hits and misses, data-cache writebacks, cycle/instruction counters and snapshot access |

The LUT/FF/BRAM/DSP results below cover this complete routed system. The archived source and firmware identify the measured configuration.

## Measured implementation

The following performance configurations ran **6,000 CoreMark iterations** on a Pango Logos2 PG2L200H-6FBB676 FPGA. Complete UART captures, firmware, timing reports, bitstreams, and source bindings are included.

| Configuration | CoreMark/MHz | CoreMark | Clock | LUT | FF | BRAM / DSP | Setup slack |
|---|---:|---:|---:|---:|---:|---:|---:|
| PaceRV Base | 3.441903 | 499.506 | 145.125 MHz | 6,097 | 2,541 | 25 / 4 | +0.047 ns |
| PaceRV Retained | **3.442075** | **499.531** | 145.125 MHz | 6,150 | 2,541 | 25 / 4 | +0.016 ns |

Setup slack includes **0.150 ns clock uncertainty**. Resources describe each complete routed system. The clock is the configured operating point. CoreMark/MHz is calculated from the 64-bit measured cycle count; detailed settings and validation configurations appear in [reproducibility](docs/reproducibility.md). See [performance context](docs/performance-context.md) for the comparison scope and verified external results.

## Start here

- [Build, simulate, and run on a board](docs/getting-started.md)
- [Architecture and configuration](docs/architecture.md)
- [Measurement and reproduction](docs/reproducibility.md)
- [Paper and citation](docs/paper.md)
- [Licenses and external dependencies](THIRD_PARTY_NOTICES.md)
- [中文简介](README.zh-CN.md)

The hardware snapshots keep their original `H3_*` directory and RTL module names so that archived source hashes and build recipes remain traceable. **H3 is the former internal name of PaceRV.** No renaming of the measured RTL is required to use this release.

```text
cpu/
  H3_Base_145125/       # PaceRV Base: source, firmware, physical inputs, evidence
  H3_Retained_145125/   # PaceRV Retained: source, tests, firmware, physical inputs, evidence
  release-support/     # PowerShell build, timing, and UART tools
scripts/               # Offline evidence verification and executable RTL tests
docs/                  # Architecture, setup, results, and paper metadata
```

To verify the release using PowerShell 7:

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    & ([System.IO.Path]::Combine((Get-Location).Path, 'scripts', 'Test-PaceRV.ps1'))
    if ($LASTEXITCODE -ne 0) { throw 'Release verification failed.' }
} catch { Write-Error $_; exit 1 }
```

The native Pango simulation models are obtained from a separately installed PDS distribution. They are not redistributed here. The portable core-level tests use Icarus Verilog and do not need PDS.

## Contributing

Use the release tag as the reference for published measurements. Develop RTL changes in a new branch, run the core-level tests, and report the exact configuration and tool versions with new measurements. VexRiscv is a separate processor; this release does not change or depend on its upstream implementation.
