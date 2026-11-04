#include "Vrv32_rvc_frontend.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <random>
#include <vector>
double sc_time_stamp() { return 0; }
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    unsigned total=0;
    for(unsigned seed=1; seed<=8; ++seed) {
        std::mt19937 random(seed);
        Vrv32_rvc_frontend model;
        std::vector<uint16_t> memory(8192,0);
        std::vector<uint32_t> starts;
        unsigned position=0;
        while(position+2<memory.size()) {
            starts.push_back(position*2);
            if(random()%3==0) {
                memory[position++]=(random()&0xffffU)|3U;
                memory[position++]=random();
            } else memory[position++]=(random()&0xfffcU)|(random()%3);
        }
        bool pending=false;
        unsigned delay=0;
        uint32_t response_data=0, response_pair=0, expected_pc=0;
        bool response_error=false, pair_valid=false;
        model.clk=0; model.rst_n=1; model.invalidate=0; model.redirect_valid=0; model.redirect_in_range=1;
        model.predicted_taken=0; model.predicted_target=0; model.out_ready=0;
        model.i_req_ready=0; model.i_rsp_valid=0; model.i_rsp_data=0; model.i_rsp_error=0;
        model.i_rsp_pair_data=0; model.i_rsp_pair_valid=0;
        model.i_rsp_is_c=3; model.i_rsp_pair_is_c=3;
        model.eval(); model.rst_n=0; model.eval();
        model.clk=1; model.eval(); model.clk=0; model.rst_n=1; model.eval();
        unsigned accepted=0;
        unsigned ready_without_progress=0;
        for(unsigned cycle=0; cycle<60000; ++cycle) {
            model.clk=0;
            bool redirect=random()%71==0 || expected_pc>=position*2-8;
            model.redirect_valid=redirect;
            model.redirect_pc=starts[random()%starts.size()];
            model.invalidate=redirect && random()%3==0;
            model.out_ready=random()%4!=0;
            model.predicted_taken=(expected_pc*0x9e3779b9U+seed)%11==0;
            model.predicted_target=starts[((expected_pc>>1)*0x45d9f3bU+seed)%starts.size()];
            model.i_rsp_valid=pending && delay==0;
            model.i_rsp_data=model.i_rsp_valid ? response_data : random();
            model.i_rsp_error=response_error;
            model.i_rsp_pair_data=model.i_rsp_valid ? response_pair : random();
            model.i_rsp_is_c=((model.i_rsp_data&3)!=3) | (((model.i_rsp_data>>16&3)!=3)<<1);
            model.i_rsp_pair_is_c=((model.i_rsp_pair_data&3)!=3) | (((model.i_rsp_pair_data>>16&3)!=3)<<1);
            model.i_rsp_pair_valid=pair_valid;
            model.i_req_ready=(!pending || model.i_rsp_valid) && random()%4!=0;
            model.eval();
            bool consume=model.out_valid && model.out_ready;
            if(consume || redirect) ready_without_progress=0;
            else if(model.out_ready) ++ready_without_progress;
            if(ready_without_progress>40) {
                std::cerr << "FRONTEND_STALLED seed=" << seed << " cycle=" << cycle << " pc=" << std::hex << model.out_pc << "\n";
                return 1;
            }
            if(consume) {
                unsigned halfword=memory.at(expected_pc/2);
                unsigned length=(halfword&3)==3 ? 4 : 2;
                uint32_t expected_instruction=halfword;
                if(length==4) expected_instruction|=uint32_t(memory.at(expected_pc/2+1))<<16;
                if(model.out_pc!=expected_pc || model.out_instruction!=expected_instruction || model.out_length!=length || model.out_error) {
                    std::cerr << "FRONTEND_FAIL seed=" << seed << " cycle=" << cycle << " pc=" << std::hex << model.out_pc << " expected_pc=" << expected_pc << " instruction=" << model.out_instruction << " error=" << unsigned(model.out_error) << "\n";
                    return 1;
                }
                expected_pc=model.out_prediction;
                ++accepted;
            }
            if(redirect) expected_pc=model.redirect_pc;
            bool request=model.i_req_valid && model.i_req_ready;
            uint32_t address=model.i_req_address;
            bool response=model.i_rsp_valid && model.i_rsp_ready;
            if(response) pending=false;
            if(pending && delay) --delay;
            if(request) {
                if(address&3) return 2;
                pending=true;
                delay=random()%7;
                response_error=address/2+1>=memory.size();
                response_data=response_error ? 0 : uint32_t(memory[address/2]) | uint32_t(memory[address/2+1])<<16;
                pair_valid=seed>4 && !(address&4) && address/2+3<memory.size();
                response_pair=pair_valid ? uint32_t(memory[address/2+2]) | uint32_t(memory[address/2+3])<<16 : 0;
            }
            model.clk=1; model.eval();
        }
        if(accepted<3000) {
            std::cerr << "FRONTEND_LIVENESS_FAIL seed=" << seed << " accepted=" << accepted << "\n";
            return 1;
        }
        total+=accepted;
    }
    std::cout << "FRONTEND_PASS seeds=8 cycles=480000 accepted=" << total << "\n";
    return 0;
}
