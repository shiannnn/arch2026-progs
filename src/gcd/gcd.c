#include "gcd.h"

/* Binary GCD (Stein's algorithm). It rests on three identities:
 *   gcd(2u, 2v) = 2 * gcd(u, v)
 *   gcd(2u, v)  = gcd(u, v)          when v is odd
 *   gcd(u, v)   = gcd(|u - v|, v)    when both are odd
 * so shifts and subtractions suffice, with no divider. The difference of two
 * odd numbers is even, hence every pass removes at least one bit and the loop
 * runs at most about 64 times for 32-bit operands.
 */
uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    if (!a)
        return b;
    if (!b)
        return a;

    /* Strip the factors of two both operands share; they are restored once at
     * the end.
     */
    unsigned shift = 0;
    while (!((a | b) & 1u)) {
        a >>= 1;
        b >>= 1;
        shift++;
    }

    /* The remaining factors of two of a are not common: drop them. */
    while (!(a & 1u))
        a >>= 1;

    /* Invariant: a is odd. */
    do {
        while (!(b & 1u))
            b >>= 1;
        if (a > b) {
            uint32_t t = a;
            a = b;
            b = t;
        }
        b -= a;
    } while (b);

    return a << shift;
}
