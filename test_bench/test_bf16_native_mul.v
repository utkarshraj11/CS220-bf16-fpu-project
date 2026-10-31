`timescale 1ns / 100ps

// BF16 native 8x8 multiplier vs exact rational arithmetic golden vectors.
module test_bf16_native_mul;
    reg clk;
    reg [15:0] opa, opb;
    reg [1:0] rmode;
    wire [15:0] result;
    wire invalid, inexact, overflow, underflow;
    integer fd, scanned, errors, tests, op_num, mode_num;
    reg [15:0] a, b, expected;
    reg same;

    bf16_mul_pipeline dut (
        .clk(clk), .opa(opa), .opb(opb), .rmode(rmode),
        .result(result), .invalid(invalid), .inexact(inexact),
        .overflow(overflow), .underflow(underflow)
    );

    always #5 clk = ~clk;

    function is_nan;
        input [15:0] bits;
        begin
            is_nan = (&bits[14:7]) && (|bits[6:0]);
        end
    endfunction

    initial begin
        clk = 0;
        opa = 0;
        opb = 0;
        rmode = 0;
        tests = 0;
        errors = 0;
        fd = $fopen("test_vectors/bf16_golden.hex", "r");
        if (fd == 0) begin
            $display("ERROR: missing test_vectors/bf16_golden.hex");
            $finish;
        end

        while (!$feof(fd)) begin
            scanned = $fscanf(fd, "%h %h %d %d %h\n",
                              a, b, op_num, mode_num, expected);
            if (scanned == 5 && op_num == 2) begin
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
                    if (errors <= 40)
                        $display("MUL MISMATCH rm=%d a=%h b=%h expected=%h got=%h",
                                 mode_num, a, b, expected, result);
                end
            end
        end
        $fclose(fd);
        $display("BF16 NATIVE MUL: %0d cases, %0d mismatches", tests, errors);
        if (errors != 0) $display("BF16_NATIVE_MUL_FAILED");
        else $display("BF16_NATIVE_MUL_PASSED");
        $finish;
    end
endmodule
