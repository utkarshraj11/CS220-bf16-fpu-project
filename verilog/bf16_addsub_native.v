// Native BF16 addition/subtraction with one shared significand datapath.
// BF16: sign[15], exponent[14:7] (bias 127), fraction[6:0].
//
// Rounding modes: 0 nearest/even, 1 toward zero, 2 toward +infinity,
//                 3 toward -infinity.
// The four-edge pipeline matches bf16_mul_pipeline/bf16_div_pipeline.
// This module has not yet been validated against the full project oracle.

module bf16_addsub_comb (
    input wire [15:0] opa,
    input wire [15:0] opb,
    input wire subtract,
    input wire [1:0] rmode,
    output reg [15:0] result,
    output reg invalid,
    output reg inexact,
    output reg overflow,
    output reg underflow
);
    wire [7:0] expa = opa[14:7];
    wire [7:0] expb = opb[14:7];
    wire [6:0] fra = opa[6:0];
    wire [6:0] frb = opb[6:0];
    wire a_nan = (&expa) && (|fra);
    wire b_nan = (&expb) && (|frb);
    wire a_snan = a_nan && !fra[6];
    wire b_snan = b_nan && !frb[6];
    wire a_inf = (&expa) && !(|fra);
    wire b_inf = (&expb) && !(|frb);
    wire a_zero = !(|opa[14:0]);
    wire b_zero = !(|opb[14:0]);

    // Keep three rounding bits (guard, round, sticky). Bits [10:3] hold
    // the eight-bit significand, including the normal hidden leading one.
    function [10:0] shift_right_jam;
        input [10:0] value;
        input [7:0] distance;
        reg [10:0] shifted;
        reg lost;
        integer j;
        begin
            shifted = 0;
            lost = 0;
            if (distance == 0) begin
                shifted = value;
            end else if (distance >= 11) begin
                shifted = {10'b0, (|value)};
            end else begin
                shifted = value >> distance;
                for (j = 0; j < 11; j = j + 1)
                    if (j < distance && value[j]) lost = 1;
                shifted[0] = shifted[0] | lost;
            end
            shift_right_jam = shifted;
        end
    endfunction

    reg sign_b_effective, sign_out;
    reg [7:0] ea_effective, eb_effective, exp_difference;
    reg [7:0] sig_a, sig_b, retained;
    reg [10:0] aligned_a, aligned_b, magnitude;
    reg [11:0] sum;
    reg [8:0] rounded;
    reg guard_bit, round_bit, sticky_bit, round_up;
    reg above_max_finite;
    integer exp_work;
    integer i;

    always @* begin
        result = 16'h0000;
        invalid = 0;
        inexact = 0;
        overflow = 0;
        underflow = 0;
        sign_b_effective = opb[15] ^ subtract;
        sign_out = 0;
        ea_effective = (expa == 0) ? 8'd1 : expa;
        eb_effective = (expb == 0) ? 8'd1 : expb;
        exp_difference = 0;
        sig_a = {expa != 0, fra};
        sig_b = {expb != 0, frb};
        aligned_a = 0;
        aligned_b = 0;
        magnitude = 0;
        sum = 0;
        retained = 0;
        rounded = 0;
        guard_bit = 0;
        round_bit = 0;
        sticky_bit = 0;
        round_up = 0;
        above_max_finite = 0;
        exp_work = 1;

        if (a_nan || b_nan) begin
            result = 16'h7fc0;
            invalid = a_snan || b_snan;
        end else if (a_inf && b_inf) begin
            if (opa[15] != sign_b_effective) begin
                result = 16'h7fc0;
                invalid = 1;
            end else begin
                result = {opa[15], 8'hff, 7'b0};
            end
        end else if (a_inf) begin
            result = {opa[15], 8'hff, 7'b0};
        end else if (b_inf) begin
            result = {sign_b_effective, 8'hff, 7'b0};
        end else if (a_zero && b_zero) begin
            sign_out = (opa[15] == sign_b_effective) ? opa[15] :
                       (rmode == 2'd3);
            result = {sign_out, 15'b0};
        end else begin
            // Align the operand with the smaller exponent, preserving all
            // discarded bits in the sticky position.
            if (ea_effective >= eb_effective) begin
                exp_work = ea_effective;
                exp_difference = ea_effective - eb_effective;
                aligned_a = {sig_a, 3'b0};
                aligned_b = shift_right_jam({sig_b, 3'b0}, exp_difference);
            end else begin
                exp_work = eb_effective;
                exp_difference = eb_effective - ea_effective;
                aligned_a = shift_right_jam({sig_a, 3'b0}, exp_difference);
                aligned_b = {sig_b, 3'b0};
            end

            if (opa[15] == sign_b_effective) begin
                sign_out = opa[15];
                sum = {1'b0, aligned_a} + {1'b0, aligned_b};
            end else if (aligned_a > aligned_b) begin
                sign_out = opa[15];
                sum = {1'b0, aligned_a - aligned_b};
            end else if (aligned_b > aligned_a) begin
                sign_out = sign_b_effective;
                sum = {1'b0, aligned_b - aligned_a};
            end else begin
                sign_out = (rmode == 2'd3);
                sum = 0;
            end

            if (sum == 0) begin
                result = {sign_out, 15'b0};
            end else begin
                if (sum[11]) begin
                    magnitude = sum[11:1];
                    magnitude[0] = magnitude[0] | sum[0];
                    exp_work = exp_work + 1;
                end else begin
                    magnitude = sum[10:0];
                end

                // Normalize cancellation, stopping at exponent field 1 so
                // that a smaller result is encoded as a BF16 subnormal.
                for (i = 0; i < 11; i = i + 1) begin
                    if (!magnitude[10] && exp_work > 1 && magnitude != 0) begin
                        magnitude = magnitude << 1;
                        exp_work = exp_work - 1;
                    end
                end

                retained = magnitude[10:3];
                guard_bit = magnitude[2];
                round_bit = magnitude[1];
                sticky_bit = magnitude[0];
                inexact = guard_bit || round_bit || sticky_bit;
                case (rmode)
                    2'd0: round_up = guard_bit &&
                                     (round_bit || sticky_bit || retained[0]);
                    2'd1: round_up = 0;
                    2'd2: round_up = !sign_out && inexact;
                    2'd3: round_up = sign_out && inexact;
                endcase
                rounded = {1'b0, retained} + {8'b0, round_up};

                // Detect values beyond the largest finite BF16 number even
                // if directed rounding would return max finite instead.
                above_max_finite = (exp_work > 254) ||
                                   (exp_work == 254 &&
                                    retained == 8'hff && inexact);
                if (above_max_finite) begin
                    overflow = 1;
                    inexact = 1;
                    if ((rmode == 2'd0 &&
                         (exp_work > 254 || round_up)) ||
                        (rmode == 2'd2 && !sign_out) ||
                        (rmode == 2'd3 && sign_out))
                        result = {sign_out, 8'hff, 7'b0};
                    else
                        result = {sign_out, 8'hfe, 7'h7f};
                end else if (exp_work == 1 && !magnitude[10]) begin
                    // Subnormal result; rounding may raise it to min normal.
                    if (rounded[7])
                        result = {sign_out, 8'h01, 7'b0};
                    else
                        result = {sign_out, 8'h00, rounded[6:0]};
                    underflow = inexact && (result[14:7] == 0);
                end else begin
                    if (rounded[8]) begin
                        rounded = rounded >> 1;
                        exp_work = exp_work + 1;
                    end
                    if (exp_work >= 255) begin
                        overflow = 1;
                        inexact = 1;
                        if (rmode == 2'd0 ||
                            (rmode == 2'd2 && !sign_out) ||
                            (rmode == 2'd3 && sign_out))
                            result = {sign_out, 8'hff, 7'b0};
                        else
                            result = {sign_out, 8'hfe, 7'h7f};
                    end else begin
                        result = {sign_out, exp_work[7:0], rounded[6:0]};
                    end
                end
            end
        end
    end
endmodule

// Four-edge pipeline: capture operands on edge 1, compute on edge 2,
// and delay the registered result through edges 3 and 4.
module bf16_addsub_pipeline (
    input wire clk,
    input wire [15:0] opa,
    input wire [15:0] opb,
    input wire subtract,
    input wire [1:0] rmode,
    output reg [15:0] result,
    output reg invalid,
    output reg inexact,
    output reg overflow,
    output reg underflow
);
    reg [15:0] opa_r, opb_r;
    reg subtract_r;
    reg [1:0] rmode_r;
    wire [15:0] comb_result;
    wire comb_invalid, comb_inexact, comb_overflow, comb_underflow;
    reg [19:0] stage2, stage3;

    bf16_addsub_comb u_addsub (
        .opa(opa_r), .opb(opb_r), .subtract(subtract_r),
        .rmode(rmode_r), .result(comb_result),
        .invalid(comb_invalid), .inexact(comb_inexact),
        .overflow(comb_overflow), .underflow(comb_underflow)
    );

    always @(posedge clk) begin
        opa_r <= opa;
        opb_r <= opb;
        subtract_r <= subtract;
        rmode_r <= rmode;
        stage2 <= {comb_invalid, comb_inexact, comb_overflow,
                   comb_underflow, comb_result};
        stage3 <= stage2;
        {invalid, inexact, overflow, underflow, result} <= stage3;
    end
endmodule
