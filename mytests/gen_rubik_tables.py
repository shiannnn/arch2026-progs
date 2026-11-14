#!/usr/bin/env python3
"""Generate the tables of the rubik solver.

Writes src/rubik/tables.h (for rubik.c) and src/rubik/tables.S (for rubik.S).
The two implementations are linked separately, so each needs its own copy.

The cube model is the one of sysprog21/minirubik solver.c: seven movable
cubies, three faces R, B, D, and for a quarter turn of face f

    new.p[i] = old.p[source[f][i]]
    new.o[i] = (old.o[source[f][i]] + twist[f][i]) % 3

Coordinates:
    p   rank of the permutation, 0..5039 (Lehmer code, identity = 0)
    o   rank of the first six orientations in base 3, 0..728 (the seventh
        follows from the sum being a multiple of 3)

Tables:
    pnext[f][p]   p after one quarter turn of face f
    onext[f][o]   o after one quarter turn of face f
    near          every state within NEAR moves of the solved cube, grouped by
                  p; one 16-bit entry per state holds o and the move that
                  brings the state one step closer to solved
    start[p]      where the group of p begins in near; start[p + 1] ends it

Run from the repository root:  python3 mytests/gen_rubik_tables.py
"""

import sys
from collections import deque

CUBIES = 7
PERMS = 5040
ORIENTS = 729
NEAR = 5
NO_MOVE = 9

SOURCE = ((1, 4, 2, 0, 3, 5, 6), (0, 1, 2, 4, 5, 6, 3), (0, 2, 5, 3, 1, 4, 6))
TWIST = ((1, 2, 0, 2, 1, 0, 0), (0, 0, 0, 1, 2, 1, 2), (0, 0, 0, 0, 0, 0, 0))


def quarter(state, f):
    p, o = state
    src, tw = SOURCE[f], TWIST[f]
    return (
        tuple(p[src[i]] for i in range(CUBIES)),
        tuple((o[src[i]] + tw[i]) % 3 for i in range(CUBIES)),
    )


def rank_perm(p):
    r = 0
    for i in range(CUBIES):
        smaller = sum(1 for j in range(i + 1, CUBIES) if p[j] < p[i])
        r = r * (CUBIES - i) + smaller
    return r


def unrank_perm(r):
    digits = []
    for base in range(1, CUBIES + 1):
        digits.append(r % base)
        r //= base
    digits.reverse()
    avail = list(range(CUBIES))
    return tuple(avail.pop(d) for d in digits)


def rank_orient(o):
    r = 0
    for i in range(6):
        r = r * 3 + o[i]
    return r


def unrank_orient(r):
    o = []
    for _ in range(6):
        o.append(r % 3)
        r //= 3
    o.reverse()
    o.append((3 - sum(o) % 3) % 3)
    return tuple(o)


def build():
    identity = tuple(range(CUBIES))
    zero = (0,) * CUBIES

    pnext = [[0] * PERMS for _ in range(3)]
    for r in range(PERMS):
        p = unrank_perm(r)
        assert rank_perm(p) == r
        for f in range(3):
            pnext[f][r] = rank_perm(quarter((p, zero), f)[0])

    onext = [[0] * ORIENTS for _ in range(3)]
    for r in range(ORIENTS):
        o = unrank_orient(r)
        assert rank_orient(o) == r
        for f in range(3):
            onext[f][r] = rank_orient(quarter((identity, o), f)[1])

    # Breadth-first search from the solved cube. A state reached from s by the
    # move (f, t) is brought back toward solved by the inverse move (f, 2 - t).
    solved = (identity, zero)
    toward = {solved: NO_MOVE}
    dist = {solved: 0}
    queue = deque([solved])
    while queue:
        s = queue.popleft()
        if dist[s] == NEAR:
            continue
        for f in range(3):
            n = s
            for t in range(3):
                n = quarter(n, f)
                if n not in dist:
                    dist[n] = dist[s] + 1
                    toward[n] = 3 * f + (2 - t)
                    queue.append(n)

    groups = [[] for _ in range(PERMS)]
    for (p, o), move in toward.items():
        groups[rank_perm(p)].append((rank_orient(o), move))
    start, near = [], []
    for g in groups:
        start.append(len(near))
        near.extend(sorted(g))
    start.append(len(near))
    return pnext, onext, start, near, dist


def c_array(name, ctype, values, per_line=12):
    lines = [f"static const {ctype} {name}[] = {{"]
    for i in range(0, len(values), per_line):
        lines.append("    " + ", ".join(str(v) for v in values[i : i + per_line]) + ",")
    lines.append("};")
    return "\n".join(lines)


def s_array(name, values, per_line=12):
    lines = [f"    .globl  {name}", f"    .type   {name}, @object", f"{name}:"]
    for i in range(0, len(values), per_line):
        lines.append("    .half   " + ", ".join(str(v) for v in values[i : i + per_line]))
    lines.append(f"    .size   {name}, .-{name}")
    return "\n".join(lines)


def main():
    pnext, onext, start, near, dist = build()
    hist = [0] * (NEAR + 1)
    for d in dist.values():
        hist[d] += 1
    used = sum(1 for i in range(PERMS) if start[i] != start[i + 1])
    longest = max(start[i + 1] - start[i] for i in range(PERMS))
    print(f"states within {NEAR} moves: {len(near)} {hist}", file=sys.stderr)
    print(f"permutations with a group: {used} of {PERMS}, longest group {longest}", file=sys.stderr)

    # C: plain indices. An entry is o in bits 0-9 and the move in bits 10-13.
    c_near = [o | (m << 10) for o, m in near]
    with open("src/rubik/tables.h", "w") as f:
        f.write("/* Generated by mytests/gen_rubik_tables.py. Do not edit. */\n")
        f.write("#pragma once\n\n#include <stdint.h>\n\n")
        f.write("/* Permutation rank after one quarter turn: pnext[face * 5040 + p]. */\n")
        f.write(c_array("pnext", "uint16_t", [v for row in pnext for v in row]) + "\n\n")
        f.write("/* Orientation rank after one quarter turn: onext[face * 729 + o]. */\n")
        f.write(c_array("onext", "uint16_t", [v for row in onext for v in row]) + "\n\n")
        f.write("/* near[near_start[p]] to near[near_start[p + 1] - 1]: the states within\n")
        f.write(" * five moves of solved that have permutation rank p.\n */\n")
        f.write(c_array("near_start", "uint16_t", start) + "\n\n")
        f.write("/* Orientation rank in bits 0-9, move toward solved in bits 10-13. */\n")
        f.write(c_array("near", "uint16_t", c_near) + "\n")

    # Assembly: every coordinate is stored doubled, so that it is the byte
    # offset of a halfword and no shift is needed to index a table.
    #
    # An entry of near is (2 * o) << 4 | move. The entries of one permutation
    # are sorted by o and followed by the sentinel 0xFFFF, which is larger
    # than any entry, so a scan needs no end pointer: it skips entries below
    # (2 * o) << 4 and then tests whether the one it stopped at is within 16
    # of that key. start[p] is the byte offset of the first entry; a
    # permutation without states points at a lone sentinel at offset 0.
    sentinel = 0xFFFF
    s_pnext = [2 * v for row in pnext for v in row]
    s_onext = [2 * v for row in onext for v in row]
    s_near, s_start = [sentinel], []
    for i in range(PERMS):
        group = near[start[i] : start[i + 1]]
        if not group:
            s_start.append(0)
            continue
        s_start.append(2 * len(s_near))
        s_near.extend((2 * o) << 4 | m for o, m in group)
        s_near.append(sentinel)
    assert max(s_start) < 0x10000
    assert max(v for v in s_near if v != sentinel) < sentinel - 16
    with open("src/rubik/tables.S", "w") as f:
        f.write("# Generated by mytests/gen_rubik_tables.py. Do not edit.\n#\n")
        f.write("# Tables of rubik_solve_asm; see the header comment of rubik.S for the\n")
        f.write("# encoding. Coordinates are stored doubled (byte offsets of halfwords).\n\n")
        f.write("    .section .rodata\n    .align  2\n\n")
        f.write("# Three rows of 5040 halfwords: 2 * p after a quarter turn of R, B, D.\n")
        f.write(s_array("rubik_pnext", s_pnext) + "\n\n")
        f.write("# Three rows of 729 halfwords: 2 * o after a quarter turn of R, B, D.\n")
        f.write(s_array("rubik_onext", s_onext) + "\n\n")
        f.write("# Byte offset into rubik_near of the states with permutation rank p.\n")
        f.write(s_array("rubik_start", s_start) + "\n\n")
        f.write("# States within five moves: (2 * o) << 4 | move, 0xFFFF ends a group.\n")
        f.write(s_array("rubik_near", s_near) + "\n")


if __name__ == "__main__":
    main()
