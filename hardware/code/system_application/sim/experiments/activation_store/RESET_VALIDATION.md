# Narrow activation-store reset regression

Run `python sim/experiments/activation_store/run_narrow_reset.py`.

The directed test interrupts each active state: FILL, WCMD, WDATA, CREDIT,
RCMD, RDATA, PREFETCH and EMIT. After every reset it starts a different geometry,
writes a fresh epoch-dependent pattern, and checks every replayed byte, row
index, read/write command count and total byte count. Live configuration is
changed to invalid values immediately after start to check the latched geometry.

Reset must clear all command/data/output valids, completion/error flags and
replay-row state. No command/output may reappear before a new start. A new read
must remain stopped until fresh row credit; one credit pulse permits exactly
one row and cannot release the next row. All eight scenarios passed.

DDR memory contents persist across reset, so stale contents can reveal an
incomplete rewrite. The model cancels outstanding DDR commands/responses at
the same reset boundary as the DUT. An upstream response arriving after reset
without coordinated cancellation is outside this test. This is a directed
module simulation, with no claim about full-top reset, DDR PHY or board reset.

Tracked hash/result summary:
`reports/activation_narrow_reset_validation_20261101.json`.
Raw log: `build/sim/activation_narrow_reset/run.log`.

Production RTL and the frozen narrow snapshot are unchanged.

## Actual production rerun

`python sim/experiments/activation_store/run_production_reset.py` adapts only
the DUT module name and TB/result names, then compiles the actual
`src/npu/activation_row_store_dynamic.v`. All eight reset scenarios passed
again, including new-geometry complete replay and fresh-credit assertions.
This result uses production RTL directly rather than inferring it from the
candidate module. The original candidate log is preserved.

The report's `production_rerun` section records the actual production SHA-256,
generated TB hash and independent log hash. The production log is
`build/sim/activation_production_reset/run.log`. The same coordinated-DDR-reset
boundary applies.
