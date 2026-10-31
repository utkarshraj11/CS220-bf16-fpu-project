`timescale 1ns / 100ps

// Back-to-back BF16 operations: a new request is launched on every clock.
// This specifically checks that the pipelined Inf*Inf and Inf/Inf overrides
// remain aligned with the original arithmetic datapath when inputs change.
// Compile with -g2012 -s test_bf16_pipeline.
module test_bf16_pipeline;
    reg clk = 0;
    always #5 clk = ~clk;

    reg [1:0] rmode = 0;
    reg [2:0] fpu_op = 0;
    reg [15:0] opa = 0, opb = 0;
    wire [15:0] out;
    wire inf, snan, qnan, ine, overflow, underflow, zero, div_by_zero;

    fpu_bf16_wrapper dut (
        .clk(clk), .rmode(rmode), .fpu_op(fpu_op),
        .opa(opa), .opb(opb), .out(out),
        .inf(inf), .snan(snan), .qnan(qnan), .ine(ine),
        .overflow(overflow), .underflow(underflow),
        .zero(zero), .div_by_zero(div_by_zero)
    );

    reg valid_in = 0;
    reg [15:0] expected_in = 0;
    reg flags_in = 0, expected_inf_in = 0, expected_qnan_in = 0;

    reg [3:0] valid_pipe;
    reg [15:0] expected_pipe [0:3];
    reg [3:0] flags_pipe, expected_inf_pipe, expected_qnan_pipe;
    integer checked = 0, failures = 0;
    integer j, k;

    initial begin
        valid_pipe = 0;
        flags_pipe = 0;
        expected_inf_pipe = 0;
        expected_qnan_pipe = 0;
        for (k = 0; k < 4; k = k + 1)
            expected_pipe[k] = 0;
    end

    always @(posedge clk) begin
        valid_pipe <= {valid_pipe[2:0], valid_in};
        flags_pipe <= {flags_pipe[2:0], flags_in};
        expected_inf_pipe <= {expected_inf_pipe[2:0], expected_inf_in};
        expected_qnan_pipe <= {expected_qnan_pipe[2:0], expected_qnan_in};
        expected_pipe[0] <= expected_in;
        for (j = 1; j < 4; j = j + 1)
            expected_pipe[j] <= expected_pipe[j-1];

        // The original FP32 core registers results with a #1 delay.
        #2;
        if (valid_pipe[3]) begin
            checked = checked + 1;
            if (out !== expected_pipe[3]) begin
                failures = failures + 1;
                $display("PIPELINE OUTPUT FAIL case=%0d expected=%h got=%h",
                         checked, expected_pipe[3], out);
            end
            if (flags_pipe[3] &&
                {inf, qnan, zero, ine, overflow, underflow, div_by_zero, snan}
                    !== {expected_inf_pipe[3], expected_qnan_pipe[3], 6'b000000}) begin
                failures = failures + 1;
                $display("PIPELINE FLAGS FAIL case=%0d inf=%b qnan=%b zero=%b ine=%b ovf=%b udf=%b dbz=%b snan=%b",
                         checked, inf, qnan, zero, ine, overflow,
                         underflow, div_by_zero, snan);
            end
        end
    end

    task send_case;
        input [2:0] op;
        input [1:0] rm;
        input [15:0] a, b, expected;
        input check_flags, expected_inf, expected_qnan;
        begin
            @(negedge clk);
            fpu_op = op;
            rmode = rm;
            opa = a;
            opb = b;
            expected_in = expected;
            flags_in = check_flags;
            expected_inf_in = expected_inf;
            expected_qnan_in = expected_qnan;
            valid_in = 1;
        end
    endtask

    initial begin
        // Mix infinity operations with ordinary arithmetic every cycle.
        // All four rounding modes and both infinity signs are represented.
        send_case(2, 0, 16'h7f80, 16'hff80, 16'hff80, 1, 1, 0);
        send_case(0, 0, 16'h3f80, 16'h4000, 16'h4040, 0, 0, 0);
        send_case(3, 0, 16'h7f80, 16'hff80, 16'h7fc0, 1, 0, 1);
        send_case(1, 0, 16'h4040, 16'h3f80, 16'h4000, 0, 0, 0);
        send_case(2, 0, 16'h7f80, 16'h7f80, 16'h7f80, 1, 1, 0);
        send_case(2, 0, 16'h4000, 16'h3fc0, 16'h4040, 0, 0, 0);
        send_case(3, 0, 16'hff80, 16'hff80, 16'h7fc0, 1, 0, 1);
        send_case(3, 0, 16'h4040, 16'h3fc0, 16'h4000, 0, 0, 0);
        send_case(2, 1, 16'hff80, 16'hff80, 16'h7f80, 1, 1, 0);
        send_case(0, 0, 16'hbf80, 16'h3f80, 16'h0000, 0, 0, 0);
        send_case(3, 1, 16'h7f80, 16'h7f80, 16'h7fc0, 1, 0, 1);
        send_case(2, 1, 16'hff80, 16'h7f80, 16'hff80, 1, 1, 0);
        send_case(0, 0, 16'h3f80, 16'h3b80, 16'h3f80, 0, 0, 0);
        send_case(3, 2, 16'hff80, 16'h7f80, 16'h7fc0, 1, 0, 1);
        send_case(2, 2, 16'h7f80, 16'hff80, 16'hff80, 1, 1, 0);
        send_case(0, 2, 16'h3f80, 16'h3b80, 16'h3f81, 0, 0, 0);
        send_case(3, 3, 16'h7f80, 16'hff80, 16'h7fc0, 1, 0, 1);
        send_case(2, 3, 16'hff80, 16'hff80, 16'h7f80, 1, 1, 0);
        send_case(0, 3, 16'hbf80, 16'hbb80, 16'hbf81, 0, 0, 0);
        send_case(3, 3, 16'hff80, 16'hff80, 16'h7fc0, 1, 0, 1);

        // Consecutive Inf +/- Inf cases found by the streaming regression.
        // Unlike the golden test, these explicitly check exception flags.
        send_case(0, 0, 16'h7f80, 16'h7f80, 16'h7f80, 1, 1, 0);
        send_case(0, 0, 16'h7f80, 16'hff80, 16'h7fc0, 1, 0, 1);
        send_case(0, 1, 16'hff80, 16'h7f80, 16'h7fc0, 1, 0, 1);
        send_case(0, 1, 16'hff80, 16'hff80, 16'hff80, 1, 1, 0);
        send_case(1, 2, 16'h7f80, 16'h7f80, 16'h7fc0, 1, 0, 1);
        send_case(1, 2, 16'h7f80, 16'hff80, 16'h7f80, 1, 1, 0);
        send_case(1, 3, 16'hff80, 16'h7f80, 16'hff80, 1, 1, 0);
        send_case(1, 3, 16'hff80, 16'hff80, 16'h7fc0, 1, 0, 1);

        @(negedge clk);
        valid_in = 0;
        opa = 0;
        opb = 0;
        fpu_op = 0;
        rmode = 0;
        repeat (6) @(posedge clk);
        #3;
        $display("BF16 PIPELINE: %0d cases, %0d failures", checked, failures);
        if (checked != 28 || failures != 0)
            $fatal(1, "BF16_PIPELINE_FAILED");
        $display("BF16_PIPELINE_PASSED");
        $finish;
    end
endmodule
