# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.
#
# Leaf function, no stack frame. Register use:
#   a0  a (odd once the main loop starts; holds the result at the end)
#   a1  b
#   t0  a | b while the shared factors of two are counted
#   t1  number of shared factors of two, restored by the final shift
#   t2  scratch: the bit under test, or the difference during a swap

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2
gcd_u32_asm:
    beqz    a0, .Lreturn_b          # gcd(0, b) = b
    beqz    a1, .Lreturn            # gcd(a, 0) = a

    # Count the factors of two that a and b share: the trailing zeros of a | b.
    or      t0, a0, a1
    li      t1, 0
    andi    t2, t0, 1
    bnez    t2, .Lstrip_a           # one operand is odd: nothing is shared
.Lshared:
    srli    t0, t0, 1
    addi    t1, t1, 1
    andi    t2, t0, 1
    beqz    t2, .Lshared
    srl     a0, a0, t1              # RV32I shifts by a register in one step
    srl     a1, a1, t1

    # Factors of two left in a are not shared: drop them, so that a is odd.
.Lstrip_a:
    andi    t2, a0, 1
    bnez    t2, .Lcheck_b
.Lshift_a:
    srli    a0, a0, 1
    andi    t2, a0, 1
    beqz    t2, .Lshift_a

.Lcheck_b:
    andi    t2, a1, 1
    bnez    t2, .Lcompare

    # Main loop. On entry to .Lshift b is even and nonzero, so the first shift
    # needs no test; the difference of two odd numbers always comes back here.
.Lshift:
    srli    a1, a1, 1
    andi    t2, a1, 1
    beqz    t2, .Lshift
.Lcompare:                          # a and b are both odd
    bltu    a1, a0, .Lswap
    sub     a1, a1, a0              # b = b - a, even
    bnez    a1, .Lshift
    sll     a0, a0, t1              # restore the shared factors of two
.Lreturn:
    ret

    # a > b: the new pair is (b, a - b). The difference is even and nonzero.
.Lswap:
    sub     t2, a0, a1
    mv      a0, a1
    mv      a1, t2
    j       .Lshift

.Lreturn_b:
    mv      a0, a1
    ret
    .size   gcd_u32_asm, .-gcd_u32_asm
