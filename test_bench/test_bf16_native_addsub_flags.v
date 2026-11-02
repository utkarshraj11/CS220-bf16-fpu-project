`timescale 1ns/1ps

// Directed checks for BF16 add/sub result bits and exception-related flags.
// Covers selected IEEE-754 special cases; this is not a complete flag oracle.
module test_bf16_native_addsub_flags;
    reg [15:0] opa, opb;
    reg subtract;
    reg [1:0] rmode;
    wire [15:0] result;
    wire invalid, inexact, overflow, underflow;
    integer checked, failed;

    bf16_addsub_comb dut (
        .opa(opa), .opb(opb), .subtract(subtract), .rmode(rmode),
        .result(result), .invalid(invalid), .inexact(inexact),
        .overflow(overflow), .underflow(underflow)
    );

    task check;
        input [15:0] a, b;
        input sub;
        input [1:0] mode;
        input [15:0] expected_result;
        input expected_invalid, expected_inexact;
        input expected_overflow, expected_underflow;
        begin
            opa = a;
            opb = b;
            subtract = sub;
            rmode = mode;
            #1;
            checked = checked + 1;
            if ({result, invalid, inexact, overflow, underflow} !==
                {expected_result, expected_invalid, expected_inexact,
                 expected_overflow, expected_underflow}) begin
                failed = failed + 1;
                $display("FLAGS FAIL a=%h b=%h sub=%b rm=%0d expected=%h/%b%b%b%b actual=%h/%b%b%b%b",
                         a, b, sub, mode, expected_result,
                         expected_invalid, expected_inexact,
                         expected_overflow, expected_underflow,
                         result, invalid, inexact, overflow, underflow);
            end
        end
    endtask

    initial begin
        checked = 0;
        failed = 0;
        opa = 0;
        opb = 0;
        subtract = 0;
        rmode = 0;

        // Exact finite arithmetic and exact cancellation.
        check(16'h3f80, 16'h3f80, 0, 0, 16'h4000, 0, 0, 0, 0);
        check(16'h3f80, 16'h3f80, 1, 0, 16'h0000, 0, 0, 0, 0);
        check(16'h3f80, 16'h3f80, 1, 3, 16'h8000, 0, 0, 0, 0);

        // Signed-zero behavior, including round-toward-negative.
        check(16'h0000, 16'h8000, 0, 0, 16'h0000, 0, 0, 0, 0);
        check(16'h0000, 16'h8000, 0, 3, 16'h8000, 0, 0, 0, 0);
        check(16'h8000, 16'h8000, 0, 0, 16'h8000, 0, 0, 0, 0);

        // Infinity conflicts are invalid; a single infinity is valid.
        check(16'h7f80, 16'hff80, 0, 0, 16'h7fc0, 1, 0, 0, 0);
        check(16'h7f80, 16'h7f80, 1, 0, 16'h7fc0, 1, 0, 0, 0);
        check(16'h7f80, 16'h3f80, 0, 0, 16'h7f80, 0, 0, 0, 0);

        // Signaling NaN raises invalid; quiet NaN propagates without it.
        check(16'h7f81, 16'h3f80, 0, 0, 16'h7fc0, 1, 0, 0, 0);
        check(16'h7fc0, 16'h3f80, 0, 0, 16'h7fc0, 0, 0, 0, 0);

        // Overflow and saturation under different rounding modes.
        check(16'h7f7f, 16'h7f7f, 0, 0, 16'h7f80, 0, 1, 1, 0);
        check(16'h7f7f, 16'h7f7f, 0, 1, 16'h7f7f, 0, 1, 1, 0);
        check(16'h7f7f, 16'h0001, 0, 0, 16'h7f7f, 0, 1, 1, 0);

        // Inexact results, including rounding toward +/- infinity.
        check(16'h3f80, 16'h0001, 0, 0, 16'h3f80, 0, 1, 0, 0);
        check(16'h3f80, 16'h0001, 0, 2, 16'h3f81, 0, 1, 0, 0);
        check(16'h3f80, 16'h0001, 1, 0, 16'h3f80, 0, 1, 0, 0);
        check(16'h3f80, 16'h0001, 1, 1, 16'h3f7f, 0, 1, 0, 0);

        // Subnormal operations can be exact, with no underflow flag.
        check(16'h0001, 16'h0001, 0, 0, 16'h0002, 0, 0, 0, 0);
        check(16'h0080, 16'h007f, 1, 0, 16'h0001, 0, 0, 0, 0);

        // Round-to-nearest-even: exact halfway tie and just above halfway.
        check(16'h3f80, 16'h3b80, 0, 0, 16'h3f80, 0, 1, 0, 0);
        check(16'h3f80, 16'h3b81, 0, 0, 16'h3f81, 0, 1, 0, 0);

        $display("BF16 NATIVE ADDSUB FLAGS: %0d cases, %0d failures",
                 checked, failed);
        if (failed != 0)
            $fatal(1, "BF16_NATIVE_ADDSUB_FLAGS_FAILED");
        $display("BF16_NATIVE_ADDSUB_FLAGS_PASSED");
        $finish;
    end
endmodule
