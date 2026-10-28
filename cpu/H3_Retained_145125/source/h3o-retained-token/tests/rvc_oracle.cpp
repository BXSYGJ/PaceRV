#include "Vrvc_oracle.h"
#include "verilated.h"
#include <iostream>
double sc_time_stamp() { return 0; }
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vrvc_oracle model;
    unsigned failures=0, checked=0;
    for(unsigned encoding=0; encoding<65536; ++encoding) {
        if((encoding&3)==3) continue;
        model.compressed=encoding;
        model.eval();
        ++checked;
        if(model.actual_illegal!=model.expected_illegal ||
           (!model.actual_illegal && model.actual!=model.expected)) {
            if(failures<20) std::cerr << "MISMATCH encoding=" << std::hex << encoding << " actual=" << model.actual << " expected=" << model.expected << " actual_illegal=" << unsigned(model.actual_illegal) << " expected_illegal=" << unsigned(model.expected_illegal) << "\n";
            ++failures;
        }
    }
    std::cout << "RVC_ORACLE checked=" << checked << " failures=" << failures << "\n";
    return failures ? 1 : 0;
}
