`timescale 1ns / 100ps

// Directed integration regression for the native BF16 multiplication path.
// Mixes add/sub/div with multiplication on consecutive clocks, checks the
// selected result and verifies native multiplication exception flags.
// The native multiplier's invalid flag is checked through the DUT hierarchy;
// the legacy wrapper does not expose a separate IEEE invalid output port.
module test_bf16_integrated_mul;
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
    reg [15:0] result_in = 0;
    reg check_flags_in = 0;
    reg [7:0] flags_in = 0;
    reg invalid_in = 0;

    reg [3:0] valid_pipe = 0;
    reg [3:0] check_flags_pipe = 0;
    reg [3:0] invalid_pipe = 0;
    reg [15:0] result_pipe [0:3];
    reg [7:0] flags_pipe [0:3];
    integer i, j, checked = 0, failures = 0;

    wire [7:0] flags_out =
        {inf, snan, qnan, ine, overflow, underflow, zero, div_by_zero};

    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            result_pipe[i] = 0;
            flags_pipe[i] = 0;
        end
    end

    always @(posedge clk) begin
        valid_pipe <= {valid_pipe[2:0], valid_in};
        check_flags_pipe <= {check_flags_pipe[2:0], check_flags_in};
        invalid_pipe <= {invalid_pipe[2:0], invalid_in};
        result_pipe[0] <= result_in;
        flags_pipe[0] <= flags_in;
        for (j = 1; j < 4; j = j + 1) begin
            result_pipe[j] <= result_pipe[j-1];
            flags_pipe[j] <= flags_pipe[j-1];
        end

        #2;
        if (valid_pipe[3]) begin
            checked = checked + 1;
            if (out !== result_pipe[3]) begin
                failures = failures + 1;
                $display("INTEGRATED MUL RESULT FAIL case=%0d expected=%h got=%h",
                         checked, result_pipe[3], out);
            end
            if (check_flags_pipe[3]) begin
                if (flags_out !== flags_pipe[3]) begin
                    failures = failures + 1;
                    $display("INTEGRATED MUL FLAGS FAIL case=%0d expected=%b got=%b",
                             checked, flags_pipe[3], flags_out);
                end
                if (dut.native_mul_invalid !== invalid_pipe[3]) begin
                    failures = failures + 1;
                    $display("INTEGRATED MUL INVALID FAIL case=%0d expected=%b got=%b",
                             checked, invalid_pipe[3], dut.native_mul_invalid);
                end
            end
        end
    end

    task send_case;
        input [2:0] op;
        input [1:0] rm;
        input [15:0] a, b, expected;
        input check_flags;
        input [7:0] expected_flags;
        input expected_invalid;
        begin
            @(negedge clk);
            fpu_op = op;
            rmode = rm;
            opa = a;
            opb = b;
            result_in = expected;
            check_flags_in = check_flags;
            flags_in = expected_flags;
            invalid_in = expected_invalid;
            valid_in = 1;
        end
    endtask

    initial begin
        // Flags order: inf,snan,qnan,ine,overflow,underflow,zero,div_by_zero.
        send_case(2, 0, 16'h4000, 16'h3fc0, 16'h4040, 1, 8'h00, 0); // 2*1.5 = 3
        send_case(0, 0, 16'h3f80, 16'h4000, 16'h4040, 0, 8'h00, 0); // 1+2
        send_case(2, 0, 16'h7f80, 16'hff80, 16'hff80, 1, 8'h80, 0); // +Inf*-Inf
        send_case(2, 0, 16'h7f80, 16'h0000, 16'h7fc0, 1, 8'h20, 1); // Inf*0 invalid
        send_case(1, 0, 16'h4040, 16'h3f80, 16'h4000, 0, 8'h00, 0); // 3-1
        send_case(2, 0, 16'h0000, 16'h4000, 16'h0000, 1, 8'h02, 0); // +0*2
        send_case(2, 0, 16'h8000, 16'h4000, 16'h8000, 1, 8'h02, 0); // -0*2
        send_case(2, 0, 16'h7f81, 16'h3f80, 16'h7fc0, 1, 8'h60, 1); // sNaN*1
        send_case(2, 0, 16'h7fc0, 16'h3f80, 16'h7fc0, 1, 8'h20, 0); // qNaN*1
        send_case(3, 0, 16'h4040, 16'h3fc0, 16'h4000, 0, 8'h00, 0); // 3/1.5
        send_case(2, 0, 16'h7f7f, 16'h4000, 16'h7f80, 1, 8'h98, 0); // overflow
        send_case(2, 0, 16'h0001, 16'h3f00, 16'h0000, 1, 8'h16, 0); // underflow
        send_case(2, 0, 16'h3f80, 16'h3f80, 16'h3f80, 1, 8'h00, 0); // 1*1
        send_case(2, 0, 16'h7fc0, 16'hff80, 16'h7fc0, 1, 8'h20, 0); // qNaN*-Inf
        send_case(2, 0, 16'hff80, 16'h7f80, 16'hff80, 1, 8'h80, 0); // -Inf*Inf
        send_case(0, 0, 16'h7f80, 16'hff80, 16'h7fc0, 0, 8'h00, 0); // Inf + -Inf

        @(negedge clk);
        valid_in = 0;
        fpu_op = 0;
        opa = 0;
        opb = 0;
        rmode = 0;
        repeat (6) @(posedge clk);
        #3;
        $display("BF16 INTEGRATED MUL: %0d cases, %0d failures", checked, failures);
        if (checked != 16 || failures != 0)
            $fatal(1, "BF16_INTEGRATED_MUL_FAILED");
        $display("BF16_INTEGRATED_MUL_PASSED");
        $finish;
    end
endmodule
