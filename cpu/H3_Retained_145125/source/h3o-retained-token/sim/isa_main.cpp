#include "Vrv32_observed_soc.h"
#include "verilated.h"
#include <iostream>
static vluint64_t sim_time=0;
double sc_time_stamp() { return static_cast<double>(sim_time); }
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vrv32_observed_soc model;
    model.clk=0; model.rst_n=1; model.serial_rx=1; model.gpio_input=0;
    model.eval(); model.rst_n=0; model.eval();
    for(unsigned cycle=0; cycle<2000000; ++cycle) {
        if(cycle==4) model.rst_n=1;
        model.clk=1; sim_time+=5; model.eval();
        model.clk=0; sim_time+=5; model.eval();
        if(model.status_code==0xc0decafeU) {
            std::cout << "ISA_PASS cycles=" << cycle << " retired=" << model.retired_count << "\n";
            return 0;
        }
        if(model.status_code || model.maintenance_fault) {
            std::cerr << "ISA_FAIL status=" << std::hex << model.status_code << " pc=" << model.trace_pc << "\n";
            return 1;
        }
    }
    std::cerr << "ISA_TIMEOUT pc=" << std::hex << model.trace_pc << "\n";
    return 1;
}
