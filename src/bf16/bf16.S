# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.
#
# All three are leaf functions without a stack frame. The ABI passes a
# uint16_t zero-extended, so bits 16 to 31 of the arguments are zero.

    .equ    BF16_QNAN, 0x7FC0
    .equ    BF16_INF, 0x7F80

    .text

# bf16_from_f32: keep the top 16 bits, round to nearest, ties to even.
#
# The contract adds 0x7FFF plus bit 16 and keeps the top half. The same result
# comes from rounding half up, by adding 0x8000, and then repairing the one
# case where that differs: an exact tie, where the discarded half was 0x8000
# and is now zero. After a tie the kept half was incremented; clearing its
# lowest bit yields the even neighbor, whichever parity it had before.
#
# Register use:
#   t0  exponent field in place, then the discarded half after rounding
#   t1  0x7F800000, then 0x8000
    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    lui     t1, 0x7F800
    and     t0, a0, t1
    beq     t0, t1, .Lf32_keep      # Inf or NaN: no rounding
    lui     t1, 0x8
    add     a0, a0, t1              # round half up
    slli    t0, a0, 16
    beqz    t0, .Lf32_tie
.Lf32_keep:
    srli    a0, a0, 16
    ret
.Lf32_tie:
    srli    a0, a0, 16
    andi    a0, a0, -2              # ties to even
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

# bf16_mul
#
# Register use:
#   a0, a1  operands; a0 also carries the result
#   t0      exponent of a, then the result exponent
#   t1      exponent of b
#   t2      significand of a (bit 7 set after normalization)
#   t3      significand of b
#   t4      scratch: constants, the bit under test, shift counts
#   t5      significand product, then the result fraction
#   t6      sign of the result, in bit 15

# One step of the 8-bit multiply: add a << k when bit k of b is set.
    .macro  MUL_STEP k
    andi    t4, t3, 1 << \k
    beqz    t4, 1f
    slli    t4, t2, \k
    add     t5, t5, t4
1:
    .endm

    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    xor     t6, a0, a1
    lui     t4, 0x8
    and     t6, t6, t4              # sign = (a ^ b) & 0x8000
    srli    t0, a0, 7
    andi    t0, t0, 0xFF
    srli    t1, a1, 7
    andi    t1, t1, 0xFF
    andi    t2, a0, 0x7F
    andi    t3, a1, 0x7F
    li      t4, 0xFF
    beq     t0, t4, .Lmul_a_special # a is examined first
    beq     t1, t4, .Lmul_b_special

    beqz    t0, .Lmul_a_small
    ori     t2, t2, 0x80            # hidden one
.Lmul_a_ready:
    beqz    t1, .Lmul_b_small
    ori     t3, t3, 0x80
.Lmul_b_ready:
    add     t0, t0, t1
    addi    t0, t0, -127            # exponents add, one bias comes off

    # 8-bit by 8-bit product, unrolled. Bit 7 of b is always set, so that
    # partial product starts the sum; the other seven are added on demand.
    slli    t5, t2, 7
    andi    t4, t3, 1
    beqz    t4, 1f
    add     t5, t5, t2
1:
    MUL_STEP 1
    MUL_STEP 2
    MUL_STEP 3
    MUL_STEP 4
    MUL_STEP 5
    MUL_STEP 6

    # The product lies in [2^14, 2^16). With its leading one at bit 15 it is
    # shifted by 8 and the exponent goes up; otherwise it is shifted by 7. The
    # bits shifted out are dropped: the fraction is truncated.
    srli    t4, t5, 15
    add     t0, t0, t4
    addi    t4, t4, 7
    srl     t5, t5, t4
    andi    t5, t5, 0x7F

    li      t4, 0xFF
    bge     t0, t4, .Lmul_inf
    blez    t0, .Lmul_denormal
    slli    t0, t0, 7
    or      a0, t6, t0
    or      a0, a0, t5
    ret

    # Result exponent <= 0: shift the fraction right by 1 - exponent; below -6
    # nothing is left and the result is a signed zero.
.Lmul_denormal:
    li      t4, -6
    blt     t0, t4, .Lmul_zero
    li      t4, 1
    sub     t4, t4, t0
    srl     t5, t5, t4
    or      a0, t6, t5
    ret

    # Exponent field 0: a zero, or a denormal whose leading one is shifted up
    # to bit 7 while the exponent, starting from 1, counts the shifts.
.Lmul_a_small:
    beqz    t2, .Lmul_zero
    li      t0, 1
1:
    slli    t2, t2, 1
    addi    t0, t0, -1
    andi    t4, t2, 0x80
    beqz    t4, 1b
    j       .Lmul_a_ready

.Lmul_b_small:
    beqz    t3, .Lmul_zero
    li      t1, 1
1:
    slli    t3, t3, 1
    addi    t1, t1, -1
    andi    t4, t3, 0x80
    beqz    t4, 1b
    j       .Lmul_b_ready

.Lmul_zero:
    mv      a0, t6
    ret

    # a is Inf or NaN. A NaN is returned as it is; Inf times zero is the quiet
    # NaN; Inf times anything else, a NaN b included, is Inf.
.Lmul_a_special:
    bnez    t2, .Lmul_return
    or      t4, t1, t3
    beqz    t4, .Lmul_nan
.Lmul_inf:
    li      t4, BF16_INF
    or      a0, t6, t4
.Lmul_return:
    ret

    # b is Inf or NaN and a is finite.
.Lmul_b_special:
    mv      a0, a1
    bnez    t3, .Lmul_return
    or      t4, t0, t2
    bnez    t4, .Lmul_inf
.Lmul_nan:
    li      a0, BF16_QNAN
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

# bf16_sqrt
#
# For a positive normal, value = 2^e * m / 128 with m in [128, 256) and
# e = exp - 127. When e is odd (exp even) m is doubled, and the new exponent
# field is (exp + 127) >> 1 in both cases. The contract's root, the largest mid
# with (mid * mid) / 128 <= m, is the integer square root of
# n = 128 * (m + 1) - 1, which lies in [16511, 65535]; the root is in
# [128, 255], so it needs no renormalization.
#
# The root is found digit by digit, without a multiply. r is kept scaled so
# that r + bit is what the trial bit would add to the square:
#   trial = r + bit; r >>= 1; if (n >= trial) { n -= trial; r += bit; }
# for bit = 2^14, 2^12, ..., 1. Since n >= 2^14 the first step is always taken,
# and it is folded into the second one as constants.
#
# Register use:
#   t0  exponent field, then the new exponent
#   t1  fraction, then n (the remainder)
#   t2  sign, then r (the root)
#   t3  scratch: the trial value

    .macro  SQRT_STEP bit
    addi    t3, t2, \bit
    srli    t2, t2, 1
    bltu    t1, t3, 1f
    sub     t1, t1, t3
    addi    t2, t2, \bit
1:
    .endm

    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    srli    t0, a0, 7
    andi    t0, t0, 0xFF
    andi    t1, a0, 0x7F
    li      t3, 0xFF
    srli    t2, a0, 15
    beq     t0, t3, .Lsqrt_special
    bnez    t2, .Lsqrt_negative
    beqz    t0, .Lsqrt_zero         # +0 and positive denormals

    ori     t1, t1, 0x80            # m, with the hidden one
    andi    t3, t0, 1
    xori    t3, t3, 1               # 1 when the true exponent is odd
    addi    t3, t3, 7
    sll     t1, t1, t3              # 128 * m, doubled for an odd exponent
    addi    t1, t1, 127             # n = 128 * (m + 1) - 1
    addi    t0, t0, 127
    srli    t0, t0, 1               # new exponent field

    # bit = 2^14 (always taken) and bit = 2^12.
    lui     t3, 0x4
    sub     t1, t1, t3              # n -= 2^14
    lui     t2, 0x2                 # r = 2^14 >> 1
    lui     t3, 0x5                 # trial = 2^14 + 2^12
    bltu    t1, t3, 1f
    sub     t1, t1, t3
    lui     t2, 0x3                 # r = (2^14 >> 1) + 2^12
1:
    SQRT_STEP 1024
    SQRT_STEP 256
    SQRT_STEP 64
    SQRT_STEP 16
    SQRT_STEP 4

    # bit = 1: the remainder is not needed afterwards.
    addi    t3, t2, 1
    srli    t2, t2, 1
    bltu    t1, t3, 1f
    addi    t2, t2, 1
1:
    andi    t2, t2, 0x7F            # drop the hidden one
    slli    t0, t0, 7
    or      a0, t0, t2
    ret

    # Negative and not Inf or NaN: -0 gives +0, anything else the quiet NaN.
.Lsqrt_negative:
    slli    t3, a0, 17              # drop the sign bit
    beqz    t3, .Lsqrt_zero
.Lsqrt_nan:
    li      a0, BF16_QNAN
    ret

.Lsqrt_zero:
    li      a0, 0
    ret

    # Exponent field 0xFF: a NaN and +Inf are returned as they are, -Inf gives
    # the quiet NaN.
.Lsqrt_special:
    bnez    t1, .Lsqrt_return
    bnez    t2, .Lsqrt_nan
.Lsqrt_return:
    ret
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm
