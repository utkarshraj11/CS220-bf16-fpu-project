`timescale 1ns/1ps

// Check four-edge latency while feeding a new BF16 add/sub operation on
// every clock edge. Result bits are compared to bf16_golden.hex.
// Exception flags need separate directed checking.
module test_bf16_native_addsub_stream;
    reg clk;
    reg [15:0] opa, opb;
    reg subtract;
    reg [1:0] rmode;
    wire [15:0] result;
    wire invalid, inexact, overflow, underflow;
    reg [15:0] expected_pipe [0:3];
    reg valid_pipe [0:3];
    integer fd, parsed, op, mode, i, sent, checked, failures;
    reg [15:0] vec_a, vec_b, vec_expected;

    bf16_addsub_pipeline dut (
        .clk(clk), .opa(opa), .opb(opb), .subtract(subtract),
        .rmode(rmode), .result(result), .invalid(invalid),
        .inexact(inexact), .overflow(overflow), .underflow(underflow)
    );

    always #5 clk = ~clk;

    task clock_transaction;
        input [15:0] next_a, next_b, next_expected;
        input next_subtract;
        input [1:0] next_mode;
        input next_valid;
        begin
            @(negedge clk);
            opa = next_a;
            opb = next_b;
            subtract = next_subtract;
            rmode = next_mode;
            @(posedge clk);
            expected_pipe[3] = expected_pipe[2];
            expected_pipe[2] = expected_pipe[1];
            expected_pipe[1] = expected_pipe[0];
            expected_pipe[0] = next_expected;
            valid_pipe[3] = valid_pipe[2];
            valid_pipe[2] = valid_pipe[1];
            valid_pipe[1] = valid_pipe[0];
            valid_pipe[0] = next_valid;
            #1; // Wait until the DUT's nonblocking assignments have settled.
            if (valid_pipe[3]) begin
                checked = checked + 1;
                if (result !== expected_pipe[3]) begin
                    failures = failures + 1;
                    if (failures <= 20)
                        $display("PIPELINE FAIL check=%0d expected=%h actual=%h",
                                 checked, expected_pipe[3], result);
                end
            end
        end
    endtask

    initial begin
        clk = 0;
        opa = 0;
        opb = 0;
        subtract = 0;
        rmode = 0;
        sent = 0;
        checked = 0;
        failures = 0;
        for (i = 0; i < 4; i = i + 1) begin
            expected_pipe[i] = 0;
            valid_pipe[i] = 0;
        end
        fd = $fopen("test_vectors/bf16_golden.hex", "r");
        if (fd == 0)
            $fatal(1, "Cannot open test_vectors/bf16_golden.hex");

        while (!$feof(fd)) begin
            parsed = $fscanf(fd, "%h %h %d %d %h\n",
                             vec_a, vec_b, op, mode, vec_expected);
            if (parsed == 5 && (op == 0 || op == 1)) begin
                clock_transaction(vec_a, vec_b, vec_expected,
                                  op == 1, mode, 1'b1);
                sent = sent + 1;
            end else if (parsed != 5 && !$feof(fd)) begin
                $fatal(1, "Malformed golden-reference vector file");
            end
        end
        $fclose(fd);

        // Drain the three transactions that remain in the pipeline.
        repeat (3)
            clock_transaction(0, 0, 0, 0, 0, 1'b0);

        $display("BF16 NATIVE ADDSUB STREAM: %0d sent, %0d checked, %0d failures",
                 sent, checked, failures);
        if (sent == 0 || checked != sent || failures != 0)
            $fatal(1, "BF16_NATIVE_ADDSUB_STREAM_FAILED");
        $display("BF16_NATIVE_ADDSUB_STREAM_PASSED");
        $finish;
    end
endmodule
