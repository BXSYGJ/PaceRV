# Build and test PaceRV

## 1. Tools

Install Git, PowerShell 7+, and Icarus Verilog for the portable core tests. Physical implementation needs licensed **PDS 2022.2-SP6.4**, PG2L200H-6FBB676 support, and the board's JTAG/UART drivers. Firmware and native system simulation use WSL2/Linux with make, G++, Perl, xPack RISC-V GCC **10.2.0-1.2**, and Verilator **5.032**.

Download the compiler and simulator from the upstream links in [third-party notices](../THIRD_PARTY_NOTICES.md). The original compiler archive is `xpack-riscv-none-embed-gcc-10.2.0-1.2-linux-x64.tar.gz`, 572,296,735 bytes, SHA-256 `d72bdcd1eee41dc5a208a8a03976b70d014510deb5890c9e8738e804ba23f985`.

Clone `https://github.com/BXSYGJ/PaceRV.git` and run the commands below from the checkout root. All build outputs go in `.work/`, leaving the frozen releases intact. Use a fresh output directory for each physical, firmware, or full simulation run.

## 2. Verify evidence and execute RTL tests

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    $repo = (Get-Location).Path
    & ([System.IO.Path]::Combine($repo, 'scripts', 'Test-PaceRV.ps1'))
    if ($LASTEXITCODE -ne 0) { throw 'Archive verification failed.' }
    & ([System.IO.Path]::Combine($repo, 'scripts', 'Test-RTL.ps1'))
    if ($LASTEXITCODE -ne 0) { throw 'RTL tests failed.' }
} catch { Write-Error $_; exit 1 }
```

The multiplier test checks arithmetic against an independent oracle. Four core runs cover both admission modes and both one-edge and retained validity, with eleven scenarios each. These tests do not use a vendor memory model.

## 3. Prepare and build the FPGA project

Choose `H3_Base_145125` or `H3_Retained_145125`, and `V0` (performance) or `V1` (validation). This command prepares the project without launching PDS:

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    $repo = (Get-Location).Path
    $release = [System.IO.Path]::Combine($repo, 'cpu', 'H3_Base_145125')
    $scripts = [System.IO.Path]::Combine($repo, 'cpu', 'release-support', 'scripts')
    & ([System.IO.Path]::Combine($scripts, 'Build-PhysicalProject.ps1')) -ReleaseRoot $release -Role V0 -OutputDirectory ([System.IO.Path]::Combine($repo, '.work', 'physical-base-V0')) -PrepareOnly
    if ($LASTEXITCODE -ne 0) { throw 'Physical preparation failed.' }
} catch { Write-Error $_; exit 1 }
```

To synthesize and route, use another fresh output directory, remove `-PrepareOnly`, and add `-PdsRoot $env:PDS_ROOT`, where `PDS_ROOT` points to your installed PDS root. The script applies the frozen device, firmware, clock, constraints, and place-and-route options, then audits timing and generates a bitstream.

The saved images use **AC26/AB26 UART pins**. Check `physical/V0/inputs/constraints/` against your board before programming. `-UartPins LocalBoard` selects B24/C24 and requires a new build; choose pins according to the actual PCB.

## 4. Rebuild firmware

`Build-Firmware.ps1` takes `-ReleaseRoot`, `-Role`, `-OutputDirectory`, and `-GccLinuxPath`. The compiler argument is an absolute path to `riscv-none-embed-gcc` inside WSL. Use the same PowerShell calling pattern as above. Compiler options come from the release recipe. The script checks that the resulting HEX matches the frozen firmware exactly.

## 5. Native timed-memory simulation

Find `GTP_DRM36K_E1.v` and `GTP_GRS.v` in your licensed PDS installation, and provide their common parent directory using `-NativeModelDirectory`. They remain local and are not committed to this repository. Required model hashes are in `recipe.json` under `simulation.external_models`.

`Run-Simulation.ps1` takes `-ReleaseRoot`, `-Role`, `-OutputDirectory`, `-VerilatorLinuxPath`, and `-NativeModelDirectory`. Supply `-VerilatorIncludeLinux` if needed by an extracted/custom Verilator installation. `-CompileOnly` stops after compiling; omitting it executes the full 6,000-iteration benchmark and verifies its UART frame. Model paths must be on a local Windows drive accessible to WSL. The simulation recipe includes `--timing` and the frozen observer/driver settings.

## 6. Board execution

Program the matching `cpu/<release>/bitstreams/V0.sbit` or `V1.sbit` with the PDS programmer. UART uses **9600 baud, 8N1, no flow control**. With the correct board and pins, start `Capture-BoardUART.ps1` using `-ReleaseRoot`, `-Role`, `-PortName COM5` (replace as needed), and a fresh `-OutputDirectory`, then reset the board. The script waits for READY, sends G, and compares the complete benchmark frame to the frozen reference. Repeat three cold starts per image.

`Audit-BoardCapture.ps1` also checks an existing capture using `-RawCapture` and `-OutputPath`. Complete architectural counts and CRC output must match; a partial UART frame is not accepted.

## 7. Develop a new configuration

Create a separate branch/workspace. The `source/`, `simulation/inputs/`, and `physical/V*/inputs/` snapshots have distinct roles. Change the inputs used by the runner you are invoking, and keep corresponding simulation/physical RTL consistent. Preserve the release tag for the published measurements and produce new evidence for each changed image.
