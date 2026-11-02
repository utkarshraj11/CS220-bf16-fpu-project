// Fully native BF16 arithmetic wrapper: add, subtract, multiply, and divide.
// BF16: sign[15], exponent[14:7] (bias 127), fraction[6:0].
//
// Floating-point opcodes: 0:add, 1:sub, 2:mul, 3:div.
// Rounding modes: 0:nearest/even, 1:zero, 2:+infinity, 3:-infinity.
// Integer conversion opcodes 4/5 are not supported by this 16-bit interface.
//
// All native paths accept one operation each rising edge and return the
// corresponding result/flags on the fourth rising edge. This wrapper no
// longer instantiates the original OpenCores FP32 datapath.
//
// Verify independently and run the full regression suite before committing.

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
    wire [15:0] native_addsub_result;
    wire native_addsub_invalid, native_addsub_inexact;
    wire native_addsub_overflow, native_addsub_underflow;
    bf16_addsub_pipeline u_native_addsub (
        .clk(clk), .opa(opa), .opb(opb),
        .subtract(fpu_op == 3'd1), .rmode(rmode),
        .result(native_addsub_result), .invalid(native_addsub_invalid),
        .inexact(native_addsub_inexact),
        .overflow(native_addsub_overflow),
        .underflow(native_addsub_underflow)
    );

    wire [15:0] native_mul_result;
    wire native_mul_invalid, native_mul_inexact;
    wire native_mul_overflow, native_mul_underflow;
    bf16_mul_pipeline u_native_mul (
        .clk(clk), .opa(opa), .opb(opb), .rmode(rmode),
        .result(native_mul_result), .invalid(native_mul_invalid),
        .inexact(native_mul_inexact), .overflow(native_mul_overflow),
        .underflow(native_mul_underflow)
    );

    wire [15:0] native_div_result;
    wire native_div_invalid, native_div_by_zero, native_div_inexact;
    wire native_div_overflow, native_div_underflow;
    bf16_div_pipeline u_native_div (
        .clk(clk), .opa(opa), .opb(opb), .rmode(rmode),
        .result(native_div_result), .invalid(native_div_invalid),
        .div_by_zero(native_div_by_zero),
        .inexact(native_div_inexact), .overflow(native_div_overflow),
        .underflow(native_div_underflow)
    );

    // Keep op selection and signaling-NaN detection aligned with the
    // four-edge latency of all three native arithmetic pipelines.
    wire op_is_addsub = (fpu_op == 3'd0 || fpu_op == 3'd1);
    wire op_is_mul = (fpu_op == 3'd2);
    wire op_is_div = (fpu_op == 3'd3);
    wire a_is_snan = (&opa[14:7]) && !opa[6] && (|opa[5:0]);
    wire b_is_snan = (&opb[14:7]) && !opb[6] && (|opb[5:0]);

    reg [3:0] addsub_select_pipe, mul_select_pipe, div_select_pipe;
    reg [3:0] native_snan_pipe;
    always @(posedge clk) begin
        addsub_select_pipe <= {addsub_select_pipe[2:0], op_is_addsub};
        mul_select_pipe <= {mul_select_pipe[2:0], op_is_mul};
        div_select_pipe <= {div_select_pipe[2:0], op_is_div};
        native_snan_pipe <= {native_snan_pipe[2:0],
                             a_is_snan || b_is_snan};
    end

    wire select_native_addsub = addsub_select_pipe[3];
    wire select_native_mul = mul_select_pipe[3];
    wire select_native_div = div_select_pipe[3];
    wire valid_op = select_native_addsub || select_native_mul ||
                    select_native_div;

    // Unsupported opcodes produce a quiet NaN instead of performing an
    // undocumented integer-conversion operation.
    assign out = select_native_addsub ? native_addsub_result :
                 select_native_mul ? native_mul_result :
                 select_native_div ? native_div_result : 16'h7fc0;

    wire bf16_is_inf = (&out[14:7]) && !(|out[6:0]);
    wire bf16_is_nan = (&out[14:7]) && (|out[6:0]);
    wire bf16_is_zero = !(|out[14:0]);

    assign inf = bf16_is_inf;
    assign qnan = bf16_is_nan;
    assign zero = bf16_is_zero;
    assign snan = valid_op && native_snan_pipe[3];
    assign ine = select_native_addsub ? native_addsub_inexact :
                 select_native_mul ? native_mul_inexact :
                 select_native_div ? native_div_inexact : 1'b0;
    assign overflow = select_native_addsub ? native_addsub_overflow :
                      select_native_mul ? native_mul_overflow :
                      select_native_div ? native_div_overflow : 1'b0;
    assign underflow = select_native_addsub ? native_addsub_underflow :
                       select_native_mul ? native_mul_underflow :
                       select_native_div ? native_div_underflow : 1'b0;
    assign div_by_zero = select_native_div && native_div_by_zero;
endmodule
