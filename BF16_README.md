# BF16 project starter — CS220 Team 5-2

This workspace contains the **unmodified OpenCores FP32 computational design**, a separately named BF16 arithmetic prototype, and an independent BF16 oracle. The only edits to original RTL are conditional guards around old testbench-specific debug code in `verilog/fpu.v` and `verilog/post_norm.v`; they do not alter the synthesized arithmetic.

The new prototype is `verilog/fpu_bf16_wrapper.v`. It accepts two 16-bit BF16 inputs, executes an operation in the four-stage FP32 FPU, then rounds the 32-bit result to BF16 using the requested rounding mode. It supports add/sub/multiply/divide (opcodes 0–3) and all four rounding modes. Integer conversion operations need separate 32-bit integer ports and are not part of this first prototype.

**Important limitation:** This is a format/integration prototype, not yet the native reduced-width BF16 hardware design. Internal arithmetic is still FP32; area, timing and power improvements are not established. Correctly rounding FP32 then BF16 can also differ from directly rounding exact arithmetic to BF16 (double rounding). The exact oracle identifies such cases rather than assuming equivalence.

## Quick start

From the `fpu_work` folder on a machine with VCS or Icarus Verilog:

```bash
bash run_bf16.sh smoke
bash run_bf16.sh golden
bash run_bf16.sh mul
bash run_bf16.sh model
bash run_bf16.sh accuracy
```

- `smoke`: 12 human-readable BF16 arithmetic and rounding cases.
- `golden`: creates 5,696 deterministic software-oracle vectors (special cases and random operands across all 4 operations and 4 rounding modes), then checks BF16 hardware outputs. NaN payload bits are intentionally ignored; NaN classification is checked. Read the mismatch count instead of assuming success.
- `mul`: tests the actual **native 8x8 BF16 significand multiplier** (`verilog/bf16_mul_native.v`) against 1,424 exact-oracle multiply cases, including subnormals, extreme exponents, NaNs, infinities, zero, all rounding modes, and random values. This is a separate four-stage arithmetic unit; it has not yet been integrated into a complete native BF16 FPU.
- `model`: compares a bit-level software model of the new native BF16 multiplier architecture with the independent exact-arithmetic oracle, using directed cases plus 120,000 random inputs. This checks the algorithm, not the HDL itself.
- `accuracy`: calculates MAE, RMSE, mean/95th-percentile/max relative error compared to FP32 arithmetic on the **original** unquantized inputs. This explicitly includes input and output quantization. Samples are drawn from log-uniform magnitude distributions (approximately 1e-5 through 2e5), not a representative application workload. Large relative error near cancellation is expected and should be discussed rather than excluded from maxima.

Generating the golden vectors and running the HDL testbenches requires Python 3 and either VCS or Icarus Verilog; NumPy is needed only for the separate `accuracy` command.

The oracle is `test_vectors/bf16_reference.py` and uses exact rational arithmetic for finite BF16 values, so it provides a reference independent of the FP32 core. The `double_round` column in the accuracy report counts cases in which rounded FP32 intermediate arithmetic differs from exactly rounded BF16.

## Next steps for the *real* BF16 hardware optimization

1. Verify the original FP32 source against the original testbench and lock the baseline synthesis reports and constraints.
2. Run the BF16 wrapper smoke and oracle tests, triage deviations (especially subnormals, special values, rounding and double rounding).
3. Replace internal FP32 mantissa arithmetic with BF16-width arithmetic: 8-bit significands, 8x8 multiplication, suitably scaled 8-bit division, and compact add/sub alignment and normalization. Preserve exception and rounding semantics.
4. Synthesize **the full BF16 arithmetic implementation**, not just an external 16-bit wrapper, using the exact same cell library, clock, operating corner, constraints, and tools as the baseline.
5. Report total area, critical path and slack, dynamic/leakage/total power, verification vector counts, and accuracy loss. Note any increase in pipeline latency or throughput tradeoffs.

The November 9 midterm report should distinguish **measured results** from projected savings and clearly state which operations are complete.
