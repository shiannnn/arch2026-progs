# op1, op2, op3 and q_mul: hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)   a0, a1, a2 -> a0
# uint32_t op2_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# uint32_t op3_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# int32_t  q_mul_asm(int32_t a, int32_t b)           a0, a1 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. q_mul forms a 64-bit product in a register pair. Tests:
# tests/tfixed.c.
#
# All four are leaf functions without a stack frame.

    .text

# op1: a + b by carry propagation, with the pass count stored through a2.
#
# Register use:
#   a0  partial sum (a ^ b)
#   a1  carry word ((a & b) << 1); the loop ends when it is zero
#   a2  int *n
#   t0  passes completed
#   t1  scratch: a & b
#
# The loop is unrolled four times, so the counter is updated once per four
# passes; a carry that dies inside a group leaves through the exit that adds
# the passes of that group.

# One pass: c = (a & b) << 1, a = a ^ b, b = c.
    .macro  OP1_PASS
    and     t1, a0, a1
    xor     a0, a0, a1
    slli    a1, t1, 1
    .endm

    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:
    li      t0, 0
    beqz    a1, .Lop1_done
.Lop1_loop:
    OP1_PASS
    beqz    a1, .Lop1_exit1
    OP1_PASS
    beqz    a1, .Lop1_exit2
    OP1_PASS
    beqz    a1, .Lop1_exit3
    OP1_PASS
    addi    t0, t0, 4
    bnez    a1, .Lop1_loop
.Lop1_done:
    sw      t0, 0(a2)
    ret
.Lop1_exit1:
    addi    t0, t0, 1
    sw      t0, 0(a2)
    ret
.Lop1_exit2:
    addi    t0, t0, 2
    sw      t0, 0(a2)
    ret
.Lop1_exit3:
    addi    t0, t0, 3
    sw      t0, 0(a2)
    ret
    .size   op1_asm, .-op1_asm

# op2: a - b modulo 2^32.
    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub     a0, a0, a1
    ret
    .size   op2_asm, .-op2_asm

# op3: floor((a + b) / 2) with no 33-bit sum. Since a + b equals
# 2 * (a & b) + (a ^ b), the half is (a & b) + ((a ^ b) >> 1).
#
# Register use: t0 = a & b.
    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    and     t0, a0, a1
    xor     a0, a0, a1
    srli    a0, a0, 1
    add     a0, a0, t0
    ret
    .size   op3_asm, .-op3_asm

# q_mul: Q11.20 product, (a * b + 2^19) >> 20 with a floor shift, low 32 bits.
#
# The product is formed on magnitudes: M = |a| * |b| by shift-and-add into a
# register pair, with the smaller magnitude as the multiplier so that the loop
# ends early. The sign is applied at the end. For a negative product -M,
#   floor((-M + 2^19) / 2^20) = -floor((M + 2^19 - 1) / 2^20)
# so the rounding constant is 2^19 for a positive product and 2^19 - 1 for a
# negative one, which keeps ties rounding toward plus infinity.
#
# Register use:
#   a0  multiplicand, low word (shifted left every pass)
#   t1  multiplicand, high word
#   a1  multiplier (shifted right every pass)
#   t2  product, low word
#   t3  product, high word
#   t4  a ^ b: bit 31 is the sign of the product
#   t0  scratch: sign mask, bit under test, carry
    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
    xor     t4, a0, a1
    srai    t0, a0, 31              # |a| = (a ^ mask) - mask
    xor     a0, a0, t0
    sub     a0, a0, t0
    srai    t0, a1, 31              # |b|
    xor     a1, a1, t0
    sub     a1, a1, t0
    bgeu    a0, a1, .Lqmul_ordered  # keep the smaller magnitude in a1
    mv      t0, a0
    mv      a0, a1
    mv      a1, t0
.Lqmul_ordered:
    li      t1, 0
    li      t2, 0
    li      t3, 0
    beqz    a1, .Lqmul_round

.Lqmul_loop:
    andi    t0, a1, 1
    beqz    t0, .Lqmul_next
    add     t2, t2, a0              # 64-bit add of the multiplicand
    sltu    t0, t2, a0              # carry out of the low word
    add     t3, t3, t1
    add     t3, t3, t0
.Lqmul_next:
    srli    t0, a0, 31              # 64-bit shift left by one
    slli    t1, t1, 1
    or      t1, t1, t0
    slli    a0, a0, 1
    srli    a1, a1, 1
    bnez    a1, .Lqmul_loop

.Lqmul_round:
    srli    t4, t4, 31              # 1 when the product is negative
    lui     t0, 0x80                # 2^19
    sub     t0, t0, t4              # 2^19 - 1 for a negative product
    add     t0, t2, t0
    sltu    t2, t0, t2              # carry into the high word
    add     t3, t3, t2
    srli    t0, t0, 20              # bits 20 to 51 of the sum
    slli    t3, t3, 12
    or      a0, t0, t3
    beqz    t4, .Lqmul_return
    neg     a0, a0
.Lqmul_return:
    ret
    .size   q_mul_asm, .-q_mul_asm
