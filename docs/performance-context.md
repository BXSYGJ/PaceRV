# CoreMark performance context

PaceRV Retained achieves **3.442075 CoreMark/MHz** in the included 6,000-iteration FPGA execution; the Base implementation achieves 3.441903. Both preserve the complete RV32IMC system described in the release.

The relevant comparison scope is **single-issue, five-stage, RV32IMC FPGA soft processors**. A claim about the best result within that scope requires checking all four attributes and the benchmark configuration. Per-MHz scores published by other projects are independently reported results, not matched experiments.

## Public sources checked on 28 October 2026

| Processor / source | Reported CoreMark/MHz | Scope information |
|---|---:|---|
| PaceRV Retained | 3.442075 | Single-issue, five-stage RV32IMC; complete FPGA system; included board evidence |
| VexRiscv, feature-matched paper configuration | 2.742514 | RV32IMC FPGA comparison used in the paper; configuration-specific result |
| rkottomt/rv32imc-pipelined-core | 2.88 | Five-stage RV32IMC FPGA core/SoC; independently reported result |
| LEVEL | 2.62 | Five-stage RV32IMC; current upstream result is RTL simulation, with FPGA bring-up paused |
| Pequeno R5, MDSP Performance++ | 2.65 | Five-stage FPGA soft core; RV32IM, so outside the exact RV32IMC scope |
| Configurable five-stage core, Electronics 13(1), 120 (2024) | 3.51 | RV32IM paper; outside the exact RV32IMC scope |
| Andes N25F | 3.57 | Commercial processor IP with additional extensions and ASIC implementation data; not a verified matching FPGA experiment |

Sources:

- https://github.com/SpinalHDL/VexRiscv
- https://github.com/rkottomt/rv32imc-pipelined-core
- https://github.com/kerimturak/level-v
- https://github.com/iammituraj/pequeno_riscv
- https://doi.org/10.3390/electronics13010120
- https://www.andestech.com/en/products-solutions/andescore-processors/riscv-n25f/

Within the matching FPGA implementations with numerical results verified in this search, PaceRV has the highest reported CoreMark/MHz. The release introduction states the measured **3.442 CoreMark/MHz** result; this dated comparison is not an exhaustive world-record certification. AIRISC's official brochure confirms five-stage RV32IMC FPGA implementations but does not provide a numerical CoreMark/MHz score, so its ranking remains unresolved.

AIRISC source: https://www.ims.fraunhofer.de/content/dam/ims/de/documents/Downloads/AIRISC%20-%20RISC-V%20CORESAIRISC%20CORES.pdf
