#pragma once
#include "verilated.h"
#include <cstdint>
#include <stdexcept>
template <typename Model>
void native_advance(VerilatedContext& context, Model& model, uint64_t target) {
    // The original FF-only baseline has no native delayed instances; Verilator
    // omits its event API. Candidate build guards require this API to be present.
    if constexpr (requires { model.eventsPending(); model.nextTimeSlot(); }) {
        while (model.eventsPending() && model.nextTimeSlot() <= target) {
            const auto event_time = model.nextTimeSlot();
            if (event_time < context.time()) throw std::runtime_error("Native event moved backwards");
            context.time(event_time); model.eval();
        }
    }
    context.time(target); model.eval();
}
template <typename Model>
void native_tick(VerilatedContext& context, Model& model) {
    model.clk = 1; model.eval(); native_advance(context, model, context.time() + 5000);
    model.clk = 0; model.eval(); native_advance(context, model, context.time() + 5000);
}
