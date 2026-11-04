# Repeated native inference evidence, 2026-11-01

Final candidate: two complete golden inferences without reset PASS; each 31,115,245 cycles.

Original: second FC2[0] 29 != 202 FAIL. Layer gating alone: second FC2[0] 6 != 202 FAIL.

Delayed independent parameter streams: fixed FC PASS; original FC fails frame 1 stale MAC.

| Local log (under build/sim/) | SHA-256 |
|---|---|
| npu_repeat_native_hardened/run.log | c2357345ed72636b8e4d9ecca736450f5efd80056d8cd7dfbf710b4806ca0cfd |
| npu_repeat_native_hardened/second_fc2_mismatch_original.log | 8268050fc4fd767d544dfd07051853bf4bfd4b8915ad7448f775932424698f20 |
| npu_repeat_native_hardened/second_fc2_gate_only_mismatch.log | c3d5121810212528a9c9b9e865098c8f96d560f6eb2db76c532d21eb0c13a778 |
| fc_parameter_epoch/run.log | 720dbf6c04d26464341d006487148ea131447f3b2a5b6908f9419f13af6bb1da |
| fc_parameter_epoch_baseline/run.log | 78b792f99148c0b328d7b26292da349b40984010cbf4c6c013fd00d3140d6980 |

Final experiment source SHA-256:

- npu_top_repeat_candidate.v: `5992d7c1f801690d344df875ed70571f72d6091099a0a28ea9955fde8cc984f9`
- fc_engine_repeat_candidate.v: `bf24dca55d48ab81fd4ce61a6c0f9c4bc41f2fa7f28937972b4cf36294f448ae`
- run_repeat_native.py: `9e0e38535e92d407a3b219ae5cc0acc8b882989b74bdf32e7b68f2945d4615d6`
- tb_fc_parameter_epoch.sv: `e5f7b7e9a747b27a03d675e9e0cfa54cf371007151e90fe790fd063eca493f35`
- run_fc_epoch.py: `03351c55c2e0a128344b6c1bc9e1f0348bd69ad421a6d2422eb17ec692716415`
