`timescale 1ns / 100ps

// Directed BF16 arithmetic/rounding smoke test.
// Launch with the original RTL and verilog/fpu_bf16_wrapper.v.
// This checks representative behavior; it is not a complete IEEE-754 suite.
module test_bf16_wrapper;
    reg clk;
    reg [1:0] rmode;
    reg [2:0] fpu_op;
    reg [15:0] opa, opb;
    wire [15:0] out;
    wire inf, snan, qnan, ine, overflow, underflow, zero, div_by_zero;
    integer tests, failures;

    fpu_bf16_wrapper dut (
        .clk(clk), .rmode(rmode), .fpu_op(fpu_op),
        .opa(opa), .opb(opb), .out(out), .inf(inf),
        .snan(snan), .qnan(qnan), .ine(ine),
        .overflow(overflow), .underflow(underflow),
        .zero(zero), .div_by_zero(div_by_zero)
    );

    always #5 clk = ~clk;

    task check;
        input [2:0] op;
        input [1:0] rm;
        input [15:0] a, b, expected;
        begin
            @(negedge clk);
            fpu_op = op;
            rmode = rm;
            opa = a;
            opb = b;
            repeat (4) @(posedge clk);
            #2;
            tests = tests + 1;
            if (out !== expected) begin
                failures = failures + 1;
                $display("FAIL op=%d rm=%d a=%h b=%h got=%h expected=%h",
                         op, rm, a, b, out, expected);
            end else begin
                $display("PASS op=%d rm=%d a=%h b=%h out=%h",
                         op, rm, a, b, out);
            end
        end
    endtask

    initial begin
        clk = 0;
        rmode = 0;
        fpu_op = 0;
        opa = 0;
        opb = 0;
        tests = 0;
        failures = 0;

        check(3'd0, 2'd0, 16'h3f80, 16'h4000, 16'h4040); // 1 + 2 = 3
        check(3'd1, 2'd0, 16'h4040, 16'h3f80, 16'h4000); // 3 - 1 = 2
        check(3'd2, 2'd0, 16'h4000, 16'h3fc0, 16'h4040); // 2 * 1.5 = 3
        check(3'd3, 2'd0, 16'h4040, 16'h3fc0, 16'h4000); // 3 / 1.5 = 2
        check(3'd0, 2'd0, 16'hbf80, 16'h3f80, 16'h0000); // -1 + 1 = 0

        // Exactly halfway between BF16 1.0 and next representable value.
        check(3'd0, 2'd0, 16'h3f80, 16'h3b80, 16'h3f80); // nearest even
        check(3'd0, 2'd1, 16'h3f80, 16'h3b80, 16'h3f80); // toward zero
        check(3'd0, 2'd2, 16'h3f80, 16'h3b80, 16'h3f81); // toward +Inf
        check(3'd0, 2'd3, 16'h3f80, 16'h3b80, 16'h3f80); // toward -Inf
        check(3'd0, 2'd0, 16'h3f80, 16'h3bc0, 16'h3f81); // > halfway
        check(3'd0, 2'd3, 16'hbf80, 16'hbb80, 16'hbf81); // negative, -Inf
        check(3'd0, 2'd2, 16'hbf80, 16'hbb80, 16'hbf80); // negative, +Inf

        $display("BF16 wrapper smoke test: %0d cases, %0d failures",
                 tests, failures);
        if (failures != 0) $display("BF16_TEST_FAILED");
        else $display("BF16_TEST_PASSED");
        $finish;
    end
endmodule
