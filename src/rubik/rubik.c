#include "rubik.h"
#include "tables.h"

/* Optimal solver for the 2x2x2 cube: a forward search that ends in a table.
 *
 * A state is the pair (p, o): p is the rank of the permutation of the seven
 * movable cubies, o the rank of their orientations. One quarter turn of a face
 * maps p and o independently, through pnext and onext, so a node of the search
 * costs two table loads and never rebuilds the cube.
 *
 * The table `near` holds all 12,224 states within NEAR = 5 moves of the solved
 * cube, each with the move that brings it one step closer. A state at distance
 * d > 5 has a shortest solution whose first d - 5 moves end in such a state,
 * and no shorter sequence does. The solver therefore tries every sequence of
 * 1, 2, ... moves until one ends in the table (at most 6, since no state is
 * further than 11), and reads the rest of the solution from the table.
 */

enum {
    CUBIES = 7,
    PERMS = 5040,
    ORIENTS = 729,
    FACES = 3,
    MAX_MOVES = 11,
    NO_MOVE = 9,   /* the entry of the solved cube */
    NOT_NEAR = -1, /* the state is more than five moves from solved */
};

struct search {
    uint8_t path[MAX_MOVES + 1]; /* move = 3 * face + (quarter turns - 1) */
    uint32_t p, o;               /* where the searched part of the path ends */
};

/* The move toward solved of state (p, o), or NOT_NEAR. The states of one
 * permutation rank are stored together; most ranks have none.
 */
static int near_move(uint32_t p, uint32_t o)
{
    for (uint32_t i = near_start[p]; i < near_start[p + 1]; i++) {
        if ((near[i] & 0x3FFu) == o)
            return near[i] >> 10;
    }
    return NOT_NEAR;
}

/* Try every sequence of `left` more moves from (p, o) that does not turn the
 * face `last` again. Returns 1 as soon as one ends within five moves of
 * solved; the moves are then in s->path and the end state in s->p, s->o.
 *
 * The three turns of one face are successive quarter turns, so each child
 * costs one step through the tables.
 */
static int descend(struct search *s,
                   uint32_t p,
                   uint32_t o,
                   int depth,
                   int left,
                   int last)
{
    const uint16_t *prow = pnext, *orow = onext;
    for (int f = 0; f < FACES; f++, prow += PERMS, orow += ORIENTS) {
        if (f == last)
            continue;
        uint32_t np = p, no = o;
        for (int t = 0; t < 3; t++) {
            np = prow[np];
            no = orow[no];
            s->path[depth] = (uint8_t) (f + f + f + t);
            if (left == 1) {
                if (near_move(np, no) != NOT_NEAR) {
                    s->p = np;
                    s->o = no;
                    return 1;
                }
            } else if (descend(s, np, no, depth + 1, left - 1, f)) {
                return 1;
            }
        }
    }
    return 0;
}

int rubik_solve(const char *state, char *out, size_t cap)
{
    uint8_t perm[CUBIES], twist[CUBIES];

    /* Validate while reading: a NUL inside the 14 characters fails the range
     * check, so nothing past the end of a short string is read.
     */
    uint32_t seen = 0, sum = 0;
    for (int i = 0; i < CUBIES; i++) {
        uint32_t v = (uint32_t) (unsigned char) state[i] - '1';
        if (v >= CUBIES || (seen & (1u << v)))
            return -1;
        seen |= 1u << v;
        perm[i] = (uint8_t) v;
    }
    for (int i = 0; i < CUBIES; i++) {
        uint32_t v = (uint32_t) (unsigned char) state[CUBIES + i] - '1';
        if (v > 2)
            return -1;
        twist[i] = (uint8_t) v;
        sum += v;
    }
    if (state[RUBIK_STATE_LEN] != '\0')
        return -1;
    while (sum >= 3)
        sum -= 3;
    if (sum != 0)
        return -1;

    /* Rank the permutation by its Lehmer code and the first six orientations
     * as a base-3 number; the seventh orientation follows from the sum.
     */
    uint32_t p = 0, o = 0;
    for (int i = 0; i < CUBIES; i++) {
        uint32_t smaller = 0;
        for (int j = i + 1; j < CUBIES; j++)
            smaller += perm[j] < perm[i];
        p = p * (uint32_t) (CUBIES - i) + smaller;
    }
    for (int i = 0; i < CUBIES - 1; i++)
        o = o + o + o + twist[i];

    /* Search: no moves when the state is already in the table, otherwise the
     * shortest sequence that leads into it.
     */
    struct search s;
    s.p = p;
    s.o = o;
    int n = 0;
    if (near_move(p, o) == NOT_NEAR) {
        n = 1;
        while (!descend(&s, p, o, 0, n, FACES)) {
            if (++n > MAX_MOVES - 5)
                return -1; /* unreachable: every state is within 11 moves */
        }
    }

    /* The table gives the remaining moves, one state at a time. */
    p = s.p;
    o = s.o;
    for (;;) {
        int m = near_move(p, o);
        if (m == NO_MOVE || n == MAX_MOVES)
            break;
        s.path[n++] = (uint8_t) m;
        int f = m >= 6 ? 2 : m >= 3 ? 1 : 0;
        const uint16_t *prow = pnext + (f == 2   ? 2 * PERMS
                                        : f == 1 ? PERMS
                                                 : 0);
        const uint16_t *orow = onext + (f == 2   ? 2 * ORIENTS
                                        : f == 1 ? ORIENTS
                                                 : 0);
        for (int t = m - (f + f + f); t >= 0; t--) {
            p = prow[p];
            o = orow[o];
        }
    }

    /* Text: a face letter, an optional suffix, single spaces between moves. */
    size_t len = n ? (size_t) n - 1 : 0;
    for (int i = 0; i < n; i++) {
        int m = s.path[i];
        int t = m >= 6 ? m - 6 : m >= 3 ? m - 3 : m;
        len += t ? 2 : 1;
    }
    if (len + 1 > cap) {
        if (cap)
            out[0] = '\0';
        return -2;
    }
    char *w = out;
    for (int i = 0; i < n; i++) {
        int m = s.path[i];
        int f = m >= 6 ? 2 : m >= 3 ? 1 : 0;
        int t = m - (f + f + f);
        if (i)
            *w++ = ' ';
        *w++ = "RBD"[f];
        if (t)
            *w++ = t == 1 ? '2' : '\'';
    }
    *w = '\0';
    return n;
}
