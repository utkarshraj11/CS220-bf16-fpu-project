// Hybrid BF16 arithmetic prototype with native BF16 mul/div datapaths.
//
// BF16: sign[15], exponent[14:7] (bias 127), fraction[6:0].
// Multiplication and division use native BF16 significands. Addition and
// subtraction still use the OpenCores FP32 core with BF16 quantization.
// Area and power savings must be measured, not assumed.
//
// Floating point operations: 0:add, 1:sub, 2:mul, 3:div.
// Rounding modes (OpenCores): 0:nearest-even, 1:zero, 2:+infinity, 3:-infinity.
// Conversion operations 4/5 are deliberately not supported by this 16-bit
// arithmetic interface because they need a separate 32-bit integer port.
//
// Input-to-output latency: same 4 rising edges as the original FPU.

module fpu_bf16_wrapper (
    input wire clk,
    input wire [1:0] rmode,
    input wire [2:0] fpu_op,
    input wire [15:0] opa,
    input wire [15:0] opb,
    output wire [15:0] out,
    output wire inf,
    output wire snan,
    output wire qnan,
    output wire ine,
    output wire overflow,
    output wire underflow,
    output wire zero,
    output wire div_by_zero
);
    wire [31:0] fp32_out;
    wire fp32_inf, fp32_snan, fp32_qnan, fp32_ine;
    wire fp32_overflow, fp32_underflow, fp32_zero, fp32_div_by_zero;

    // The native multiplier accepts a BF16 transaction on every rising edge
    // and produces its BF16 result and exception flags on the fourth edge.
    wire [15:0] native_mul_result;
    wire native_mul_invalid, native_mul_inexact;
    wire native_mul_overflow, native_mul_underflow;
    bf16_mul_pipeline u_native_mul (
        .clk(clk), .opa(opa), .opb(opb), .rmode(rmode),
        .result(native_mul_result), .invalid(native_mul_invalid),
        .inexact(native_mul_inexact), .overflow(native_mul_overflow),
        .underflow(native_mul_underflow)
    );

    // Native BF16 divider has the same four-edge latency as multiplication.
    // Keeping the paths independent allows mixed operations every clock.
    wire [15:0] native_div_result;
    wire native_div_invalid, native_div_by_zero, native_div_inexact;
    wire native_div_overflow, native_div_underflow;
    bf16_div_pipeline u_native_div (
        .clk(clk), .opa(opa), .opb(opb), .rmode(rmode),
        .result(native_div_result), .invalid(native_div_invalid),
        .div_by_zero(native_div_by_zero), .inexact(native_div_inexact),
        .overflow(native_div_overflow), .underflow(native_div_underflow)
    );

    wire op_is_mul = (fpu_op == 3'd2);
    wire op_is_div = (fpu_op == 3'd3);
    wire a_is_snan = (&opa[14:7]) && !opa[6] && (|opa[5:0]);
    wire b_is_snan = (&opb[14:7]) && !opb[6] && (|opb[5:0]);
    reg [3:0] mul_select_pipe, div_select_pipe, native_snan_pipe;
    always @(posedge clk) begin
        mul_select_pipe <= {mul_select_pipe[2:0], op_is_mul};
        div_select_pipe <= {div_select_pipe[2:0], op_is_div};
        native_snan_pipe <= {native_snan_pipe[2:0], a_is_snan || b_is_snan};
    end
    wire select_native_mul = mul_select_pipe[3];
    wire select_native_div = div_select_pipe[3];

    // The legacy FP32 core shows misaligned infinity-pair add/sub results in
    // streaming mode. Native mul/div handle their own special cases.
    wire opa_is_inf = (&opa[14:7]) && !(|opa[6:0]);
    wire opb_is_inf = (&opb[14:7]) && !(|opb[6:0]);
    wire inf_pair = opa_is_inf && opb_is_inf;
    wire addsub_pair = inf_pair && (fpu_op == 3'd0 || fpu_op == 3'd1);
    wire effective_b_sign = opb[15] ^ (fpu_op == 3'd1);
    wire addsub_same_sign = opa[15] == effective_b_sign;
    reg [3:0] addsub_inf_pipe, addsub_nan_pipe, addsub_sign_pipe;
    always @(posedge clk) begin
        addsub_inf_pipe <= {addsub_inf_pipe[2:0], addsub_pair && addsub_same_sign};
        addsub_nan_pipe <= {addsub_nan_pipe[2:0], addsub_pair && !addsub_same_sign};
        addsub_sign_pipe <= {addsub_sign_pipe[2:0], opa[15]};
    end
    wire corrected_inf = addsub_inf_pipe[3];
    wire corrected_nan = addsub_nan_pipe[3];
    wire corrected_special = corrected_inf || corrected_nan;
    wire corrected_sign = addsub_sign_pipe[3];

    // BF16 encodings are exact FP32 numbers when 16 zero fraction bits
    // are appended. Keep opa/opb widths constant for all arithmetic ops.
    // Only add/sub require legacy arithmetic. Redirect native mul/div and
    // unsupported int conversion operations to add, whose output is ignored.
    // This should permit the wide FP32 mul/div datapaths to be pruned in
    // synthesis; a controlled synthesis run must verify the actual savings.
    wire [2:0] legacy_op = (fpu_op == 3'd1) ? 3'd1 : 3'd0;
    fpu u_fp32 (
        .clk(clk), .rmode(rmode), .fpu_op(legacy_op),
        .opa({opa, 16'h0000}), .opb({opb, 16'h0000}),
        .out(fp32_out), .inf(fp32_inf), .snan(fp32_snan),
        .qnan(fp32_qnan), .ine(fp32_ine),
        .overflow(fp32_overflow), .underflow(fp32_underflow),
        .zero(fp32_zero), .div_by_zero(fp32_div_by_zero)
    );

    // The source FPU samples operands on edge 1 and registers outputs on
    // edge 4. Align the rounding mode to those registered outputs.
    reg [1:0] rm1, rm2, rm3, rm4;
    always @(posedge clk) begin
        rm1 <= rmode;
        rm2 <= rm1;
        rm3 <= rm2;
        rm4 <= rm3;
    end

    wire [15:0] top = fp32_out[31:16];
    wire [15:0] discarded = fp32_out[15:0];
    wire discarded_nonzero = |discarded;
    wire [7:0] exponent = top[14:7];
    wire fp32_is_nan = (&fp32_out[30:23]) && (|fp32_out[22:0]);
    wire fp32_is_inf = (&fp32_out[30:23]) && !(|fp32_out[22:0]);
    wire finite = !(&fp32_out[30:23]);

    wire increment =
        (rm4 == 2'd0) ?
            (discarded[15] && ((|discarded[14:0]) || top[0])) :
        (rm4 == 2'd1) ? 1'b0 :
        (rm4 == 2'd2) ? (!top[15] && discarded_nonzero) :
                       (top[15] && discarded_nonzero);

    wire [15:0] finite_rounded = top + {15'b0, increment};

    // FP32 NaNs can have their payload exclusively in the low 16 fraction
    // bits; preserve the NaN class rather than accidentally producing Inf.
    assign out = select_native_mul ? native_mul_result :
                 select_native_div ? native_div_result :
                 corrected_inf ? {corrected_sign, 8'hff, 7'b0} :
                 corrected_nan ? 16'h7fc0 :
                 fp32_is_nan ? {top[15], 8'hff, 1'b1, 6'b0} :
                 fp32_is_inf ? {top[15], 8'hff, 7'b0} :
                 finite_rounded;

    wire bf16_is_inf = (&out[14:7]) && !(|out[6:0]);
    wire bf16_is_nan = (&out[14:7]) && (|out[6:0]);
    wire bf16_is_zero = !(|out[14:0]);
    wire bf16_is_subnormal_or_zero = !(|out[14:7]);
    wire bf16_inexact = fp32_ine || (finite && discarded_nonzero);

    // These status flags include BF16 output quantization. Full IEEE-754
    // flag equivalence is a separate verification target for the native core.
    assign ine = select_native_mul ? native_mul_inexact :
                 select_native_div ? native_div_inexact :
                 (!corrected_special && bf16_inexact);
    assign overflow = select_native_mul ? native_mul_overflow :
                      select_native_div ? native_div_overflow :
                      (!corrected_special && (fp32_overflow ||
                      (finite && exponent == 8'hfe &&
                       (&top[6:0]) && discarded_nonzero)));
    assign underflow = select_native_mul ? native_mul_underflow :
                       select_native_div ? native_div_underflow :
                       (!corrected_special && (fp32_underflow ||
                       (finite && bf16_is_subnormal_or_zero && bf16_inexact)));
    assign inf = select_native_mul ? bf16_is_inf :
                 select_native_div ? bf16_is_inf :
                 (corrected_inf ||
                  (!corrected_special && (fp32_inf || (!fp32_is_nan && bf16_is_inf))));
    assign zero = bf16_is_zero;
    assign qnan = select_native_mul ? (bf16_is_nan || native_mul_invalid) :
                  select_native_div ? (bf16_is_nan || native_div_invalid) :
                  (corrected_nan || (!corrected_special && fp32_qnan));
    assign snan = (select_native_mul || select_native_div) ? native_snan_pipe[3] :
                  (!corrected_special && fp32_snan);
    assign div_by_zero = select_native_mul ? 1'b0 :
                         select_native_div ? native_div_by_zero :
                         (!corrected_special && fp32_div_by_zero);

endmodule
