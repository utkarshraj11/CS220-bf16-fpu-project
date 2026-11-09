// FP32 baseline testbench (OpenCores FPU, module fpu).
// Streams vectors from fp32_golden_model.py, one operation per cycle, and
// checks out / inf / qnan / zero / div_by_zero LAT rising edges later.
// Works unchanged for RTL and gate-level (netlist) simulation.
//
// Plusargs:
//   +VECTORS=<file>   vector file (default test_vectors/fp32_baseline_vectors.hex)
//   +VCD=<file>       dump a VCD of the DUT (used for PrimeTime power)
//   +VERBOSE          print every case, not only failures
`timescale 1ns / 100ps
module test_fp32_baseline;
  parameter real PERIOD = 10.0;   // override with +define+ or -pvalue for netlist runs
  parameter integer LAT = 4;      // fpu: "delivers a result four cycles later"
  parameter integer MAXV = 4096;

  reg         clk = 0;
  reg  [1:0]  rmode = 0;
  reg  [2:0]  fpu_op = 0;
  reg  [31:0] opa = 0, opb = 0;
  wire [31:0] out;
  wire inf, snan, qnan, ine, overflow, underflow, zero, div_by_zero;

  fpu dut(.clk(clk), .rmode(rmode), .fpu_op(fpu_op), .opa(opa), .opb(opb), .out(out),
          .inf(inf), .snan(snan), .qnan(qnan), .ine(ine), .overflow(overflow),
          .underflow(underflow), .zero(zero), .div_by_zero(div_by_zero));

  always #(PERIOD/2.0) clk = ~clk;

  reg [7:0]  v_oprm [0:MAXV-1];
  reg [31:0] v_a [0:MAXV-1], v_b [0:MAXV-1], v_exp [0:MAXV-1];
  reg [3:0]  v_flg [0:MAXV-1];
  reg [8*64-1:0] v_name [0:MAXV-1];
  integer n, i, fd, rc, errors, checked, issued;
  reg [8*256-1:0] vecfile, vcdfile, line;
  reg verbose;

  function is_nan(input [31:0] x);
    is_nan = (x[30:23] == 8'hff) && (x[22:0] != 0);
  endfunction

  task check(input integer k);
    reg ok;
    reg [3:0] got_flags;
    begin
      got_flags = {inf, qnan, zero, div_by_zero};
      ok = (is_nan(v_exp[k]) ? is_nan(out) : (out === v_exp[k])) && (got_flags === v_flg[k]);
      checked = checked + 1;
      if (!ok) errors = errors + 1;
      if (!ok || verbose)
        $write("%s op=%0d rm=%0d a=%h b=%h got=%h exp=%h flags(inf,qnan,zero,dbz) got=%b exp=%b %0s",
               ok ? "PASS" : "FAIL", v_oprm[k][7:4], v_oprm[k][3:0], v_a[k], v_b[k],
               out, v_exp[k], got_flags, v_flg[k], v_name[k]);
    end
  endtask

  initial begin
    errors = 0; checked = 0; issued = 0; n = 0;
    verbose = $test$plusargs("VERBOSE");
    if (!$value$plusargs("VECTORS=%s", vecfile)) vecfile = "test_vectors/fp32_baseline_vectors.hex";
    if ($value$plusargs("VCD=%s", vcdfile)) begin
      $dumpfile(vcdfile);
      $dumpvars(0, test_fp32_baseline.dut);
    end
    fd = $fopen(vecfile, "r");
    if (fd == 0) begin $display("ERROR: cannot open %0s", vecfile); $fatal(1); end
    while (!$feof(fd) && n < MAXV) begin
      rc = $fscanf(fd, "%h %h %h %h %h", v_oprm[n], v_a[n], v_b[n], v_exp[n], v_flg[n]);
      if (rc == 5) begin
        rc = $fgets(line, fd);           // rest of line: "// name"
        v_name[n] = line;
        n = n + 1;
      end else rc = $fgets(line, fd);
    end
    $fclose(fd);
    $display("Loaded %0d vectors from %0s (latency %0d cycles)", n, vecfile, LAT);
  end

  // drive on falling edge, one new operation per cycle
  always @(negedge clk) begin
    if (n > 0 && issued < n) begin
      fpu_op <= v_oprm[issued][6:4];
      rmode  <= v_oprm[issued][1:0];
      opa    <= v_a[issued];
      opb    <= v_b[issued];
      issued <= issued + 1;
    end
  end

  // operation k is captured on rising edge k+1 and appears LAT edges later;
  // sample just before the next falling edge
  integer edges = 0;
  always @(posedge clk) begin
    edges = edges + 1;
    #(PERIOD/4.0);
    if (edges - LAT >= 1 && edges - LAT <= n) check(edges - LAT - 1);
    if (n > 0 && edges - LAT == n) begin
      $display("RESULT: %0d / %0d checks passed, %0d failed", checked - errors, checked, errors);
      if (errors) $fatal(1, "FP32 baseline: %0d mismatches", errors);
      $display("ALL TESTS PASSED");
      $finish;
    end
  end
endmodule
