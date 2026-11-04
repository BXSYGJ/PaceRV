# 八类模型训练、评估与部署

本目录保存固定八类InstrumentCNN、原始FP32检查点、INT8 TorchScript及转换所需权重。数据集音频与数GB特征缓存由使用者准备，不纳入源码。最佳检查点epoch=6、验证准确率93.9611%；完整来源与文件hash见`../docs/evidence/model_provenance.json`。

## 数据与环境

从Medley-solos-DB官方发布取得音频及`Medley-solos-DB_metadata.csv`，保持原始subset和instrument_id。音频放在`data/raw/medley_wav/`。缓存读取支持官方双`.wav.wav`命名。按track_id检查training、validation、test不交叉；数量为5841/3494/12236。不得自行随机重划分后沿用已有指标。

在本目录执行，建议Python 3.12虚拟环境：

```powershell
python -m venv .venv
.venv/Scripts/Activate.ps1
pip install -r requirements.txt
```

原训练环境为PyTorch 2.3.1+cu121及GTX 1050 Ti；需要GPU时，先从PyTorch cu121官方索引安装torch/torchaudio同版本，再安装其余依赖。CPU环境可评估／转换，但不能把不同后端数值差异当作硬件golden。

## 训练与评估

```powershell
python -m src.cache_features --wav-dir data/raw/medley_wav --csv-path Medley-solos-DB_metadata.csv --cache-dir data/cache
python -m src.train --epochs 50 --batch-size 64 --lr 0.001 --patience 10 --seed 42 --no-amp --output-dir outputs/retrain
python -m src.evaluate --checkpoint runs/best_model.pt --batch-size 64 --output-dir outputs/evaluation
```

训练源使用逆频率加权采样、加权交叉熵、Adam(weight_decay=1e-4)和余弦退火，关闭SpecAugment，以验证准确率选最佳检查点。程序默认输出`runs/`，务必使用上述`--output-dir`保存重训结果，避免覆盖已冻结的`runs/best_model.pt`。

**复现口径：** 原项目后续实验覆盖了配置文件；检查点能验证网络权重、epoch、Adam状态与余弦调度参数，不能恢复全部数据增强、batch、seed和早停设置。上面的batch=64、seed=42、patience=10是明确的复现配置，不能承诺生成同一检查点或同一准确率。后续FocalLoss／SpecAugment失败实验指标不属于本模型。已报道FP32准确率77.8359%与INT8准确率77.3701%绑定归档模型和历史评估JSON，本轮未重新跑完整数据集。

## 量化及硬件转换

```powershell
python -m src.quantize --checkpoint runs/best_model.pt --num-calibration-samples 500 --quant-method static --output-dir outputs/requantized
```

采用fbgemm静态量化，Conv-BN-ReLU及FC1-ReLU融合；权重per-channel symmetric qint8、激活per-tensor affine quint8。清理副本校准默认不增强；原始量化配置未记录全部随机状态，重新量化会生成新的模型，不能自动替换固定部署资产。

在`instrec_fpga/`运行：

```powershell
python scripts/verify_model.py
python scripts/gen_weight_image.py --instrec-root training --outdir build/weight-reexport
```

后者在临时目录重新导出，成功后应核对`weights_image.bin`是否与固定镜像相同。新版PyTorch的oneDNN／fbgemm实现可能造成探针LSB差异；已有镜像及`layer_contract.json`是此版本硬件部署依据，不自动覆盖。`deploy/weights/*_bias_int32.npy`为原始导出中间文件，生成器会从TorchScript重建偏置，禁止直接上传这些偏置文件。

源码整理删除普通注释／文档字符串，移除双头网络，训练流程固定为加权CE；已保存模型字节保持原样。`src/quantize.py`中生成单音频推理脚本的字符串属于导出功能。依赖检查和模型结构验证不等于重新训练／重新测试。
