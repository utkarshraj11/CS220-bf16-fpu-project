`timescale 1ns / 100ps

// Native BF16 divider against exact rational golden-reference vectors.
// This validates isolated operations; streaming verification is a separate
// integration requirement before replacing the existing FP32 divider.
module test_bf16_native_div;
    reg clk;
    reg [15:0] opa, opb;
    reg [1:0] rmode;
    wire [15:0] result;
    wire invalid, div_by_zero, inexact, overflow, underflow;
    integer fd, scanned, errors, tests, op_num, mode_num;
    reg [15:0] a, b, expected;
    reg same;

    bf16_div_pipeline dut (
        .clk(clk), .opa(opa), .opb(opb), .rmode(rmode),
        .result(result), .invalid(invalid),
        .div_by_zero(div_by_zero), .inexact(inexact),
        .overflow(overflow), .underflow(underflow)
    );
    always #5 clk = ~clk;

    function is_nan;
        input [15:0] bits;
        begin is_nan = (&bits[14:7]) && (|bits[6:0]); end
    endfunction

    initial begin
        clk = 0;
        opa = 0;
        opb = 0;
        rmode = 0;
        tests = 0;
        errors = 0;
        fd = $fopen("test_vectors/bf16_golden.hex", "r");
        if (fd == 0) $fatal(1, "Missing test_vectors/bf16_golden.hex");
        while (!$feof(fd)) begin
            scanned = $fscanf(fd, "%h %h %d %d %h\n",
                              a, b, op_num, mode_num, expected);
            if (scanned == 5 && op_num == 3) begin
                @(negedge clk);
                opa = a;
                opb = b;
                rmode = mode_num[1:0];
                repeat (4) @(posedge clk);
                #2;
                tests = tests + 1;
                same = (is_nan(expected) && is_nan(result)) ||
                       (result === expected);
                if (!same) begin
                    errors = errors + 1;
                    if (errors <= 30)
                        $display("DIV MISMATCH rm=%0d a=%h b=%h expected=%h got=%h",
                                 mode_num, a, b, expected, result);
                end
            end
        end
        $fclose(fd);
        $display("BF16 NATIVE DIV: %0d cases, %0d mismatches", tests, errors);
        if (tests == 0 || errors != 0) $fatal(1, "BF16_NATIVE_DIV_FAILED");
        $display("BF16_NATIVE_DIV_PASSED");
        $finish;
    end
endmodule
