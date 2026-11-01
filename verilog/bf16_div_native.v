// Native BF16 divider, using 8-bit significands instead of FP32 arithmetic.
// Operand normalization is followed by a bounded 24/8 integer quotient and
// exact remainder-based guard/sticky rounding in all four rounding modes.
// This is a research RTL prototype; validate flags against SoftFloat before
// claiming full IEEE-754 exception behavior.

module bf16_div_comb (
    input wire [15:0] opa,
    input wire [15:0] opb,
    input wire [1:0] rmode,
    output reg [15:0] result,
    output reg invalid,
    output reg div_by_zero,
    output reg inexact,
    output reg overflow,
    output reg underflow
);
    wire sign = opa[15] ^ opb[15];
    wire [7:0] expa = opa[14:7];
    wire [7:0] expb = opb[14:7];
    wire [6:0] fra = opa[6:0];
    wire [6:0] frb = opb[6:0];
    wire a_nan = (&expa) && (|fra);
    wire b_nan = (&expb) && (|frb);
    wire a_inf = (&expa) && !(|fra);
    wire b_inf = (&expb) && !(|frb);
    wire a_zero = !(|opa[14:0]);
    wire b_zero = !(|opb[14:0]);

    reg [7:0] sig_a, sig_b, norm_a, norm_b;
    reg [3:0] highest_a, highest_b;
    reg [23:0] numerator;
    reg [15:0] quotient;
    reg [7:0] remainder;
    reg signed [11:0] ea, eb, unbiased_exp, shift;
    reg signed [11:0] encoded_exp;
    reg [15:0] truncated;
    reg [8:0] rounded;
    reg guard_bit, sticky_bit, round_up;
    reg tiny_before_round, beyond_max;
    integer i;

    always @* begin
        result = 16'h0000;
        invalid = 0;
        div_by_zero = 0;
        inexact = 0;
        overflow = 0;
        underflow = 0;
        sig_a = {expa != 0, fra};
        sig_b = {expb != 0, frb};
        norm_a = 0;
        norm_b = 0;
        highest_a = 0;
        highest_b = 0;
        numerator = 0;
        quotient = 0;
        remainder = 0;
        ea = (expa == 0) ? -12'sd126 : $signed({4'b0, expa}) - 12'sd127;
        eb = (expb == 0) ? -12'sd126 : $signed({4'b0, expb}) - 12'sd127;
        unbiased_exp = 0;
        encoded_exp = 0;
        shift = 0;
        truncated = 0;
        rounded = 0;
        guard_bit = 0;
        sticky_bit = 0;
        round_up = 0;
        tiny_before_round = 0;
        beyond_max = 0;

        if (a_nan || b_nan) begin
            result = 16'h7fc0;
            invalid = (a_nan && !fra[6]) || (b_nan && !frb[6]);
        end else if ((a_zero && b_zero) || (a_inf && b_inf)) begin
            result = 16'h7fc0;
            invalid = 1;
        end else if (a_inf || b_zero) begin
            result = {sign, 8'hff, 7'h00};
            div_by_zero = b_zero && !a_inf;
        end else if (a_zero || b_inf) begin
            result = {sign, 15'b0};
        end else begin
            for (i = 0; i < 8; i = i + 1) begin
                if (sig_a[i]) highest_a = i;
                if (sig_b[i]) highest_b = i;
            end
            norm_a = sig_a << (7 - highest_a);
            norm_b = sig_b << (7 - highest_b);
            // normalized significand ratio is [1, 2). Determine its true
            // exponent, including the case where norm_a < norm_b.
            unbiased_exp = ea - eb + $signed({8'b0, highest_a}) -
                           $signed({8'b0, highest_b});
            if (norm_a < norm_b)
                unbiased_exp = unbiased_exp - 12'sd1;

            // 16-bit fixed-point quotient with its most significant set bit
            // at bit 15. The remainder preserves all bits beyond bit zero.
            numerator = {16'b0, norm_a} << ((norm_a < norm_b) ? 16 : 15);
            quotient = numerator / norm_b;
            remainder = numerator % norm_b;
            tiny_before_round = unbiased_exp < -12'sd126;
            shift = tiny_before_round ? (8 - 12'sd126 - unbiased_exp) : 12'sd8;
            encoded_exp = unbiased_exp + 12'sd127;
            truncated = quotient >> shift;
            if (shift > 0 && shift <= 16)
                guard_bit = quotient[shift - 1];
            sticky_bit = (remainder != 0);
            for (i = 0; i < 16; i = i + 1)
                if (i < shift - 1 && quotient[i]) sticky_bit = 1;

            inexact = guard_bit || sticky_bit;
            case (rmode)
                2'd0: round_up = guard_bit && (sticky_bit || truncated[0]);
                2'd1: round_up = 0;
                2'd2: round_up = !sign && inexact;
                2'd3: round_up = sign && inexact;
            endcase
            rounded = {1'b0, truncated[7:0]} + round_up;
            beyond_max = (unbiased_exp > 12'sd127) ||
                         (unbiased_exp == 12'sd127 &&
                          truncated[7:0] == 8'hff && inexact);

            if (tiny_before_round) begin
                if (rounded[7])
                    result = {sign, 8'h01, 7'h00};
                else
                    result = {sign, 8'h00, rounded[6:0]};
                underflow = inexact && (result[14:7] == 0);
            end else begin
                if (rounded[8]) begin
                    encoded_exp = encoded_exp + 12'sd1;
                    rounded = rounded >> 1;
                end
                if (encoded_exp >= 12'sd255) begin
                    if (rmode == 2'd0 ||
                        (rmode == 2'd2 && !sign) ||
                        (rmode == 2'd3 && sign))
                        result = {sign, 8'hff, 7'h00};
                    else
                        result = {sign, 8'hfe, 7'h7f};
                end else begin
                    result = {sign, encoded_exp[7:0], rounded[6:0]};
                end
                if (beyond_max || encoded_exp >= 12'sd255) begin
                    overflow = 1;
                    inexact = 1;
                end
            end
        end
    end
endmodule

// Same four-edge latency and one-operation-per-clock throughput as our native
// BF16 multiplier. Stage 1 captures inputs, stage 2 performs the calculation,
// and stages 3 and 4 align the result with the wrapper's output pipeline.
module bf16_div_pipeline (
    input wire clk,
    input wire [15:0] opa,
    input wire [15:0] opb,
    input wire [1:0] rmode,
    output reg [15:0] result,
    output reg invalid,
    output reg div_by_zero,
    output reg inexact,
    output reg overflow,
    output reg underflow
);
    reg [15:0] opa_r, opb_r;
    reg [1:0] rmode_r;
    wire [15:0] comb_result;
    wire comb_invalid, comb_div_by_zero, comb_inexact;
    wire comb_overflow, comb_underflow;
    reg [20:0] stage2, stage3;

    bf16_div_comb u_div (
        .opa(opa_r), .opb(opb_r), .rmode(rmode_r),
        .result(comb_result), .invalid(comb_invalid),
        .div_by_zero(comb_div_by_zero), .inexact(comb_inexact),
        .overflow(comb_overflow), .underflow(comb_underflow)
    );

    always @(posedge clk) begin
        opa_r <= opa;
        opb_r <= opb;
        rmode_r <= rmode;
        stage2 <= {comb_invalid, comb_div_by_zero, comb_inexact,
                   comb_overflow, comb_underflow, comb_result};
        stage3 <= stage2;
        {invalid, div_by_zero, inexact, overflow, underflow, result} <= stage3;
    end
endmodule
