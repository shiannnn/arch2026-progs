#include "fixed.h"

/* Addition from logic: a ^ b is the sum without carries and (a & b) << 1 is
 * the carries moved to the position they add into. Repeating until no carry is
 * left yields a + b modulo 2^32; a carry travels at most 32 positions, so the
 * loop runs at most 32 times. The pass count is part of the result.
 */
uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    int passes = 0;
    while (b) {
        uint32_t c = (a & b) << 1;
        a ^= b;
        b = c;
        passes++;
    }
    *n = passes;
    return a;
}

/* a - b modulo 2^32. The bitwise model is op1(a, op1(~b, 1)), that is, adding
 * the two's complement of b; unsigned subtraction gives the same value.
 */
uint32_t op2(uint32_t a, uint32_t b)
{
    return a - b;
}

/* floor((a + b) / 2) without forming the 33-bit sum: a + b equals
 * 2 * (a & b) + (a ^ b), so the half is (a & b) + ((a ^ b) >> 1).
 */
uint32_t op3(uint32_t a, uint32_t b)
{
    return (a & b) + ((a ^ b) >> 1);
}

/* Q11.20 product: (a * b + 2^19) >> 20, keeping the low 32 bits.
 *
 * The 64-bit product is kept as a pair of 32-bit words and built from four
 * 16-bit by 16-bit partial products of the bit patterns, each of which fits
 * in 32 bits and needs only the 32-bit multiply of the runtime:
 *   a * b = hh * 2^32 + (lh + hl) * 2^16 + ll
 * That is the unsigned product. Reading a pattern x as signed subtracts 2^32
 * when its top bit is set, so the signed product differs from the unsigned
 * one only in the high word: by b when a is negative and by a when b is
 * negative.
 */
int32_t q_mul(int32_t a, int32_t b)
{
    uint32_t ua = (uint32_t) a, ub = (uint32_t) b;
    uint32_t al = ua & 0xFFFFu, ah = ua >> 16;
    uint32_t bl = ub & 0xFFFFu, bh = ub >> 16;

    uint32_t ll = al * bl, lh = al * bh, hl = ah * bl, hh = ah * bh;

    /* The middle sum can reach 33 bits; its carry is worth 2^48. */
    uint32_t mid = lh + hl;
    uint32_t mid_carry = mid < lh;

    uint32_t lo = ll + (mid << 16);
    uint32_t hi = hh + (mid >> 16) + (mid_carry << 16) + (lo < ll);

    if (a < 0)
        hi -= ub;
    if (b < 0)
        hi -= ua;

    /* Half a unit, then a floor shift: ties round toward plus infinity. Only
     * bits 20 to 51 of the sum survive, so the kind of right shift does not
     * matter.
     */
    const uint32_t half = 1u << (Q - 1);
    hi += lo > UINT32_MAX - half; /* carry out of the low word */
    lo += half;
    return (int32_t) ((lo >> Q) | (hi << (32 - Q)));
}
