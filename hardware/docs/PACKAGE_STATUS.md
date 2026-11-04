# 源码包验证状态

整理日期：2026-11-04。板卡：盘古 **100Pro+**；目标器件：**PG2L100H-6IFBG676**。

## 已完成

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| 工程清单与静态依赖 | 13 / 13 配置通过 | HDL、IP、约束、固件和 ROM 初始化文件 |
| PDS 编译 | 3 / 3 通过 | `performance_155250_V0`、`efficiency_145125_V0`、`application_full` |
| 协议与计算模型回归 | 50 项通过 | PCM1808、权重上传、UART 帧、重量化、池化 / GAP、NPU 流模型 |
| 权重镜像回归 | 6 项通过 | 部署参数、镜像布局及重生成一致性 |
| 模型来源一致性 | 通过 | 685,864 参数检查点 → INT8 权重 → TorchScript → 六段镜像 |
| CPU 串口审核工具 | 4 份参考通过，4 份截断记录拒绝 | 两套 CPU 的 V0/V1 已有记录；未连接板卡 |
| 旧板卡名称检查 | 通过 | 交付内容中未检出旧板卡型号引用 |
| PowerShell 构建入口 | 语法通过，UTF-8 BOM | `tools/Build-PDS.ps1` |

PDS 版本为 2022.2-SP6.4。机器可读结果见 [validation/results.json](validation/results.json)。源码完整性由包根目录的 `SHA256SUMS` 和 `tools/verify_package.py` 检查。

## 配置与测量的对应关系

两套 CPU 保留原始 RTL，新增显式参数和 PLL 连接的正式板级顶层、100Pro+ 引脚约束及可迁移构建入口。音频工程补回匹配的初始化表、IP 配置、控制固件和部署模型。开发软件、许可证、外部训练数据集由使用者安装或获取。

本次 PDS 验证止于编译；尚未为这些新生成的工程配置完成布局布线和上板测量。目标 155.25 / 145.125 MHz 的时序、资源和 CoreMark 实测值应与后续生成的位流对应。已有固件及 UART 参考用于复现核对；串口审核工具的离线测试不计作新的上板测试。

完整 RTL 仿真和全部训练数据集评估未在本次整理中重新执行。已执行的最小回归命令及其环境说明见 [BUILD_AND_RUN.md](BUILD_AND_RUN.md)。

## 来源

- 原始手选 HDL 清单及 SHA-256：[validation/original-hdl-manifest.json](validation/original-hdl-manifest.json)。
- 音频硬件依赖：公开仓库 XSY 分支，提交 `3b265bde6e9ca727f24d02fc641dd72de6666895`；保留包内已有 RTL。
- CPU 依赖：本地冻结的 Original 155.25 MHz 与 H3 Base 145.125 MHz 发布材料；匹配 RTL 后提取固件、测试和顶层参数，并生成本包板级工程。
- 八类模型与部署工具：本地 `codex-instrec8-source-docs` 分支材料；来源记录见应用 `docs/evidence/model_provenance.json`。
- 供应商 IP 保留原始版权和保护声明。

构建缓存、工具许可证、临时文件和历史位流不进入交付压缩包。竞赛交付入口为 https://github.com/BXSYGJ/PaceRV ，源码位于 `hardware/`。
