# InstRec-FPGA Verilator 仿真体系（sim/）

> 目标：**改一行 RTL → 几十秒内拿到数值结论**，替代当前「改 RTL → PDS 构建 7~15 分钟
> → 烧板 → 串口比对」的慢回路。所有 TB 直接例化 `src/` 下的真实模块，不再使用
> `top_npu_conv1_test` / `top_mel_test` 这类脚手架顶层——2026-10-31 的两轮板级 FAIL
> 全部出自脚手架（conv1 的 contract 地址映射、mel 的假 DDR3 只应答 4/516 条命令），
> 而不是被测引擎本身。

## 1. 快速开始

```powershell
cd instrec_fpga

python sim/run_sim.py --list                 # 查看全部 TB 与超时
python sim/run_sim.py self_test              # 单个 TB（PASS 退出码 0，FAIL 非 0）
python sim/run_sim.py conv1
python sim/run_sim.py all --jobs 6           # 并行跑全部，打印汇总表
python sim/run_sim.py mel --keep             # 保留波形（--trace，较慢）
python sim/run_sim.py all --jobs 6 --clean   # 强制重新生成 C++ 模型
```

一条 `all --jobs 6` 会输出类似：

```
====================================================================================================
TB             RESULT   TIME      FIRST FAILURE / NOTE
----------------------------------------------------------------------------------------------------
self_test      PASS     28.6s
conv1          FAIL     23.4s     FIRST_MISMATCH row=0 grp=0 col=111 ch=0 expected=0 observed=17
...
total 95.3s | pass 4 | fail 2 | skip 1 | jobs 6
```

- 产物集中在 `build/sim/<case>/`（已被 `instrec_fpga/.gitignore` 的 `build/` 覆盖），
  **不在源码目录产生 `obj_dir`**。
- 每个 case 的完整编译/运行日志在 `build/sim/<case>/run.log`，汇总写入
  `build/sim/summary.txt`。
- 退出码：全部 PASS（SKIP 不算失败）= 0，否则 = 1。

## 2. 为什么不是一句 `verilator --binary`

Verilator 的 `--binary` 每次都会重新编译 C++ 运行时（`verilated.cpp` +
`verilated_timing.cpp` + `verilated_threads.cpp`），g++ 16.2 下约 **33 秒**，还没算
RTL。`run_sim.py` 把它拆成两步：

1. `verilator --cc --exe --main --timing` 只生成 C++ 模型（1~3 s）；
2. 把**共享运行时对象缓存**（`build/sim/_runtime/*.o`，首次调用构建一次）拷进
   每个 case 自己的 `obj`，再 `mingw32-make -j 4` 只编译生成的模型并链接（5~15 s）。

因此单 TB「编译 + 运行」从 ~40 s 降到 20~30 s，且多个 TB 并行时互不干扰
（每个 case 独立 `obj` 目录，缓存只读复制）。

> 缓存首次构建约 25~35 s，只发生一次；`build/` 被清理后会自动重建。

## 3. TB 矩阵

| case | 被测 | 数据来源 | 判据 |
|---|---|---|---|
| `self_test` | `src/ctrl/self_test.v` + 4 KB 行为级 DDR3 | 无（自带 pattern） | 16 命令全 PASS、写/读 abort 各自 `st_fail_addr` 正确、`cmd_valid` 为电平保持 |
| `conv1` | `conv_engine` + `requant_unit` | `hex_conv1/*.hex` + `reports/golden_ref/sine_440_full/conv1.npy` | 792,576 个 u8 全量逐值比对，`mismatch==0` |
| `mel` | `mel_engine`（全链：framer/FFT/mel/db/standardize） | `tests/fixtures/sine_440_full.wav` → 行为级 m2 PCM 源 | **FILL_CREDIT=1025 必须复现死锁**（cmds=4 / accepted=1024 / frames=0） |
| `mel_credit` | 同上，`FILL_CREDIT=1280`（构建目录副本覆盖） | 同上 | 516 条命令、132,096 样本、16,512 feat 与 `feat.npy` 逐字节一致 |
| `weight_loader` | `src/ctrl/weight_loader.v` + m1 行为模型 | `build/sim/weight_loader/payload.hex` | 4×`K`、`WOK <digest>`、digest 与字节模型一致、CRC 错给 `N` |
| `ctrl_smoke` | `sys_ctrl` + `uart_debug` | 无 | 控制台按序出现 `BOOT` / `DDR3 SELFTEST` / `DDROK` / `DDR3 STS`，且 `sys_run=1`、`safe_err=0` |
| `npu_chain` | `gap_unit` → `fc1` → `fc2` → `softmax_top` | `pool4/gap/fc1/fc2_logits/probs.npy` + `weights_image.bin` | 四级逐值比对 |
| `ui_render` | `ui_renderer` + `ui_overlay` + `waveform_disp` | 无 | 四层优先级 bars>text>spec>base、rgb/de 4 拍对齐 |
| `ddr3_subsys` | `ddr3_ctrl_axi` + `ddr3_arbiter` + `self_test` | T28 交付的 TB | 未交付时显示 `SKIP`，不拖垮其它 case |

## 4. 加新 TB 的三步

1. 在 `sim/` 新建 `tb_<name>.sv`，**直接例化 `src/` 模块**；
   - 用 `` `timescale 1ns/1ps ``；
   - 只用 `initial` + `always` + `#delay`，不要 SV-2012 语法；
   - 结尾打印 `RESULT: PASS <name>`（退出 0）或 `RESULT: FAIL <name> ...`
     + `$fatal(1, ...)`（退出非 0）。
2. 在 `sim/run_sim.py` 的 `register(...)` 区加一条 `Case`：
   ```python
   register(Case(
       name="my_case",
       tb="tb_my_case.sv",
       rtl=["src/path/module.v", ...],
       timeout=300,
       prepare="my_data",          # 可选：golden 数据准备
       description="one line",
   ))
   ```
3. 若需要 golden 数据，在 `PREPARERS` 里加一个 `def prepare_my_data(work: Path)`，
   负责把 `.npy/.wav` 转成 `$readmemh` 表（`write_hex(path, values, digits)`）。
   所有 prepare 在并行启动前**串行执行一次**，共享表不会竞争。

## 5. 参数覆盖（不改仓库源文件）

Verilator 的 `-G` 只能覆盖 `parameter`，覆盖不了 `localparam`。`Case` 提供两种机制：

```python
# 1) 预处理源文件副本（只改 build/sim/<case>/rtl/，src/ 原封不动）
overrides=[("src/mel/mel_engine.v",
            r"localparam integer FILL_CREDIT\s*=\s*1025;",
            "localparam integer FILL_CREDIT    = 1280;")]

# 2) 编译期宏（TB 里用 `ifdef 分支）
defines=["WRONG_CTR_MAP"]

# 3) 直接给 verilator 传额外参数
extra_flags=["--public"]      # 允许 TB 读 DUT 内部计数（mel 的 frm_out / pc_credit）
```

`overrides` 要求正则**恰好命中 1 次**，否则直接报错退出——防止悄悄改错文件。

## 6. 自证（TB 有效性）方法

只跑 PASS 不能证明 TB 真的在看数据；每个 TB 都设计了「注入已知错误必须 FAIL」的路径：

| TB | 注入方法 | 期望 |
|---|---|---|
| `self_test` | 运行前把 TB 里 `wb_abort_at` 改成 `3`（或 `rb_abort=1`）后跑 T1 | T1 变 FAIL，T2 的 `st_fail_addr` 检查仍 PASS → 证明 abort 检查器有效 |
| `conv1` | `python sim/run_sim.py conv1` 前在 `run_sim.py` 的 conv1 case 加 `defines=["WRONG_CTR_MAP"]` | 复现板级分布：grp1 大量 255、grp2 趋 0，`FIRST_MISMATCH` 从 row0 起始 |
| `mel` | 默认 case 本身就是 1025（真实死锁） | 打印 `DEADLOCK_REPRODUCED`，`mel_credit`（1280）跑完并逐字节对拍 |
| `weight_loader` | 把 `send_frame(0, 1'b0)` 改成 `1'b1`（损坏 CRC）同时删掉 B 段 | A 段应 FAIL（拿不到 `WOK`），证明 digest/CRC 检查器有效 |
| `ctrl_smoke` | 把 `TX_GAP` 设成 0（1 拍就绪的假 sink） | 仍应 PASS；反之把 sys_ctrl 的 `!dbg_busy` 门槛去掉，DDROK 检查应 FAIL |
| `npu_chain` | `fc2` 例化的 `ZP_OUT` 改 56，或 softmax 里去掉 `-57` | fc2/probs 段失配 |
| `ui_render` | 交换 `ui_overlay` 里 bars/text 判断顺序（仅构建目录副本） | `x=0..9` 窗口优先级的 check FAIL |

`conv1` 的 `WRONG_CTR_MAP` 宏在 TB 内实现：正确映射为
`ctr[grp*16+c] / ctr[48+grp*16+c] / ctr[96+grp*16+c]`；错误映射（板级原始版本）为
每组连续读 48 字 `ctr[grp*48+c_step]`。这正是 T25 修掉的缺陷形态。

## 7. 已知 RTL 问题（只报告，未改源）

1. **`src/ctrl/self_test.v` 重复声明 `wdata`**
   `output wire [255:0] wdata` 之后又写了 `wire [255:0] wdata;`（第 136 行）。
   PDS 容忍，Verilator 直接 `%Error: Duplicate declaration`。
   `run_sim.py` 用 `overrides` 在 `build/sim/self_test/rtl/` 去掉该行（语义不变），
   **仓库源文件未改**。建议后续按 RTL 规范修掉。
2. **`conv1` 数值失配（仿真已定位）**
   `stream_samples=792576` 正确，`mismatch=143754`；首个失配
   `row=0 grp=0 col=111 ch=0 expected=0 observed=17`，之后每列失配数近似恒定。
   分通道统计均匀（不是三组参数错位那种 grp1 饱和/grp2 趋 0 的形态），
   指向 `conv_engine` 行缓冲/窗口边界，而不是 contract 地址映射。T25 的修复
   针对的是 `top_npu_conv1_test.v` 的映射，因此**不能**消除本项。
3. **`mel_engine` FILL_CREDIT=1025 死锁**
   4 条读命令后 `pc_credit=1 < 256`，framer 永远凑不满 1025 样本，`frame_fft_done`
   不再补充 credit → 200 ms 看门狗。1280 即满足 `1025 + 256`（PH_FILL + 一个命令），
   与 T26 的结论一致。

## 8. 这套仿真能不能替代「构建 + 烧板」

可以替代**数值/协议层**的定位：

- 能直接看到 `(row, group, col, channel, expected, observed)` 级别的失配，而不只是
  「串口 30 字节 / 没有 DDROK」；
- 能在 30 秒内验证「改一行 RTL 是否真的修好了」，而构建一圈要 7~15 分钟且要抢
  `pds_shell.exe` 与 JTAG 单实例；
- `tb_ctrl_smoke` 能证明「自检 PASS 时 DDROK 一定发得出来」——这正是 m4fix 板级
  两次无法区分的那条二义性。

**不能**替代的：

- 时序收敛 / WNS、DRM/APM 资源、引脚约束、CDC 与真实 DDR3 PHY 电气行为；
- 真实 I2S 采样、HDMI 输出、板级上电顺序。
  这些仍必须走 PDS + 烧板，仿真只保证「逻辑与数值是对的」。

## 9. 约束

- 本目录**只新增** `sim/*`，不修改 `src/**`、`scripts/**`、`tests/**`、`constraints/**`。
- 所有 TB 使用 SystemVerilog 子集（`always @*`、`always @(posedge)`、`initial`、
  `task/function`），`--binary --timing` 下 Verilator 5.050 可直接编译。
- 不跑 PDS、不碰 `cdt_js`；仿真与构建可并行，不占用构建槽位与 JTAG。