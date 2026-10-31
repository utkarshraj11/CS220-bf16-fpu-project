// Native BF16 multiplier datapath. Unlike fpu_bf16_wrapper, this really uses
// an 8x8 significand multiplier (16 product bits), not a 24x24 FP32 multiplier.
//
// Four IEEE-754 rounding modes, finite/subnormal/infinity/zero/NaN handling,
// and tininess-after-rounding status outputs. Validate against the exact
// software oracle before treating this as production-equivalent.

module bf16_mul_comb (
    input wire [15:0] opa,
    input wire [15:0] opb,
    input wire [1:0] rmode,
    output reg [15:0] result,
    output reg invalid,
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

    reg [7:0] sig_a, sig_b;
    reg [15:0] product;
    reg [4:0] highest;
    reg signed [11:0] ea, eb, unbiased_exp, shift;
    reg [15:0] truncated;
    reg [8:0] rounded;
    reg [8:0] encoded_exp;
    reg guard_bit, sticky_bit, round_up;
    reg tiny_before_round;
    reg beyond_max;
    integer i;

    always @* begin
        // Defaults are deliberate: fully combinational, with no latches.
        result = 16'h0000;
        invalid = 1'b0;
        inexact = 1'b0;
        overflow = 1'b0;
        underflow = 1'b0;
        sig_a = {expa != 0, fra};
        sig_b = {expb != 0, frb};
        product = sig_a * sig_b;  // the actual native 8 x 8 multiplication
        highest = 0;
        ea = (expa == 0) ? -12'sd126 : $signed({4'b0000, expa}) - 12'sd127;
        eb = (expb == 0) ? -12'sd126 : $signed({4'b0000, expb}) - 12'sd127;
        unbiased_exp = 0;
        shift = 0;
        truncated = 0;
        rounded = 0;
        encoded_exp = 0;
        guard_bit = 0;
        sticky_bit = 0;
        round_up = 0;
        tiny_before_round = 0;
        beyond_max = 0;

        if (a_nan || b_nan) begin
            result = 16'h7fc0;
            invalid = (a_nan && !fra[6]) || (b_nan && !frb[6]);
        end else if ((a_inf && b_zero) || (b_inf && a_zero)) begin
            result = 16'h7fc0;
            invalid = 1'b1;
        end else if (a_inf || b_inf) begin
            result = {sign, 8'hff, 7'h00};
        end else if (a_zero || b_zero) begin
            result = {sign, 15'b0};
        end else begin
            for (i = 0; i < 16; i = i + 1)
                if (product[i]) highest = i;

            // The exact value is product * 2^(ea + eb - 14).
            unbiased_exp = ea + eb - 12'sd14 + $signed({7'b0, highest});
            tiny_before_round = unbiased_exp < -12'sd126;

            if (!tiny_before_round) begin
                // Eight significand bits, including the hidden leading one.
                shift = $signed({7'b0, highest}) - 12'sd7;
                encoded_exp = unbiased_exp + 12'sd127;
            end else begin
                // BF16 subnormal unit is 2^-133. Round the product directly
                // in those units; a carry can round up to minimum normal.
                shift = -(ea + eb + 12'sd119);
                encoded_exp = 0;
            end

            if (shift < 0) begin
                truncated = product << (-shift);
            end else if (shift == 0) begin
                truncated = product;
            end else if (shift > 16) begin
                truncated = 0;
                guard_bit = 0;
                sticky_bit = |product;
            end else begin
                truncated = product >> shift;
                guard_bit = product[shift - 1];
                // Bits strictly below guard form the sticky bit.
                for (i = 0; i < 16; i = i + 1)
                    if (i < shift - 1 && product[i]) sticky_bit = 1;
            end

            inexact = guard_bit || sticky_bit;
            case (rmode)
                2'd0: round_up = guard_bit && (sticky_bit || truncated[0]);
                2'd1: round_up = 1'b0;
                2'd2: round_up = !sign && inexact;
                2'd3: round_up = sign && inexact;
            endcase
            rounded = {1'b0, truncated[7:0]} + round_up;

            // Values above maximum BF16 finite overflow even when directed
            // rounding saturates at max finite rather than infinity.
            beyond_max = (unbiased_exp > 12'sd127) ||
                         (unbiased_exp == 12'sd127 &&
                          truncated[7:0] == 8'hff && inexact);
            if (beyond_max) begin
                overflow = 1;
                inexact = 1;
                if (rmode == 2'd0 ||
                    (rmode == 2'd2 && !sign) ||
                    (rmode == 2'd3 && sign))
                    result = {sign, 8'hff, 7'h00};
                else
                    result = {sign, 8'hfe, 7'h7f};
            end else if (tiny_before_round) begin
                if (rounded[7])
                    result = {sign, 8'h01, 7'h00};
                else
                    result = {sign, 8'h00, rounded[6:0]};
                underflow = inexact && (result[14:7] == 0);
            end else begin
                if (rounded[8]) begin
                    encoded_exp = encoded_exp + 1;
                    rounded = rounded >> 1;
                end
                // A rounding carry into exponent 255 is an overflow.
                if (encoded_exp >= 255) begin
                    overflow = 1;
                    inexact = 1;
                    if (rmode == 2'd0 ||
                        (rmode == 2'd2 && !sign) ||
                        (rmode == 2'd3 && sign))
                        result = {sign, 8'hff, 7'h00};
                    else
                        result = {sign, 8'hfe, 7'h7f};
                end else begin
                    result = {sign, encoded_exp[7:0], rounded[6:0]};
                end
            end
        end
    end
endmodule


// Pipeline interface: operands registered at stage 1, native arithmetic
// registered at stage 2, two result registers at stages 3 and 4.
module bf16_mul_pipeline (
    input wire clk,
    input wire [15:0] opa,
    input wire [15:0] opb,
    input wire [1:0] rmode,
    output reg [15:0] result,
    output reg invalid,
    output reg inexact,
    output reg overflow,
    output reg underflow
);
    reg [15:0] opa_r, opb_r;
    reg [1:0] rmode_r;
    wire [15:0] comb_result;
    wire comb_invalid, comb_inexact, comb_overflow, comb_underflow;
    reg [19:0] stage2, stage3;

    bf16_mul_comb u_mul (
        .opa(opa_r), .opb(opb_r), .rmode(rmode_r),
        .result(comb_result), .invalid(comb_invalid),
        .inexact(comb_inexact), .overflow(comb_overflow),
        .underflow(comb_underflow)
    );

    always @(posedge clk) begin
        opa_r <= opa;
        opb_r <= opb;
        rmode_r <= rmode;
        stage2 <= {comb_invalid, comb_inexact, comb_overflow,
                   comb_underflow, comb_result};
        stage3 <= stage2;
        {invalid, inexact, overflow, underflow, result} <= stage3;
    end
endmodule
