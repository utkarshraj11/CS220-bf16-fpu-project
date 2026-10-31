// BF16 arithmetic prototype around the unmodified OpenCores FP32 FPU.
//
// BF16: sign[15], exponent[14:7] (bias 127), fraction[6:0].
// This *is not* a native 8-bit-significand implementation. FP32 is used
// internally, then its result is rounded to BF16. It is intended to validate
// the external format, quantify rounding error, and provide an integration
// target before the internal datapaths are made narrower.
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

    // BF16 encodings are exact FP32 numbers when 16 zero fraction bits
    // are appended. Keep opa/opb widths constant for all arithmetic ops.
    fpu u_fp32 (
        .clk(clk), .rmode(rmode), .fpu_op(fpu_op),
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
    assign out = fp32_is_nan ? {top[15], 8'hff, 1'b1, 6'b0} :
                 fp32_is_inf ? {top[15], 8'hff, 7'b0} :
                 finite_rounded;

    wire bf16_is_inf = (&out[14:7]) && !(|out[6:0]);
    wire bf16_is_zero = !(|out[14:0]);
    wire bf16_is_subnormal_or_zero = !(|out[14:7]);
    wire bf16_inexact = fp32_ine || (finite && discarded_nonzero);

    // These status flags include BF16 output quantization. Full IEEE-754
    // flag equivalence is a separate verification target for the native core.
    assign ine = bf16_inexact;
    assign overflow = fp32_overflow ||
                      (finite && exponent == 8'hfe &&
                       (&top[6:0]) && discarded_nonzero);
    assign underflow = fp32_underflow ||
                       (finite && bf16_is_subnormal_or_zero && bf16_inexact);
    assign inf = fp32_inf || (!fp32_is_nan && bf16_is_inf);
    assign zero = bf16_is_zero;
    assign qnan = fp32_qnan;
    assign snan = fp32_snan;
    assign div_by_zero = fp32_div_by_zero;

endmodule
