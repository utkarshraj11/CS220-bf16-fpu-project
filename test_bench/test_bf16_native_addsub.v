`timescale 1ns/1ps

// Standalone result-bit verification against the existing exact BF16 oracle.
// Run from the repository root so test_vectors/bf16_golden.hex is found.
// Flags and the four-edge pipeline need additional independent tests.
module test_bf16_native_addsub;
    reg [15:0] opa, opb;
    reg subtract;
    reg [1:0] rmode;
    wire [15:0] result;
    wire invalid, inexact, overflow, underflow;

    bf16_addsub_comb dut (
        .opa(opa), .opb(opb), .subtract(subtract), .rmode(rmode),
        .result(result), .invalid(invalid), .inexact(inexact),
        .overflow(overflow), .underflow(underflow)
    );

    integer file_handle, parsed, opcode, rounding;
    integer tested, failed;
    reg [15:0] vector_a, vector_b, expected;

    initial begin
        opa = 0;
        opb = 0;
        subtract = 0;
        rmode = 0;
        tested = 0;
        failed = 0;
        file_handle = $fopen("test_vectors/bf16_golden.hex", "r");
        if (file_handle == 0)
            $fatal(1, "Cannot open test_vectors/bf16_golden.hex");

        while (!$feof(file_handle)) begin
            parsed = $fscanf(file_handle, "%h %h %d %d %h\n",
                             vector_a, vector_b, opcode, rounding, expected);
            if (parsed == 5 && (opcode == 0 || opcode == 1)) begin
                opa = vector_a;
                opb = vector_b;
                subtract = (opcode == 1);
                rmode = rounding;
                #1;
                tested = tested + 1;
                if (result !== expected) begin
                    failed = failed + 1;
                    if (failed <= 20)
                        $display("FAIL op=%0d rm=%0d a=%h b=%h expected=%h actual=%h",
                                 opcode, rounding, vector_a, vector_b,
                                 expected, result);
                end
            end else if (parsed != 5 && !$feof(file_handle)) begin
                $fatal(1, "Malformed golden-reference vector file");
            end
        end
        $fclose(file_handle);
        $display("BF16 NATIVE ADDSUB: %0d cases, %0d failures", tested, failed);
        if (tested == 0 || failed != 0)
            $fatal(1, "BF16_NATIVE_ADDSUB_FAILED");
        $display("BF16_NATIVE_ADDSUB_PASSED");
        $finish;
    end
endmodule
