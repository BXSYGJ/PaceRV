#include "Vrv32_observed_soc.h"
#include "verilated.h"
#include <cstdint>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include "native_timing_tick_v2.h"
int main(int argc, char **argv) {
    try {
        if (argc != 3) throw std::runtime_error("Expected UART output and cycle limit");
        std::string limit(argv[2]);
        if (limit.empty() || limit.find_first_not_of("0123456789") != std::string::npos)
            throw std::runtime_error("Invalid cycle limit");
        uint64_t max_cycles = std::stoull(limit);
        if (!max_cycles || max_cycles > 1000000000000ULL) throw std::runtime_error("Cycle limit out of range");
        std::ofstream uart(argv[1], std::ios::binary);
        if (!uart) throw std::runtime_error("Cannot open UART log");
        VerilatedContext context; context.commandArgs(argc, argv);
        auto model = std::make_unique<Vrv32_observed_soc>(&context);
        model->clk = 0; model->rst_n = 1; model->serial_rx = 1; model->gpio_input = 0;
        model->eval(); model->rst_n = 0; model->eval();
        auto tick = [&]() {
            native_tick(context, *model);
        };
        for (int i = 0; i < 4; ++i) tick();
        model->rst_n = 1; model->eval();
        bool command_started = false;
        uint64_t command_start = 0;
        bool previous_tx = true, receiving = false;
        uint64_t deadline = 0;
        int bit = -1;
        unsigned byte = 0;
        uint32_t sequence = 0, sp = 0, minimum_sp = 65536;
        uint64_t first_cycles = 0, first_retired = 0, observed_cycles = 0, observed_retired = 0;
        uint64_t redirects[7] = {}, eligible[7] = {}, request_stalls = 0, response_waits = 0, barriers = 0;
        for (uint64_t cycle = 1; cycle <= max_cycles; ++cycle) {
            uint64_t before_cycles = model->cycle_count, before_retired = model->retired_count;
            bool retiring = model->retire_event;
            bool redirect = model->redirect_event, can_prime = model->redirect_eligible;
            unsigned kind = model->redirect_kind;
            bool request_stall = model->fetch_request_stall, response_wait = model->fetch_response_wait, barrier = model->frontend_barrier;
            if (model->wb_write && model->wb_rd == 2) sp = model->wb_data;
            tick();
            if (model->cycle_count != before_cycles + 1 || model->retired_count != before_retired + unsigned(retiring))
                throw std::runtime_error("Cycle or retirement observer disagreement");
            if (model->status_code == 0xc0100002U) {
                if (sp < minimum_sp) minimum_sp = sp;
                if (sp < 65536 - 16384 || sp > 65536) {
                    std::cerr << "STACK_BOUND sp=" << sp << " minimum=49152 maximum=65536\n";
                    throw std::runtime_error("Stack pointer exceeded reserved 16384-byte stack");
                }
            }
            if (model->snapshot_sequence != sequence) {
                if (model->snapshot_sequence != sequence + 1 || sequence >= 2)
                    throw std::runtime_error("Unexpected performance snapshot count");
                if (model->snapshot_cycles != before_cycles || model->snapshot_retired != before_retired)
                    throw std::runtime_error("Atomic snapshots differ from independent pre-edge counters");
                sequence = model->snapshot_sequence;
                if (sequence == 1) { first_cycles = before_cycles; first_retired = before_retired; }
                else { observed_cycles = before_cycles - first_cycles; observed_retired = before_retired - first_retired; }
            }
            // Include the first snapshot edge and exclude the second snapshot edge.
            if (sequence == 1) {
                if (redirect) {
                    if (kind >= 7) throw std::runtime_error("Invalid redirect category");
                    ++redirects[kind]; if (can_prime) ++eligible[kind];
                }
                request_stalls += unsigned(request_stall); response_waits += unsigned(response_wait); barriers += unsigned(barrier);
            }
            bool tx = model->serial_tx;
            if (!receiving && previous_tx && !tx) {
                receiving = true; deadline = cycle + 16; bit = -1; byte = 0;
            }
            if (receiving && cycle == deadline) {
                if (bit == -1) { if (tx) throw std::runtime_error("Invalid UART start"); }
                else if (bit < 8) byte |= unsigned(tx) << bit;
                else {
                    if (!tx) throw std::runtime_error("Invalid UART stop");
                    uart.put(char(byte)); std::cout.put(char(byte));
                    if (byte == 10) { uart.flush(); std::cout.flush(); }
                    receiving = false;
                }
                ++bit; deadline += 32;
            }
            previous_tx = tx;
            if (!command_started && model->status_code == 0xc0100000U) {
                command_started = true; command_start = cycle;
                model->serial_rx = 0; model->eval();
            } else if (command_started && cycle - command_start <= 288) {
                uint64_t position = cycle - command_start;
                if (position != 0 && position % 32 == 0) {
                    unsigned command_bit = unsigned(position / 32 - 1);
                    model->serial_rx = command_bit < 8 ? ((0x47U >> command_bit) & 1U) : 1U;
                    model->eval();
                }
            }
            if (model->trap_valid || model->maintenance_fault) {
                std::cerr << "Trap PC=0x" << std::hex << model->trace_pc << " cause=" << model->trap_cause << std::dec << '\n';
                throw std::runtime_error("RTL trap or maintenance fault");
            }
            if (model->status_code == 0xc0100001U) {
                if (sequence != 2 || !observed_cycles || !observed_retired)
                    throw std::runtime_error("Missing measured snapshot interval");
                if (receiving) throw std::runtime_error("Incomplete UART output");
                uart.flush();
                if (!uart) throw std::runtime_error("UART log write failed");
                model->final();
                std::cout << "PASS RTL CoreMark smoke total_cycles=" << cycle << " total_retired=" << model->retired_count << '\n';
                std::cout << "OBSERVER cycles=" << observed_cycles << " retired=" << observed_retired << " minimum_sp=" << minimum_sp << '\n';
                std::cout << "EVENTS redirects=";
                for (int i=0; i<7; ++i) std::cout << (i ? "," : "") << redirects[i];
                std::cout << " eligible=";
                for (int i=0; i<7; ++i) std::cout << (i ? "," : "") << eligible[i];
                std::cout << " request_stalls=" << request_stalls << " response_waits=" << response_waits << " barrier_cycles=" << barriers << '\n';
                return 0;
            }
            if ((model->status_code & 0xffff0000U) == 0xdead0000U) {
                std::cerr << "status=0x" << std::hex << model->status_code << std::dec << '\n';
                throw std::runtime_error("Firmware verification, assert, or runtime failure");
            }
            if (cycle % 100000000ULL == 0) std::cerr << "progress cycles=" << cycle << '\n';
            if (Verilated::gotFinish()) throw std::runtime_error("Unexpected RTL finish");
        }
        throw std::runtime_error("RTL cycle limit exceeded");
    } catch (const std::exception &e) {
        std::cerr << "FAIL " << e.what() << '\n'; return 1;
    }
}
