# CS220 BF16 Hybrid FPU - synthesis under the original FP32 baseline constraints.
#
# Run in Synopsys Design Compiler on Bender after placing the eight Verilog
# source files in $HOME/cs220_final_project/bf16_hybrid/verilog/.
#
# This flow deliberately writes into a new reports directory. It does not
# modify the existing FP32 baseline reports or compiled netlists.

set ROOT "$env(HOME)/cs220_final_project"
set RTL_DIR "$ROOT/bf16_hybrid/verilog"
set REPORT_DIR "$ROOT/syn/bf16_hybrid_reports"

file mkdir $REPORT_DIR

# Match the baseline: SAED32 RVT, SS, 0.7 V, 125 C.
set LIB "/usr/local/synopsys/pdk/SAED32_EDK/lib/stdcell_rvt/db_nldm/saed32rvt_ss0p7v125c.db"
set_app_var target_library [list $LIB]
set_app_var link_library [list "*" $LIB]

# All arithmetic RTL is needed for the hybrid BF16 top-level.
set RTL_FILES [list \
    "$RTL_DIR/fpu.v" \
    "$RTL_DIR/except.v" \
    "$RTL_DIR/pre_norm.v" \
    "$RTL_DIR/pre_norm_fmul.v" \
    "$RTL_DIR/post_norm.v" \
    "$RTL_DIR/primitives.v" \
    "$RTL_DIR/bf16_mul_native.v" \
    "$RTL_DIR/fpu_bf16_wrapper.v" \
]

foreach src $RTL_FILES {
    if {![file exists $src]} {
        error "BF16 source file missing: $src"
    }
}

analyze -format verilog $RTL_FILES
elaborate fpu_bf16_wrapper
current_design fpu_bf16_wrapper
link

check_design > "$REPORT_DIR/bf16_check_design.log"

# Identical 500 MHz timing constraints to the original FP32 FPU run.
create_clock -name clk -period 2.0 -waveform {0 1} [get_ports clk]
set DATA_INPUTS [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay 0.1 -max -clock clk $DATA_INPUTS
set_output_delay 0.1 -max -clock clk [all_outputs]
set_clock_uncertainty 0.2 -setup [get_clocks clk]
set_clock_uncertainty 0.2 -hold [get_clocks clk]

compile_ultra

# Keep results separate from the original FP32 baseline.
report_qor > "$REPORT_DIR/bf16_qor_report.log"
report_area -hierarchy > "$REPORT_DIR/bf16_area_report.log"
report_timing -max_paths 20 > "$REPORT_DIR/bf16_timing_report.log"
report_power -hierarchy > "$REPORT_DIR/bf16_power_report.log"
report_reference -hierarchy > "$REPORT_DIR/bf16_reference_report.log"

write -format verilog -hierarchy -output "$REPORT_DIR/bf16_mapped.v"
write_sdc "$REPORT_DIR/bf16_constraints.sdc"

puts "BF16 HYBRID SYNTHESIS COMPLETE"
puts "Reports: $REPORT_DIR"
