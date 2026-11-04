# Experimental conv and pool backpressure

Copies only; no mainline or PDS source changes. No synthesis/route/board evidence.

Run from instrec_fpga:

    python sim/experiments/activation_pipeline/run_conv.py
    python sim/experiments/activation_pipeline/run_pool.py

Conv: 16-byte output FIFO, complete 16-result capacity reservation before snapshot_go, every in-flight result included. Requant remains nonstallable. No new snapshot until old reserved group drains. y_valid/data remain stable under !y_ready. Fixed fin_cnt=22 now reaches and holds at 1; done requires all reserved/output bytes accepted. Random backpressure conv1 golden passes 792576 values, mismatch0, 1399343 cycles. TB retains original row-credit-safe input and true weights/contracts.

Pool: 8-byte output FIFO; reservation counts accepted fire_c results including fixed read pipeline and producer output register. y_ready stalls ingestion before capacity exhaustion. All ingress counters/RAM writes/fire advance only on y_valid&&y_ready. p_valid/data/last stay stable under !p_ready. Reset must be before producing conv, after the previous result fully drained. Independent 4x5x32 odd-width test passes all128 mathematically computed pooled bytes under long periodic output stalls, checking FIFO/reservations and p_last.

Initial experimental failures were TB counting defects, corrected before PASS: conv initially counted valid without ready; pool expected row stride128 rather than64 bytes. The original pool failure log is in gitignored build/activation_pipeline_candidate/pool_tb_index_failure.log.

Still unverified: full-chain integration, all-layer natural replay, repeated inference, vendor synthesis inference/resource/timing, DDR adapter and arbitrary hardware failure. Existing NPU top does not supply these ready ports. Do not replace mainline sources without updating every caller and passing full integration tests.

## Integrated protocol experiments

    python sim/experiments/activation_pipeline/run_pool_store.py
    python sim/experiments/activation_pipeline/run_conv_pool_store.py

Pool->row store->DDR model->canonical replay passes 128 mathematical golden bytes, 4 writes and 4 reads. The DDR write ready is open only 5 out of 101 cycles, propagating stalls through the real pool ready port.

Small real conv->pool->row store->DDR->canonical replay also passes. Conv geometry H4/W6/CIN1/COUT16 uses nonzero all-one 3x3 weights, channel-index biases, M=2^30, shift30, explicit zero padding and row-credit-safe input. Every one of 384 conv bytes is checked against independent integer convolution, all96 pooled bytes against independent 2x2 max, then all96 DDR replay bytes against canonical row/col/channel order. Four writes/reads cover row padding. This is no replacement for actual npu_top/full model integration or native DDR adapter evidence.
