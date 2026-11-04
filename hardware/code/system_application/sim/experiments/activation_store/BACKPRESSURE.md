# Conv drain and pool backpressure integration points

Read-only design review; no mainline changes.

## Minimal safe approach: reserve a complete drain batch

Do not directly gate y_valid with ready or stop only rhe_busy_cnt. requant_unit has a fixed four-stage valid pipeline; previously issued results continue to arrive. Introduce a small elastic output FIFO, and reserve room for all 16 lanes before snapshot_go. The free calculation must subtract both occupied FIFO entries and reserved-but-not-yet-returned requant results. Release a reservation only when that result enters the FIFO, not when it is issued.

conv_engine.v changes:

- Add output y_valid/y_data with input y_ready, backed by FIFO. Hold y_valid and y_data stable during !y_ready. Pop only on valid && ready.
- Add a complete 16-result reservation predicate to snapshot_go (:835). Keep PH_SNAP stalled until reservation succeeds. This already prevents acc_snap/m_drn/shft_drn overwrite while waiting; PH_LOAD of the following pixel remains unreachable until snapshot acceptance.
- At snapshot acceptance, reserve 16 bytes and issue all 16 requants without further stalling. Preserve existing rhe_ch/rhe_busy_cnt and requant latency; no changes to the numerical pipeline are needed.
- The output FIFO must accept every rq_y_valid, regardless of downstream ready. Assert occupied + reserved <= depth on every cycle. Depth >=16 is sufficient only if reservation accounts correctly for the entire already issued batch; 32 is a simple initial candidate.
- Current fin_cnt=22 completion (:969) means requant production finished, not all output bytes accepted. Latch an internal production-finished flag and emit done only after FIFO empty AND no reserved/inflight results. Do not reset/advance layer while any byte is pending.
- Expose a row-retired/row-release pulse for activation replay, after all MAC reads of output row r have ended. A row cache can refill old input row r-1 then; releasing only on final output acceptance is conservative and also safe.

pool_engine.v changes:

- Add y_ready for conv FIFO and p_ready for activation store FIFO. Its lane/col/group/row counters, RAM writes, cur_prev capture and fire calculation must use y_valid && y_ready, not raw y_valid.
- Fixed synchronous RAM read and fire_d1/fire_d2 pipeline currently continues each clock. Either clock-enable every data/control/read stage together during stalls OR retain it free-running and reserve output FIFO capacity before accepting each input that can produce a pool output. The latter avoids touching pooling arithmetic and variable input gaps.
- A pool output FIFO must hold p_valid/p_data stable under !p_ready; p_last accompanies the same FIFO entry and becomes completed only when the final entry is accepted. Sticky p_last cannot be cleared by a late pool_start.
- Conservative y_ready may require at least 3 slots free after subtracting in-flight fire_d1/fire_d2/p_valid. Precise bound depends on whether registered p_valid is inserted into FIFO on the same edge; verify with RTL assertions rather than assuming two stages.
- Reset pool at producing conv start, before first accepted y byte. During the later POOL sequencer state, only drain/wait; do not reset counters or completion.

activation_row_store uses in_ready and out_ready already. A one-row store deasserts in_ready while writing DDR. Propagate this stall through pool FIFO and conv FIFO/batch reservation. DDR writes must continue independently while producers are stalled, otherwise a circular wait is possible.

## Stability and ordering assertions

1. valid && !ready implies next-cycle valid and unchanged data/last.
2. Counters advance iff valid && ready; no skipped or duplicated lane under stalls.
3. accepted conv count = expected full shape; accepted pool count = floor-pooled shape.
4. No snapshot without 16 reserved slots; no rq result without a matching reservation.
5. done only after last output handshake; layer select stays unchanged until then.
6. Arbitrary long DDR write stalls and consumer stalls eventually drain after ready recovers; no FIFO overflow while stalls persist.
7. Read-side R has no ready and accepted bursts always have reserved storage for every beat.
8. Two complete inferences must pass, exercising pool/GAP reset and all row credits.
