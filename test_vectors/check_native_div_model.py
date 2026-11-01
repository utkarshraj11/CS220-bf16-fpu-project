#!/usr/bin/env python3
"""Check the integer algorithm used in bf16_div_native.v against our oracle.

This Python port is *not* a Verilog simulation; run the HDL testbench with
Icarus Verilog separately before integrating the native divider.
"""

import argparse
import random

from bf16_reference import bf16_op


def native_div_model(a, b, mode):
    sign = ((a ^ b) >> 15) & 1
    exp_a, exp_b = (a >> 7) & 255, (b >> 7) & 255
    frac_a, frac_b = a & 127, b & 127
    nan_a, nan_b = exp_a == 255 and frac_a != 0, exp_b == 255 and frac_b != 0
    inf_a, inf_b = exp_a == 255 and frac_a == 0, exp_b == 255 and frac_b == 0
    zero_a, zero_b = exp_a == 0 and frac_a == 0, exp_b == 0 and frac_b == 0
    if nan_a or nan_b or (zero_a and zero_b) or (inf_a and inf_b):
        return 0x7FC0
    if inf_a or zero_b:
        return sign << 15 | 0x7F80
    if zero_a or inf_b:
        return sign << 15

    sa, sb = (128 if exp_a else 0) + frac_a, (128 if exp_b else 0) + frac_b
    ea, eb = (exp_a - 127 if exp_a else -126), (exp_b - 127 if exp_b else -126)
    ha, hb = sa.bit_length() - 1, sb.bit_length() - 1
    na, nb = sa << (7 - ha), sb << (7 - hb)
    less = na < nb
    exp = ea - eb + ha - hb - int(less)
    num = na << (16 if less else 15)
    quotient, rem = divmod(num, nb)
    tiny = exp < -126
    shift = 8 - 126 - exp if tiny else 8
    truncated = quotient >> shift
    guard = bool(quotient & (1 << (shift - 1))) if shift <= 16 else False
    sticky = bool(rem or (quotient & ((1 << (shift - 1)) - 1)))
    inexact = guard or sticky
    if mode == 0:
        inc = guard and (sticky or (truncated & 1))
    elif mode == 1:
        inc = False
    elif mode == 2:
        inc = not sign and inexact
    else:
        inc = bool(sign and inexact)
    rounded = truncated + int(inc)

    if tiny:
        value = 0x0080 if rounded >= 128 else rounded
        return sign << 15 | value

    if rounded >= 256:
        exp += 1
        rounded >>= 1
    if exp > 127:
        to_inf = mode == 0 or (mode == 2 and not sign) or (mode == 3 and sign)
        value = 0x7F80 if to_inf else 0x7F7F
    else:
        value = (exp + 127) << 7 | (rounded & 127)
    return sign << 15 | value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--random", type=int, default=100_000)
    parser.add_argument("--seed", type=int, default=220)
    args = parser.parse_args()
    count = 0
    with open("test_vectors/bf16_golden.hex", encoding="ascii") as source:
        for line in source:
            a, b, op, mode, expected = line.split()
            if int(op) != 3:
                continue
            aa, bb, mm, ee = int(a, 16), int(b, 16), int(mode), int(expected, 16)
            actual = native_div_model(aa, bb, mm)
            if actual != ee:
                raise AssertionError(f"Golden mismatch {aa:04x}/{bb:04x} rm={mm}: {actual:04x} != {ee:04x}")
            count += 1
    print(f"Native divider arithmetic model: {count} golden cases passed")
    rng = random.Random(args.seed)
    for i in range(args.random):
        aa, bb, mm = rng.randrange(0x10000), rng.randrange(0x10000), rng.randrange(4)
        actual, expected = native_div_model(aa, bb, mm), bf16_op(aa, bb, 3, mm)
        if actual != expected:
            raise AssertionError(f"Random #{i} {aa:04x}/{bb:04x} rm={mm}: {actual:04x} != {expected:04x}")
    print(f"Native divider arithmetic model: {args.random} randomized cases passed")


if __name__ == "__main__":
    main()
