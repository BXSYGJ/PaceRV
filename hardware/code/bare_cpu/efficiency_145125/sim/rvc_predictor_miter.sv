`timescale 1ns/1ps
module rvc_predictor_miter;
    parameter integer INDEX_BITS=8,HISTORY_BITS=4,COUNTER_BITS=2,STACK_DEPTH=1;
    reg clk=0,rst_n=0,invalidate=0;
    reg [31:0] fetch_pc=0,update_pc=0,update_target=0,stack_push_address=0;
    reg update_valid=0,update_taken=0,update_conditional=0,update_return=0,stack_push=0,stack_pop=0;
    wire actual_taken,actual_hit,reference_taken,reference_hit;
    wire [31:0] actual_target,reference_target;
    integer seed=32'h34ec17a9,iteration,checks=0,hits=0,updates=0;
    reg [31:0] random_bits;
    always #5 clk=~clk;
    rv32_btb #(.INDEX_BITS(INDEX_BITS),.ADDRESS_BITS(16),.HISTORY_BITS(HISTORY_BITS),
        .COUNTER_BITS(COUNTER_BITS),.RETURN_STACK_DEPTH(STACK_DEPTH)) actual(
        .clk(clk),.rst_n(rst_n),.invalidate(invalidate),.fetch_pc(fetch_pc),
        .predicted_taken(actual_taken),.predicted_target(actual_target),.prediction_hit(actual_hit),
        .update_valid(update_valid),.update_pc(update_pc),.update_target(update_target),
        .update_taken(update_taken),.update_conditional(update_conditional),.update_return(update_return),
        .stack_push(stack_push),.stack_pop(stack_pop),.stack_push_address(stack_push_address));
    rv32_btb_reference #(.INDEX_BITS(INDEX_BITS),.ADDRESS_BITS(16),.HISTORY_BITS(HISTORY_BITS),
        .COUNTER_BITS(COUNTER_BITS),.RETURN_STACK_DEPTH(STACK_DEPTH)) reference_model(
        .clk(clk),.rst_n(rst_n),.invalidate(invalidate),.fetch_pc(fetch_pc),
        .predicted_taken(reference_taken),.predicted_target(reference_target),.prediction_hit(reference_hit),
        .update_valid(update_valid),.update_pc(update_pc),.update_target(update_target),
        .update_taken(update_taken),.update_conditional(update_conditional),.update_return(update_return),
        .stack_push(stack_push),.stack_pop(stack_pop),.stack_push_address(stack_push_address));
    task check_prediction;
        begin
            #1;
            checks=checks+1;
            if({actual_hit,actual_taken,actual_target}!=={reference_hit,reference_taken,reference_target})
                $fatal(1,"PREDICTOR_MISMATCH iteration=%0d pc=%h actual=%b/%b/%h reference=%b/%b/%h",
                    iteration,fetch_pc,actual_hit,actual_taken,actual_target,reference_hit,reference_taken,reference_target);
            if(actual_hit) hits=hits+1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        for(iteration=0;iteration<100000;iteration=iteration+1) begin
            @(negedge clk);
            rst_n=!(iteration>=60000 && iteration<60004);
            random_bits=$random(seed);
            invalidate=iteration%4093==4092;
            update_valid=iteration%5!=0;
            update_conditional=random_bits[5:4]!=0;
            update_taken=random_bits[7];
            update_return=!update_conditional && random_bits[9];
            update_pc={21'b0,random_bits[19:10],1'b0};
            if(iteration%97==0) update_pc[0]=1;
            if(iteration%113==0) update_pc[16]=1;
            update_target={16'b0,random_bits[30:16],1'b0};
            if(iteration%127==0) update_target[16]=1;
            stack_push=random_bits[2:0]==3'b001;
            stack_pop=random_bits[4:2]==3'b010;
            stack_push_address=update_pc+32'd2;
            fetch_pc=iteration%3==0 ? update_pc : {21'b0,random_bits[29:20],1'b0};
            if(iteration%131==0) fetch_pc[16]=1;
            if(iteration%139==0) fetch_pc[0]=1;
            if(iteration%1024<96) begin
                update_pc=32'h102;
                fetch_pc=32'h102;
                update_target=32'h202;
                update_valid=1;
                update_conditional=1;
                update_taken=iteration%96<48;
            end
            check_prediction();
            if(actual.train_update) updates=updates+1;
            @(posedge clk);
            check_prediction();
        end
        if(hits<5000 || updates<50000) $fatal(1,"Insufficient predictor test coverage");
        $display("PREDICTOR_PASS index=%0d history=%0d counters=%0d stack=%0d checks=%0d hits=%0d updates=%0d",
            INDEX_BITS,HISTORY_BITS,COUNTER_BITS,STACK_DEPTH,checks,hits,updates);
        $finish;
    end
endmodule
