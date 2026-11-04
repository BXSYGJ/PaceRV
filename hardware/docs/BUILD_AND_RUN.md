# 100Pro+ 工程构建与测试

本包面向盘古 100Pro+，器件为 **PG2L100H-6IFBG676**。CPU 与音频应用共用这块板，分别下载对应工程。全部构建入口以包内文件为依据，不依赖原电脑的工作目录。

## 1. 开发环境

- Windows、PowerShell 7+、Python 3.10+。
- Pango Design Suite 2022.2-SP6.4，安装 Logos2 / PG2L100H 器件支持并配置有效许可证。
- CPU 固件复现：xPack RISC-V Embedded GCC **10.2.0-1.2**，前缀 `riscv-none-embed-`。包内已提供可直接用于构建的 V0/V1 固件。
- 应用模型训练与权重重生成：另装 `code/system_application/training/requirements.txt` 所列依赖，包括 PyTorch。
- 完整 RTL 仿真：按应用 `sim/run_sim.py` 的配置安装 MSYS2、Verilator 和 Make；CPU 的测试平台在各 CPU 的 `tests/`、`sim/` 中。

以下命令在源码包根目录执行。PDS 和许可证路径按新电脑实际位置填写；许可证不随源码包分发。

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
try {
    python -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw '创建 Python 环境失败' }
    $python = [System.IO.Path]::Combine($PWD.Path, '.venv', 'Scripts', 'python.exe')
    & $python -m pip install -r requirements.txt
    if ($LASTEXITCODE -ne 0) { throw '安装依赖失败' }
    $env:PATH = [System.IO.Path]::Combine($PWD.Path, '.venv', 'Scripts') + [System.IO.Path]::PathSeparator + $env:PATH
    $env:PDS_ROOT = [System.IO.Path]::Combine('C:/', 'Pango', 'PDS_2022.2-SP6.4')
    $env:PANGO_LICENSE_FILE = [System.IO.Path]::Combine('C:/', 'Pango', 'license', 'pds.lic')
    python tools/verify_package.py
    if ($LASTEXITCODE -ne 0) { throw '源码包校验失败' }
} catch {
    Write-Error $_
    exit 1
}
```

## 2. 生成与编译 FPGA 工程

`projects.json` 定义源文件、IP、约束、固件、顶层和布局布线参数。先检查依赖，再编译：

```powershell
pwsh -File tools/Build-PDS.ps1 -Project performance_155250_V0 -PrepareOnly
pwsh -File tools/Build-PDS.ps1 -Project performance_155250_V0 -StopAfter compile
pwsh -File tools/Build-PDS.ps1 -Project efficiency_145125_V0 -StopAfter compile
pwsh -File tools/Build-PDS.ps1 -Project application_full -StopAfter compile
```

去掉 `-StopAfter compile` 即执行综合、映射、布局布线、时序报告和位流生成。一次运行一个 PDS 工程。输出在 `build/<工程名>/`，其中 `build.tcl` 是生成的批处理，`inputs.json` 固定输入哈希，`pds-console.log` 保存工具日志，`result.json` 记录所选工具阶段是否完成。使用 `python tools/build_project.py <工程名> --output <独立目录>` 可隔离新的实验。

CPU 工程分为 `performance_155250_V0/V1`、`efficiency_145125_V0/V1`；V0 是性能运行，V1 是验证运行，均固定 6,000 次迭代。正式顶层为 `fpga/pds_soc_top.v`，已连接 PLL 并显式设置 RV32IMC、缓存、预测和时钟参数。通用模块 `rtl/rv32_board_top.sv` 的默认参数不等于正式工程配置。

CPU 板级约束在各自 `constraints/board_100proplus.fdc`：27 MHz 输入时钟 D18、复位 C22、按键 C23、UART RX B24、TX C24；设置 0.150 ns setup uncertainty。应用采用包内 `instrec`、`ddr3_100h` 和时钟组约束。请按约束连接硬件。

音频完整功能用 `application_full`。另有 DDR3、UI、卷积、Mel、CPU、PCM1808 等独立诊断工程；`application_emergency_demo` 是独立的应急演示模式，不代替完整音频推理工程。

155.25 / 145.125 MHz 是工程的目标时钟。首次在新器件工程上生成位流后，应核对 `report_timing` 的所有时序要求及资源报告，再下载测试。编译成功只表示源文件与 IP、约束可被 PDS 接受。

## 3. CPU 上板与 CoreMark

用 PDS Programmer 扫描 JTAG，选择本次生成的 `build/<工程名>/generate_bitstream/pds_soc_top.sbit` 下载到 100Pro+。连接 UART 后，在包根目录执行：

```powershell
python tools/capture_cpu.py performance_155250 --role V0 --port COM5 --output build/captures/performance_V0_run1
python tools/capture_cpu.py efficiency_145125 --role V0 --port COM5 --output build/captures/efficiency_V0_run1
```

串口为 **9,600 baud、8N1**。工具打开串口后按板上复位；收到 `ZGTC COREMARK READY` 后自动发送 `G`。V1 必须先下载对应 V1 位流，再以 `--role V1` 采集。输出目录须为新目录，避免覆盖前次原始数据。

工具保存 `uart.bin`，核对完整起止帧、所选固件对应的全部 UART 字节、64 位 cycles/retired 计数和不少于 10 秒的运行时长，并生成 `measurement.json`。结果公式为 `CoreMark = iterations × clock_hz / cycles`，`CoreMark/MHz = iterations × 10^6 / cycles`。计数比对用于复现冻结参考；修改硬件或固件后，应独立检查算法输出，并重新建立参考。

`--capture-file <文件>` 只审核已有串口记录，不操作板卡。包内 `firmware/V0/uart.log`、`firmware/V1/uart.log` 为对应固件的参考输出。

重新编译固件：

```powershell
python tools/build_firmware.py performance_155250 --role V0 --prefix C:/Toolchain/bin/riscv-none-embed-
python tools/build_firmware.py efficiency_145125 --role V1 --prefix C:/Toolchain/bin/riscv-none-embed-
```

编译参数在各自 `firmware/recipe.json`，源码、启动代码、链接脚本和 CoreMark 移植层在 `firmware/V0/inputs/`、`firmware/V1/inputs/`。新镜像输出到 `build/firmware/`，同时打印参考和重建哈希。若要用于 FPGA 构建，明确更新工程清单中的镜像路径；脚本不覆盖冻结镜像。

## 4. 音频系统运行

下载 `application_full` 的 `instrec_top.sbit`。PCM1808 按 48 kHz 主模式连接，BCK U20、LRCK T20、串行数据 V16，并共地；其余 HDMI、DDR3、串口连接以包内板级约束为准。应用串口为 **115,200 baud**，不同于 CPU 性能工程。

在 `code/system_application/` 执行：

```powershell
python scripts/board_check.py --sbit ../../build/application_full/generate_bitstream/instrec_top.sbit --port COM5 --seconds 15 --expect "RV32 BOOT" "RV32 MMIO OK" "DDROK"
python scripts/weight_upload.py --port COM5 --image scripts/outputs/weights_image.bin
```

`board_check.py` 使用 `PDS_ROOT` 定位 Programmer。权重工具通过 UART 上传镜像；收到确认后由控制固件调度推理。权重存储复位后需要重新上传。启动判定由顶层使能与 CPU 请求共同决定，不能只读一个参数判断运行流程。

`src/cpu/prog.hex` 是已提供的控制固件。重建时设置 `RV32_TOOLCHAIN`，运行 `python scripts/build_rv32_sw.py --no-m`，匹配应用控制核的 RV32I 配置及 8 KiB ROM/RAM。这里的控制核工程与性能测试的完整 RV32IMC 工程用途不同。

`training/` 包含训练、量化和评估代码及模型参数；`scripts/gen_weight_image.py` 默认从本包 `training/` 读取部署参数，生成权重镜像。训练数据集获取方法见 `training/README.md`，数据集不包含在包内。

## 5. 本地验证

在 `code/system_application/` 运行已验证的协议与计算模型测试：

```powershell
python -m pytest -q tests/test_pcm1808.py tests/test_weight_upload.py tests/test_uart_frames.py tests/test_requant_model.py tests/test_pool_gap_model.py tests/test_npu_stream_model.py
python -m pytest -q tests/test_weight_image.py
```

第一组 50 项，第二组 6 项；第二组需要训练依赖。完整 RTL 仿真另由 `sim/run_sim.py` 驱动，可用 `--help` 查看用例；通过 `MSYS_ROOT`、`VERILATOR_BIN`、`MAKE_EXE` 指定本机安装位置。目录内还保留专项开发测试，应按各自文件说明配置环境与输入，不等同于上述最小回归集。

本次实际完成的检查及范围见 [PACKAGE_STATUS.md](PACKAGE_STATUS.md)。
