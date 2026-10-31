`timescale 1ns / 100ps

// File-driven comparison against direct, one-round BF16 software oracle.
// Generate vectors first:
//   python3 test_vectors/bf16_reference.py --vectors-out test_vectors/bf16_golden.hex
// Run from fpu_work/ so the relative path below resolves correctly.
//
// A prototype-vs-oracle mismatch is reported, not silently ignored.
// NaN payload bits are intentionally ignored (only NaN classification).
module test_bf16_golden;
    reg clk;
    reg [1:0] rmode;
    reg [2:0] fpu_op;
    reg [15:0] opa, opb;
    wire [15:0] out;
    wire inf, snan, qnan, ine, overflow, underflow, zero, div_by_zero;
    integer fd, scanned, errors, tests, op_num, mode_num;
    reg [15:0] a, b, expected;
    reg same;

    fpu_bf16_wrapper dut (
        .clk(clk), .rmode(rmode), .fpu_op(fpu_op),
        .opa(opa), .opb(opb), .out(out), .inf(inf),
        .snan(snan), .qnan(qnan), .ine(ine),
        .overflow(overflow), .underflow(underflow),
        .zero(zero), .div_by_zero(div_by_zero)
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
        fpu_op = 0;
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
            if (scanned == 5) begin
                @(negedge clk);
                opa = a;
                opb = b;
                fpu_op = op_num[2:0];
                rmode = mode_num[1:0];
                repeat (4) @(posedge clk);
                #2;
                tests = tests + 1;
                same = (is_nan(expected) && is_nan(out)) || (out === expected);
                if (!same) begin
                    errors = errors + 1;
                    if (errors <= 40)
                        $display("MISMATCH op=%d rm=%d a=%h b=%h expected=%h got=%h",
                                 op_num, mode_num, a, b, expected, out);
                end
            end
        end
        $fclose(fd);
        $display("BF16 GOLDEN: %0d cases, %0d mismatches", tests, errors);
        if (errors != 0)
            $display("BF16_ORACLE_MISMATCHES (investigate before claiming equivalence)");
        else
            $display("BF16_ORACLE_PASSED");
        $finish;
    end
endmodule
