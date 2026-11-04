# Promoted mainline conv-layer regression

From instrec_fpga:

```powershell
python sim/experiments/conv_layers_mainline/run.py
python sim/run_sim.py conv1,npu_chain,npu_completion,rv_cpu,rv_top_ctrl --jobs 3 --verbose
```

The standalone runner regenerates each conv2..4 input and contract/tap
fixture from golden_pipeline, layer_contract.json and weights_image.bin.
It simulates src/npu/conv_engine.v + requant_unit.v with the shared
sim/tb_conv_layer.sv, then compares every output byte against golden.
Fixtures and binaries are isolated under build/sim/mainline_conv_layers;
old build/ml_conv and build/sim_L*_y.bin are preserved.

2026-11-01 after promotion from frozen 20261101-215059:

| Check | Output samples | Mismatches | Result |
|---|---:|---:|---|
| mainline conv1 | 792576 | 0 | PASS |
| mainline conv2 | 396288 | 0 | PASS |
| mainline conv3 | 196608 | 0 | PASS |
| mainline conv4 | 65536 | 0 | PASS |
| NPU tail GAP/FC1/FC2/softmax | 256/128/16 padded/8 | 0 | PASS |
| NPU forced sequencer completion twice | 8 probabilities each | - | PASS |
| CPU boot/MMIO/ISA/control/results/ack | C1..C9 | - | PASS |
| Exact top CPU launch slice and physical UART | 17 assertions | - | PASS |

The completion-only TB explicitly does not serve activation DDR: it forces
sequencer transition and verifies the real softmax completion path. It is
not an end-to-end inference substitute.

The first rv_top_ctrl run failed compilation because its extraction header
did not expose the newly added native owner/fault launch predicates. The
simulation wrapper now exposes both signals; the TB proves ownership and
native faults block launch while retaining the CPU pending request.
Original compile-failure log is retained at
build/sim/rv_top_ctrl/pre_native_ports_failure.log. The corrected regression
passes. No RTL change was needed for these compatibility adjustments.

Evidence hashes (all logs under build/sim):

- conv1/run.log: `18f2cd05c42569db3bfba10029637e0ba6f60bed0ffdf3e9326cf58b34d9dcef`
- mainline_conv2/run.log: `caf817a791773f629630ccb82da84805deedbdd64b1c8fdeda9e7d6fa30214d2`
- mainline_conv3/run.log: `98fb0afdb4524ebe6610be2e9313b5944c6a1fc949fa141d2d5262d952b6899d`
- mainline_conv4/run.log: `fde23e122cf68c47818917d84a8d6ac4c57a456bf57c7564729d62b2f62272a1`
- npu_chain/run.log: `e57df8163bc86bb49c135296d1cfbac84fc20ccfa6968c541d113b5a259156d2`
- npu_completion/run.log: `17f69434d0a46d24586a9a3284f35d2f9b07ca0b7d1d0b262ce1b92c9319666f`
- rv_cpu/run.log: `aa27b0612e27b10c97f319968e460144f112dd5258b3b626f04d0a2cf3662a99`
- rv_top_ctrl/run.log: `7ed989a76f21d3f0a0cf40862839402040d5a43212886e17678a8e69893a7ae0`
- rv_top_ctrl/pre_native_ports_failure.log: `d14ecc1ca86b3cb19ba52917c60f7958c1055525f6a74939b2d87fd618ce30c8`
- mainline_conv_layers/summary.json: `62d07f8e03b4b4d10a66f25f4e6f4443b77ca956309f549e869ea445e3aed2d5`
