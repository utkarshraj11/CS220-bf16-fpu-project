# CS220 native BF16 multiplication + division FPU synthesis.
#
# Run in Synopsys Design Compiler on Bender after uploading all nine RTL
# source files into $HOME/cs220_final_project/bf16_mul_div/verilog/.
# Uses the same library and constraints as the FP32 baseline and the
# previous multiplier-only BF16 hybrid. Reports remain in a new directory.

set ROOT "$env(HOME)/cs220_final_project"
set RTL_DIR "$ROOT/bf16_mul_div/verilog"
set REPORT_DIR "$ROOT/syn/bf16_mul_div_reports"

file mkdir $REPORT_DIR

# SAED32 RVT slow-slow corner, 0.7 V, 125 C.
set LIB "/usr/local/synopsys/pdk/SAED32_EDK/lib/stdcell_rvt/db_nldm/saed32rvt_ss0p7v125c.db"
set_app_var target_library [list $LIB]
set_app_var link_library [list "*" $LIB]

set RTL_FILES [list \
    "$RTL_DIR/fpu.v" \
    "$RTL_DIR/except.v" \
    "$RTL_DIR/pre_norm.v" \
    "$RTL_DIR/pre_norm_fmul.v" \
    "$RTL_DIR/post_norm.v" \
    "$RTL_DIR/primitives.v" \
    "$RTL_DIR/bf16_mul_native.v" \
    "$RTL_DIR/bf16_div_native.v" \
    "$RTL_DIR/fpu_bf16_wrapper.v" \
]

foreach src $RTL_FILES {
    if {![file exists $src]} {
        error "BF16 multiplier/divider source file missing: $src"
    }
}

analyze -format verilog $RTL_FILES
elaborate fpu_bf16_wrapper
current_design fpu_bf16_wrapper
link

check_design > "$REPORT_DIR/bf16_mul_div_check_design.log"

# Identical nominal 500 MHz (2 ns period) clock and I/O constraints.
create_clock -name clk -period 2.0 -waveform {0 1} [get_ports clk]
set DATA_INPUTS [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay 0.1 -max -clock clk $DATA_INPUTS
set_output_delay 0.1 -max -clock clk [all_outputs]
set_clock_uncertainty 0.2 -setup [get_clocks clk]
set_clock_uncertainty 0.2 -hold [get_clocks clk]

compile_ultra

report_qor > "$REPORT_DIR/bf16_mul_div_qor_report.log"
report_area -hierarchy > "$REPORT_DIR/bf16_mul_div_area_report.log"
report_timing -max_paths 20 > "$REPORT_DIR/bf16_mul_div_timing_report.log"
report_power -hierarchy > "$REPORT_DIR/bf16_mul_div_power_report.log"
report_reference -hierarchy > "$REPORT_DIR/bf16_mul_div_reference_report.log"

write -format verilog -hierarchy -output "$REPORT_DIR/bf16_mul_div_mapped.v"
write_sdc "$REPORT_DIR/bf16_mul_div_constraints.sdc"

puts "BF16 MULTIPLIER + DIVIDER SYNTHESIS COMPLETE"
puts "Reports: $REPORT_DIR"
