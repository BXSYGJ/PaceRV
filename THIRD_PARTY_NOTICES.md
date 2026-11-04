# 版权、许可与第三方依赖

## 原创源码

团队原创 RTL、固件移植层、测试平台、构建脚本与技术说明采用根目录 MIT 许可。各文件原有版权声明继续有效。

## CoreMark

CoreMark 属于 EEMBC。基准源码及 `LICENSE.md` 保存在各 CPU 的 `firmware/V0/inputs/coremark/` 与 `firmware/V1/inputs/coremark/` 中，遵循其中的 Apache-2.0 与使用条款。根目录 MIT 许可不替代这些条款。

上游：https://github.com/eembc/coremark

## 紫光同创 IP 与工具

DDR3、PLL 及仿真依赖保留供应商的版权、保护与许可声明，适用供应商许可。包内工程描述与 IP 文件按 PDS 工作流程使用。PDS 安装程序、器件支持、编译器和许可证不随仓库提供。

## 模型与软件依赖

训练与部署依赖分别列于 `hardware/requirements.txt` 和 `hardware/code/system_application/training/requirements.txt`。外部数据集按其来源许可获取；模型来源与检查点校验记录见应用目录的 `docs/evidence/model_provenance.json`。

## 作品材料与标识

技术报告、PPT、海报与照片作为参赛作品材料提供。赛事标识、紫光同创标识和会议资料属于各自权利人；论文适用其作者与出版协议。源码的 MIT 许可不改变这些材料的权利归属。
