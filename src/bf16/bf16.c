#include "bf16.h"

#define BF16_SIGN 0x8000u
#define BF16_EXP_MASK 0x7F80u
#define BF16_FRAC_MASK 0x007Fu
#define BF16_HIDDEN 0x0080u
#define BF16_EXP_BIAS 127
#define BF16_QNAN 0x7FC0u

/* Narrow binary32 to bfloat16: round to nearest, ties to even. Adding 0x7FFF
 * carries into bit 16 when the discarded half is above 0x8000; adding the
 * lowest kept bit as well makes an exact tie (0x8000) carry only when that bit
 * is one, which is the round-to-even rule.
 */
uint16_t bf16_from_f32(uint32_t f32bits)
{
    if (((f32bits >> 23) & 0xFFu) == 0xFFu)
        return (uint16_t) (f32bits >> 16);
    f32bits += 0x7FFFu + ((f32bits >> 16) & 1u);
    return (uint16_t) (f32bits >> 16);
}

/* Shift-and-add product of two 8-bit significands; at most 8 passes. */
static uint32_t mul_sig(uint32_t a, uint32_t b)
{
    uint32_t r = 0;
    while (b) {
        if (b & 1u)
            r += a;
        a <<= 1;
        b >>= 1;
    }
    return r;
}

uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    uint32_t sign = (a ^ b) & BF16_SIGN;
    int exp_a = (a >> 7) & 0xFF, exp_b = (b >> 7) & 0xFF;
    uint32_t mant_a = a & BF16_FRAC_MASK, mant_b = b & BF16_FRAC_MASK;

    /* Inf and NaN: a is examined first, then b. */
    if (exp_a == 0xFF) {
        if (mant_a)
            return a;
        if (!exp_b && !mant_b)
            return BF16_QNAN;
        return (uint16_t) (sign | BF16_EXP_MASK);
    }
    if (exp_b == 0xFF) {
        if (mant_b)
            return b;
        if (!exp_a && !mant_a)
            return BF16_QNAN;
        return (uint16_t) (sign | BF16_EXP_MASK);
    }
    if ((!exp_a && !mant_a) || (!exp_b && !mant_b))
        return (uint16_t) sign;

    /* Bring both significands to 1.xxxxxxx form (bit 7 set). A denormal has
     * exponent 1 - bias and no hidden one, so it is shifted up and the shift
     * count is taken off the exponent.
     */
    int exp_adjust = 0;
    if (!exp_a) {
        while (!(mant_a & BF16_HIDDEN)) {
            mant_a <<= 1;
            exp_adjust--;
        }
        exp_a = 1;
    } else {
        mant_a |= BF16_HIDDEN;
    }
    if (!exp_b) {
        while (!(mant_b & BF16_HIDDEN)) {
            mant_b <<= 1;
            exp_adjust--;
        }
        exp_b = 1;
    } else {
        mant_b |= BF16_HIDDEN;
    }

    /* [128, 256) times [128, 256) lies in [2^14, 2^16): the product has its
     * leading one at bit 14 or at bit 15. The fraction is truncated.
     */
    uint32_t prod = mul_sig(mant_a, mant_b);
    int exp = exp_a + exp_b - BF16_EXP_BIAS + exp_adjust;
    uint32_t frac;
    if (prod & 0x8000u) {
        frac = (prod >> 8) & BF16_FRAC_MASK;
        exp++;
    } else {
        frac = (prod >> 7) & BF16_FRAC_MASK;
    }

    if (exp >= 0xFF)
        return (uint16_t) (sign | BF16_EXP_MASK);
    if (exp <= 0) {
        if (exp < -6)
            return (uint16_t) sign;
        /* The contract shifts the fraction, without the hidden one. */
        frac >>= 1 - exp;
        exp = 0;
    }
    return (uint16_t) (sign | ((uint32_t) exp << 7) | frac);
}

uint16_t bf16_sqrt(uint16_t a)
{
    uint32_t exp = (a >> 7) & 0xFFu;
    uint32_t mant = a & BF16_FRAC_MASK;

    if (exp == 0xFFu) {
        if (mant)
            return a; /* NaN */
        return (a & BF16_SIGN) ? BF16_QNAN : a;
    }
    if (!exp && !mant)
        return 0; /* +0 and -0 */
    if (a & BF16_SIGN)
        return BF16_QNAN;
    if (!exp)
        return 0; /* denormals flush to zero */

    /* value = 2^e * m / 128 with m in [128, 256) and e = exp - 127. An odd e
     * is made even by doubling m; exp is even exactly when e is odd. The new
     * biased exponent is floor(e / 2) + 127 = (exp + 127) >> 1 in both cases.
     */
    uint32_t m = BF16_HIDDEN | mant;
    if (!(exp & 1u))
        m <<= 1;
    uint32_t new_exp = (exp + BF16_EXP_BIAS) >> 1;

    /* The contract asks for the largest mid with (mid * mid) / 128 <= m, the
     * division truncating. That is mid * mid < 128 * (m + 1), so mid is the
     * integer square root of n = 128 * (m + 1) - 1. With m in [128, 512), n
     * lies in [16511, 65535] and mid in [128, 255]: the search window
     * [90, 256] never binds and the result needs no renormalization.
     *
     * Digit-by-digit square root: r holds the root found so far, scaled so
     * that r + bit is the amount the trial bit would add to the square.
     */
    uint32_t n = (m << 7) + 127u, r = 0;
    for (uint32_t bit = 1u << 14; bit; bit >>= 2) {
        uint32_t trial = r + bit;
        r >>= 1;
        if (n >= trial) {
            n -= trial;
            r += bit;
        }
    }

    return (uint16_t) ((new_exp << 7) | (r & BF16_FRAC_MASK));
}
