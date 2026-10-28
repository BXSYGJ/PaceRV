# Associated paper

Yihang Dai, Shuyu Xu, Yinfeng Zhou, and Chenglei Peng, **Memory Admission and Result-Retention Sizing in an RV32IMC FPGA Soft Processor**, accepted at the 19th IEEE International Symposium on Embedded Multicore/Many-core Systems-on-Chip (MCSoC), 2026.

The conference paper studies admission-dependent arithmetic-result reuse, validity-window sizing, and prediction under changed memory service. PaceRV is the processor implementation used for its complete-system evidence. The earlier internal name H3 remains in frozen filenames and module/configuration records.

- Conference: https://mcsoc-forum.org/
- Implementation: https://github.com/BXSYGJ/PaceRV
- Paper reproducibility artifact: https://github.com/BXSYGJ/PaceRV-MCSoC2026
- arXiv identifier and proceedings DOI: to be added after assignment.

This repository releases the processor and its qualified implementation evidence. The separate [MCSoC reproducibility artifact](https://github.com/BXSYGJ/PaceRV-MCSoC2026) provides paper data, frozen forecasts, eight complete new-workload dependency profiles, 58 execution records, finite-window RTL, the matched VexRiscv configuration and reproduction commands. Its scripts recompute the main results and rerun 64 complete-profile forecasts against their frozen references.

Please cite the associated paper when using PaceRV in research. `CITATION.cff` records the authors and repository release metadata.
