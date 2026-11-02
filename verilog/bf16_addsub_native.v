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

// Four-edge pipeline with work balanced across the first three edges.
// Edge 1 aligns and classifies operands; edge 2 adds/subtracts; edge 3
// normalizes, rounds, and generates flags; edge 4 presents the output.
// This preserves the externally visible latency of the original pipeline.
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
    // The combinational reference module above remains available for
    // standalone testing. The pipelined implementation uses the same
    // arithmetic, but registers intermediate values at useful boundaries.
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

    // A priority encoder replaces the former eleven serial conditional
    // normalizing shifts and exponent decrements.
    function [3:0] leading_zeroes11;
        input [10:0] value;
        begin
            casez (value)
                11'b1??????????: leading_zeroes11 = 4'd0;
                11'b01?????????: leading_zeroes11 = 4'd1;
                11'b001????????: leading_zeroes11 = 4'd2;
                11'b0001???????: leading_zeroes11 = 4'd3;
                11'b00001??????: leading_zeroes11 = 4'd4;
                11'b000001?????: leading_zeroes11 = 4'd5;
                11'b0000001????: leading_zeroes11 = 4'd6;
                11'b00000001???: leading_zeroes11 = 4'd7;
                11'b000000001??: leading_zeroes11 = 4'd8;
                11'b0000000001?: leading_zeroes11 = 4'd9;
                11'b00000000001: leading_zeroes11 = 4'd10;
                default:         leading_zeroes11 = 4'd11;
            endcase
        end
    endfunction

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
    wire effective_b_sign = opb[15] ^ subtract;
    wire [7:0] ea = (expa == 0) ? 8'd1 : expa;
    wire [7:0] eb = (expb == 0) ? 8'd1 : expb;
    wire [7:0] sig_a = {expa != 0, fra};
    wire [7:0] sig_b = {expb != 0, frb};

    // First combinational stage: exponent alignment and special values.
    reg [10:0] aligned_a_c, aligned_b_c;
    reg [8:0] exp_c;
    reg special_c, special_invalid_c;
    reg [15:0] special_result_c;
    always @* begin
        aligned_a_c = 0;
        aligned_b_c = 0;
        exp_c = 9'd1;
        special_c = 0;
        special_invalid_c = 0;
        special_result_c = 0;

        if (ea >= eb) begin
            exp_c = {1'b0, ea};
            aligned_a_c = {sig_a, 3'b0};
            aligned_b_c = shift_right_jam({sig_b, 3'b0}, ea - eb);
        end else begin
            exp_c = {1'b0, eb};
            aligned_a_c = shift_right_jam({sig_a, 3'b0}, eb - ea);
            aligned_b_c = {sig_b, 3'b0};
        end

        if (a_nan || b_nan) begin
            special_c = 1;
            special_result_c = 16'h7fc0;
            special_invalid_c = a_snan || b_snan;
        end else if (a_inf && b_inf) begin
            special_c = 1;
            if (opa[15] != effective_b_sign) begin
                special_result_c = 16'h7fc0;
                special_invalid_c = 1;
            end else begin
                special_result_c = {opa[15], 8'hff, 7'b0};
            end
        end else if (a_inf) begin
            special_c = 1;
            special_result_c = {opa[15], 8'hff, 7'b0};
        end else if (b_inf) begin
            special_c = 1;
            special_result_c = {effective_b_sign, 8'hff, 7'b0};
        end else if (a_zero && b_zero) begin
            special_c = 1;
            special_result_c = {(opa[15] == effective_b_sign) ?
                                opa[15] : (rmode == 2'd3), 15'b0};
        end
    end

    reg [10:0] aligned_a_s1, aligned_b_s1;
    reg [8:0] exp_s1;
    reg sign_a_s1, sign_b_s1;
    reg [1:0] mode_s1;
    reg special_s1, special_invalid_s1;
    reg [15:0] special_result_s1;

    // Second combinational stage: the shared add/subtract datapath.
    reg [11:0] sum_c;
    reg sign_c;
    always @* begin
        sum_c = 0;
        sign_c = 0;
        if (sign_a_s1 == sign_b_s1) begin
            sign_c = sign_a_s1;
            sum_c = {1'b0, aligned_a_s1} + {1'b0, aligned_b_s1};
        end else if (aligned_a_s1 > aligned_b_s1) begin
            sign_c = sign_a_s1;
            sum_c = {1'b0, aligned_a_s1 - aligned_b_s1};
        end else if (aligned_b_s1 > aligned_a_s1) begin
            sign_c = sign_b_s1;
            sum_c = {1'b0, aligned_b_s1 - aligned_a_s1};
        end else begin
            sign_c = (mode_s1 == 2'd3);
        end
    end

    reg [11:0] sum_s2;
    reg sign_s2;
    reg [8:0] exp_s2;
    reg [1:0] mode_s2;
    reg special_s2, special_invalid_s2;
    reg [15:0] special_result_s2;

    // Third combinational stage: normalize, round, and set IEEE flags.
    reg [15:0] final_result_c;
    reg invalid_c, inexact_c, overflow_c, underflow_c;
    reg [10:0] magnitude_c;
    reg [8:0] exp_work_c, headroom_c;
    reg [3:0] zeros_c, shift_c;
    reg [7:0] retained_c;
    reg [8:0] rounded_c;
    reg guard_c, round_c, sticky_c, round_up_c, above_max_c;
    always @* begin
        final_result_c = 0;
        invalid_c = 0;
        inexact_c = 0;
        overflow_c = 0;
        underflow_c = 0;
        magnitude_c = 0;
        exp_work_c = exp_s2;
        headroom_c = 0;
        zeros_c = 0;
        shift_c = 0;
        retained_c = 0;
        rounded_c = 0;
        guard_c = 0;
        round_c = 0;
        sticky_c = 0;
        round_up_c = 0;
        above_max_c = 0;

        if (special_s2) begin
            final_result_c = special_result_s2;
            invalid_c = special_invalid_s2;
        end else if (sum_s2 == 0) begin
            final_result_c = {sign_s2, 15'b0};
        end else begin
            if (sum_s2[11]) begin
                magnitude_c = sum_s2[11:1];
                magnitude_c[0] = magnitude_c[0] | sum_s2[0];
                exp_work_c = exp_s2 + 9'd1;
            end else begin
                magnitude_c = sum_s2[10:0];
            end

            zeros_c = leading_zeroes11(magnitude_c);
            headroom_c = exp_work_c - 9'd1;
            if (headroom_c < {5'b0, zeros_c})
                shift_c = headroom_c[3:0];
            else
                shift_c = zeros_c;
            magnitude_c = magnitude_c << shift_c;
            exp_work_c = exp_work_c - {5'b0, shift_c};

            retained_c = magnitude_c[10:3];
            guard_c = magnitude_c[2];
            round_c = magnitude_c[1];
            sticky_c = magnitude_c[0];
            inexact_c = guard_c || round_c || sticky_c;
            case (mode_s2)
                2'd0: round_up_c = guard_c &&
                     (round_c || sticky_c || retained_c[0]);
                2'd1: round_up_c = 0;
                2'd2: round_up_c = !sign_s2 && inexact_c;
                2'd3: round_up_c = sign_s2 && inexact_c;
            endcase
            rounded_c = {1'b0, retained_c} + {8'b0, round_up_c};

            above_max_c = (exp_work_c > 9'd254) ||
                          (exp_work_c == 9'd254 &&
                           retained_c == 8'hff && inexact_c);
            if (above_max_c) begin
                overflow_c = 1;
                inexact_c = 1;
                if ((mode_s2 == 2'd0 &&
                     (exp_work_c > 9'd254 || round_up_c)) ||
                    (mode_s2 == 2'd2 && !sign_s2) ||
                    (mode_s2 == 2'd3 && sign_s2))
                    final_result_c = {sign_s2, 8'hff, 7'b0};
                else
                    final_result_c = {sign_s2, 8'hfe, 7'h7f};
            end else if (exp_work_c == 9'd1 && !magnitude_c[10]) begin
                if (rounded_c[7])
                    final_result_c = {sign_s2, 8'h01, 7'b0};
                else
                    final_result_c = {sign_s2, 8'h00, rounded_c[6:0]};
                underflow_c = inexact_c && (final_result_c[14:7] == 0);
            end else begin
                if (rounded_c[8]) begin
                    rounded_c = rounded_c >> 1;
                    exp_work_c = exp_work_c + 9'd1;
                end
                if (exp_work_c >= 9'd255) begin
                    overflow_c = 1;
                    inexact_c = 1;
                    if (mode_s2 == 2'd0 ||
                        (mode_s2 == 2'd2 && !sign_s2) ||
                        (mode_s2 == 2'd3 && sign_s2))
                        final_result_c = {sign_s2, 8'hff, 7'b0};
                    else
                        final_result_c = {sign_s2, 8'hfe, 7'h7f};
                end else begin
                    final_result_c = {sign_s2, exp_work_c[7:0], rounded_c[6:0]};
                end
            end
        end
    end

    reg [19:0] stage3_packet;
    always @(posedge clk) begin
        // Edge 1: alignment and special-case classification.
        aligned_a_s1 <= aligned_a_c;
        aligned_b_s1 <= aligned_b_c;
        exp_s1 <= exp_c;
        sign_a_s1 <= opa[15];
        sign_b_s1 <= effective_b_sign;
        mode_s1 <= rmode;
        special_s1 <= special_c;
        special_invalid_s1 <= special_invalid_c;
        special_result_s1 <= special_result_c;

        // Edge 2: significand arithmetic.
        sum_s2 <= sum_c;
        sign_s2 <= sign_c;
        exp_s2 <= exp_s1;
        mode_s2 <= mode_s1;
        special_s2 <= special_s1;
        special_invalid_s2 <= special_invalid_s1;
        special_result_s2 <= special_result_s1;

        // Edge 3: normalization and rounding.
        stage3_packet <= {invalid_c, inexact_c, overflow_c,
                          underflow_c, final_result_c};

        // Edge 4: externally visible result.
        {invalid, inexact, overflow, underflow, result} <= stage3_packet;
    end
endmodule
