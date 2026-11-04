# PaceRV 与音频智能计算系统 · 100Pro+ 源码包

作品使用盘古 **100Pro+** 开发板，FPGA 为 **PG2L100H-6IFBG676**。本包统一提供该板的工程配置、引脚约束、CPU 固件、音频模型、初始化文件和测试工具。

## 工程目录

| 路径 | 内容 | 正式构建入口 |
| --- | --- | --- |
| `code/bare_cpu/performance_155250/` | PaceRV Original：目标 155.25 MHz 的完整 RV32IMC SoC | `fpga/pds_soc_top.v` |
| `code/bare_cpu/efficiency_145125/` | PaceRV H3 Base：目标 145.125 MHz 的完整 RV32IMC SoC | `fpga/pds_soc_top.v` |
| `code/system_application/` | 音频采集、采样率转换、DDR3、Mel、INT8 NPU、控制 CPU、HDMI 界面 | `src/ctrl/instrec_top.v` |
| `tools/` | PDS 构建、固件重建、UART 采集与源码包校验 | 见下方命令 |

`bare_cpu` 沿用原目录名，两套工程均保留缓存与 SoC 外设。正式 CPU 顶层已连接 PLL 并显式设置测试参数。

## 快速开始

安装 PDS 2022.2-SP6.4 和 Python 依赖，设置 `PDS_ROOT` 与本机许可证后，在本目录运行：

```powershell
python tools/verify_package.py
pwsh -File tools/Build-PDS.ps1 -Project performance_155250_V0 -PrepareOnly
pwsh -File tools/Build-PDS.ps1 -Project performance_155250_V0 -StopAfter compile
pwsh -File tools/Build-PDS.ps1 -Project efficiency_145125_V0 -StopAfter compile
pwsh -File tools/Build-PDS.ps1 -Project application_full -StopAfter compile
```

去掉 `-StopAfter compile` 可生成位流。全部 **13 个工程配置**定义在 [projects.json](projects.json)，构建输出位于 `build/`。CPU 的 V0/V1 固件均运行 6,000 次 CoreMark；CPU 性能工程 UART 为 9,600 baud，音频应用为 115,200 baud。

- [完整构建、烧录、测量和模型使用说明](docs/BUILD_AND_RUN.md)
- [本次验证结果与工程状态](docs/PACKAGE_STATUS.md)
- [源码包完整性校验工具](tools/verify_package.py)

## 已包含的配套材料

- 两套 CPU 的板级顶层、100Pro+ 约束、PLL、固件源码、链接脚本、编译参数、V0/V1 镜像及参考串口输出。
- 音频工程的 DDR3 / PLL IP、控制固件、Mel / FFT 查找表、中文字体、UI 初始化文件。
- 模型训练、量化和评估代码，部署参数、预生成权重镜像及 UART 上传工具。
- 协议、计算模型、权重与 RTL 仿真测试，以及相应参考数据。

本次已完成依赖核对、两套 CPU 与音频顶层的 PDS 编译，以及 56 项功能测试。155.25 / 145.125 MHz 是本包工程的目标时钟；新配置的时序、资源与板级性能以随后实际生成的位流及测量为准。

## 开源与提交

- 项目仓库：<https://github.com/BXSYGJ/ZGTC_RISC_CPU>
- CPU 发布分支：<https://github.com/BXSYGJ/ZGTC_RISC_CPU/tree/DYH>
- 音频应用分支：<https://github.com/BXSYGJ/ZGTC_RISC_CPU/tree/XSY/instrec_fpga>
- PaceRV：<https://github.com/BXSYGJ/PaceRV>

应用依赖来源为 XSY 提交 `3b265bde6e9ca727f24d02fc641dd72de6666895`。本源码包在 PaceRV 竞赛仓库的 `hardware/` 目录发布。第三方 IP 保留原始版权与许可说明，按供应商许可使用。

主办方要求全部代码以 **RAR、200 MB 以内**提交，并按企业指南提供实际工程分支的 GitHub 链接。官方要求：<http://www.fpgachina.cn/notice-details.html?id=58>（2026-11-04 核对）。训练数据集及开发软件、许可证按使用说明另行安装。
