# Architecture

PaceRV is a single-issue, in-order RV32IMC processor organized around fetch, decode, execute, memory, and writeback stages. Its compressed-instruction front end handles 16/32-bit alignment. Branch prediction, forwarding, load-use handling, machine-mode control/status registers, multiplication/division, instruction/data caches, shared backing memory, and UART/GPIO are included in the released systems.

The paper focuses on the interaction between **memory admission** and **prepared multiplication**. Moving a data request earlier changes which multiply instructions remain stalled after an arithmetic preparation opportunity. The Retained implementation preserves permission to use a prepared low-word multiply result while the same dynamic instruction remains in execute. Operand hazards and instruction cancellation govern validity.

The architectural M extension includes MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, and REMU. The prepared-result optimization applies to low-word MUL; it does not imply early preparation of every M instruction.

## Source entry points

- `cpu/H3_Base_145125/source/rtl/`: the Base processor and system modules.
- `cpu/H3_Retained_145125/source/h3o-retained-token/rtl/`: the Retained processor and system modules.
- `cpu/*/physical/V*/inputs/`: exact independent physical-build inputs for each firmware image.
- `cpu/*/simulation/inputs/`: the observed full-system simulation snapshots and C++ driver.
- `cpu/H3_Retained_145125/source/core_token_tb.sv`: instruction identity, cancellation, stalls, and preparation tests.
- `cpu/H3_Retained_145125/source/mul_retention_tb.sv`: arithmetic oracle, retention, cancellation, and response-backpressure tests.

Use the physical or simulation snapshot selected by its recipe when reproducing measurements. Edit both when developing a new equivalent configuration. Directory names and RTL parameters are preserved from the measured version.

The published board configurations use early data-request admission. The focused testbench also exercises registered admission and one-edge versus retained permission. The board release contains the two qualified 145.125 MHz systems; additional experimental policies described in the paper are not represented as additional board-qualified images here.
