# CPU 流水线观测波形

本目录提供 Original 与 H3 Base 在 CoreMark 链表、矩阵和状态机函数中的局部执行窗口，每组包含 1,024 点总览、触发点放大图及原始 / 解码 CSV。

这些图来自**本地 RTL 仿真**，横轴为采样 CPU 边沿，用于观察 PC、指令及流水线状态之间的对应关系。它们与完整基准的性能测量分别组织。数据来源、固件标识及文件 SHA-256 见 [observation-provenance.json](observation-provenance.json)。

| 配置 | 链表 | 矩阵 | 状态机 |
| --- | --- | --- | --- |
| Original 155.25 MHz 配置 | [窗口](Original_155250/analysis/core_bench_list/trigger-zoom.png) | [窗口](Original_155250/analysis/core_bench_matrix/trigger-zoom.png) | [窗口](Original_155250/analysis/core_bench_state/trigger-zoom.png) |
| H3 Base 145.125 MHz 配置 | [窗口](H3_Base_145125/analysis/core_bench_list/trigger-zoom.png) | [窗口](H3_Base_145125/analysis/core_bench_matrix/trigger-zoom.png) | [窗口](H3_Base_145125/analysis/core_bench_state/trigger-zoom.png) |
