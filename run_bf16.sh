#!/usr/bin/env bash
# Run BF16 directed tests or the exact-reference vector suite.
# Prefers Icarus Verilog; uses Synopsys VCS if Icarus is unavailable.
set -euo pipefail

cd "$(dirname "$0")"
suite="${1:-smoke}"

case "$suite" in
  smoke) top=test_bf16_wrapper ;;
  golden)
    top=test_bf16_golden
    python3 test_vectors/bf16_reference.py \
      --vectors-out test_vectors/bf16_golden.hex --random-vectors 100
    ;;
  mul)
    top=test_bf16_native_mul
    python3 test_vectors/bf16_reference.py \
      --vectors-out test_vectors/bf16_golden.hex --random-vectors 100
    ;;
  accuracy)
    python3 test_vectors/bf16_reference.py --accuracy --samples 2000
    exit 0
    ;;
  model)
    python3 test_vectors/check_native_mul_model.py
    exit 0
    ;;
  *)
    echo "Usage: bash run_bf16.sh [smoke|golden|mul|accuracy|model]" >&2
    exit 2
    ;;
esac

rtl=(
  verilog/fpu.v
  verilog/pre_norm.v
  verilog/pre_norm_fmul.v
  verilog/post_norm.v
  verilog/except.v
  verilog/primitives.v
  verilog/fpu_bf16_wrapper.v
  verilog/bf16_mul_native.v
)
tb="test_bench/${top}.v"
mkdir -p .bf16_build

if command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1; then
  iverilog -g2012 -s "$top" -o ".bf16_build/${top}.vvp" "${rtl[@]}" "$tb"
  vvp ".bf16_build/${top}.vvp"
elif command -v vcs >/dev/null 2>&1; then
  vcs -full64 -sverilog -top "$top" -o ".bf16_build/${top}.simv" \
    "${rtl[@]}" "$tb"
  ".bf16_build/${top}.simv"
else
  echo "Neither Icarus Verilog (iverilog/vvp) nor Synopsys VCS is available." >&2
  echo "Run this script on a machine with either simulator installed." >&2
  exit 1
fi
