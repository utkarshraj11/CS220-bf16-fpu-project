# CS220 BF16 FPU implementation workplan

Project: Faster and Smaller BF16 Floating-Point Unit (Team 5-2)

## Scope

- Optimize **bfloat16** (1 sign bit, 8 exponent bits, 7 stored fraction bits).
- Keep the OpenCores FP32 core untouched as a comparison baseline.
- Start with a BF16 input/output adapter to establish correct format handling and a repeatable accuracy experiment.
- Then narrow the internal BF16 datapath. The adapter is a **prototype**, not proof of an 8-bit native datapath or any area improvement.
- Keep all four IEEE-754 rounding directions and explicitly evaluate NaNs, signed zero, infinities, subnormals, overflow and inexact results.
- Retain the original four-stage pipeline latency where feasible.

## Deliverables for the November 4 progress update

1. Reproducible original FP32 baseline and tool settings.
2. BF16 encoding/decoding and reference conversion checks.
3. Directed test vectors and numerical accuracy measurements.
4. BF16 RTL prototype and simulation status.

## Deliverables for the November 9 midterm

1. BF16 implementation block diagram and source changes.
2. Simulation pass/fail counts, all four rounding modes, special-case test coverage.
3. Baseline vs. BF16 area, timing, power *measured with identical constraints* when available.
4. Quantization evaluation: MAE, RMSE, relative error distribution and max error, separating input/output quantization from arithmetic effects.
5. Remaining native-datapath work and limitations, clearly described.

## Measurement cautions

- BF16 and FP32 have the same exponent range, but different precision. BF16 has 8 significand bits including the implicit bit; FP32 has 24.
- Casting an already rounded FP32 result to BF16 can produce rare double-rounding differences from direct correctly rounded BF16 arithmetic. Do not claim bit-exact native BF16 without a proper BF16 reference and tests.
- A 16-bit external interface does not automatically imply narrow internal adders, multipliers, dividers, or a smaller synthesized design.
- Report numerical errors separately from RTL functional mismatches. Intentional BF16 quantization differs from an RTL bug.
