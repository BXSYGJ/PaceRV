# Licensing and dependencies

## PaceRV

The authors' processor RTL, peripherals, platform adapters, testbenches, scripts, and documentation are distributed under the root MIT license. Existing copyright notices are retained. The independently measured source snapshots are included without functional edits.

## CoreMark

CoreMark is maintained by EEMBC. Its source files and license are retained in each `firmware/V*/inputs/coremark/` directory, including the Apache-2.0 software license and EEMBC acceptable-use/trademark terms. The root MIT license does not replace these terms. The platform port is separate from the benchmark algorithms. No claim of EEMBC certification is made.

Upstream: https://github.com/eembc/coremark

## Pango Design Suite

PDS 2022.2-SP6.4, device support, and its simulation libraries are separately installed dependencies. Pango's `GTP_DRM36K_E1.v` and `GTP_GRS.v` carry proprietary notices and are **not included**. Full-system simulation accepts a local model directory and checks the expected SHA-256 values. Vendor primitive instantiations in the authors' RTL remain in the physical source snapshots.

## Toolchains and simulators

The repository does not redistribute a compiler, simulator, or PDS installer. Exact compiler flags are recorded in the recipes. Firmware reproduction uses xPack RISC-V GCC 10.2.0-1.2; native timed-memory simulation uses Verilator 5.032; the small core-level tests use Icarus Verilog. Obtain these tools from their upstream distributions under their respective licenses.

- https://github.com/xpack-dev-tools/riscv-none-embed-gcc-xpack/releases/tag/v10.2.0-1.2
- https://github.com/verilator/verilator/releases/tag/v5.032
- https://github.com/steveicarus/iverilog

## Paper

The associated MCSoC paper has a separate publication and copyright agreement. The repository contains bibliographic metadata and links; the code's MIT license does not license the paper.
