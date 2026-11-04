# 项目来源、论文与仓库分工

## 竞赛交付与源仓库

本仓库是 **2026 嵌赛 FPGA 创新设计赛道**的作品入口。交付板卡统一为盘古 **100Pro+ / PG2L100H-6IFBG676**，CPU 性能工程与音频应用采用各自对应的完整工程配置。

| 内容 | 本仓库路径 | 开发来源 |
| --- | --- | --- |
| Original 155.25 MHz CPU | `hardware/code/bare_cpu/performance_155250/` | [源仓库 DYH 分支](https://github.com/BXSYGJ/ZGTC_RISC_CPU/tree/DYH)及冻结 CPU 发布材料 |
| H3 Base 145.125 MHz CPU | `hardware/code/bare_cpu/efficiency_145125/` | [源仓库 DYH 分支](https://github.com/BXSYGJ/ZGTC_RISC_CPU/tree/DYH)及冻结 CPU 发布材料 |
| 音频、NPU、DDR3、HDMI、控制程序 | `hardware/code/system_application/` | [源仓库 XSY/instrec_fpga 分支](https://github.com/BXSYGJ/ZGTC_RISC_CPU/tree/XSY/instrec_fpga) |
| 构建、固件复现和测量工具 | `hardware/tools/` | 统一便携交付工具 |

音频硬件依赖对应提交 [`3b265bde6e9ca727f24d02fc641dd72de6666895`](https://github.com/BXSYGJ/ZGTC_RISC_CPU/commit/3b265bde6e9ca727f24d02fc641dd72de6666895)。模型参数来源、校验值和部署镜像关系见 [model_provenance.json](../hardware/code/system_application/docs/evidence/model_provenance.json)。源码包中的原始 HDL 清单见 [original-hdl-manifest.json](../hardware/docs/validation/original-hdl-manifest.json)。

## 相关论文

Yihang Dai, Shuyu Xu, Yinfeng Zhou, Chenglei Peng. **Memory Admission and Result-Retention Sizing in an RV32IMC FPGA Soft Processor**. 获 **19th IEEE McSoc**（2026）正式录用。

- [arXiv 预印本：2611.02974](https://arxiv.org/abs/2611.02974)
- [论文复现材料](https://github.com/BXSYGJ/PaceRV-MCSoC2026)

论文研究内存请求接纳与算术结果有效期之间的关系；竞赛作品进一步整合高性能 CPU、音频采集、神经网络加速和可视化。论文材料与竞赛完整系统分别组织，便于按需阅读和复现。

## 测试与后续实验

13 个配置包含两套 CPU 的 V0/V1 固件、完整音频系统和独立诊断工程。默认构建入口统一使用 PG2L100H / FBG676；初始化文件、引脚约束和模型镜像随源码提供。每次构建记录输入哈希，每次串口采集保存原始数据及机器可读测量结果。

具体已执行项目见 [PACKAGE_STATUS.md](../hardware/docs/PACKAGE_STATUS.md)，新电脑环境与实验命令见 [BUILD_AND_RUN.md](../hardware/docs/BUILD_AND_RUN.md)。
