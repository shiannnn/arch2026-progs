# rubik_solve_asm: optimal 2x2x2 cube solver, hand-written RV32I.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#                                   a0 = state, a1 = out, a2 = cap; result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions, no heap, no recursion. Tests: tests/trubik.c.
#
# Algorithm. A state is the pair (P, O): the rank of the permutation and the
# rank of the orientations, each stored doubled so that it is the byte offset
# of a halfword. A quarter turn of a face maps P through rubik_pnext and O
# through rubik_onext; the three turns of a face are one, two and three such
# steps. rubik_near holds the 12,224 states within five moves of the solved
# cube, each with the move that brings it one step closer. The solver tries
# every sequence of k = 1, 2, ... moves until one ends in that table (k is at
# most 6), then reads the remaining moves from the table.
#
# A sequence of k moves is enumerated in three parts:
#   upper levels   the first k - 2 moves, an explicit stack of frames in
#                  memory; at most 4 levels and 2,331 nodes, so not time
#                  critical;
#   .Lbottom2      move k - 1, a loop over two faces and three turns;
#   .Lleaf         move k, the same loop with a table probe after every turn.
# The last two run in registers only and take almost all of the time.
#
# Table probe (macro PROBE). The states of one permutation are stored
# together, sorted by orientation and ended by 0xFFFF. An entry is
# (O << 4) | move, so the scan skips entries below O << 4 and stops at the
# first one that is not; that entry is a hit when it is less than 16 above.
#
# Registers that hold constants during the search:
#   s0  rubik_pnext           s1  rubik_onext
#   s2  rubik_start           s3  rubik_near
#   s4  10080, bytes in a row of rubik_pnext
#   s5  1458, bytes in a row of rubik_onext
#   s6  9, the number of moves; as a move index it means "none"
#   s9  16, the width of the move field of an entry
# Other registers with a fixed role:
#   s7, s8   row pointers of the face turned by .Lbottom2
#   s10      return address of .Lleaf
#   s11      where .Lbottom2 stores the last two moves of the path
#   t1, t2   P and O of the state under test; the end state after a hit
#   t3, t4   row pointers of the face turned by .Lleaf, or by the caller
# Moves are numbered 3 * face + (quarter turns - 1), faces R = 0, B = 1, D = 2.

    .equ    PATH, 0                 # 12 bytes: the moves of the solution
    .equ    PERM, 16                # 7 bytes: cubie digits minus one
    .equ    TWIST, 24               # 7 bytes: orientation digits minus one
    .equ    ROOT_P, 32
    .equ    ROOT_O, 36
    .equ    OUT, 40
    .equ    CAP, 44
    .equ    DEPTH, 48               # k, the number of searched moves
    .equ    CUR_FRAME, 52           # frame pointer across a call
    .equ    LAST_FRAME, 56          # address of the deepest upper frame
    .equ    FRAMES, 64              # 4 frames of FRAME_SIZE bytes
    .equ    FRAME_SIZE, 32
    .equ    SAVED, 192              # ra, s0-s11
    .equ    STACK, 256

    # Fields of an upper-level frame.
    .equ    F_NODE_P, 0             # state the frame starts from
    .equ    F_NODE_O, 4
    .equ    F_CUR_P, 8              # state after the last move tried
    .equ    F_CUR_O, 12
    .equ    F_MOVE, 16              # next move to try, 9 when exhausted
    .equ    F_SKIP, 20              # first move of the face not to turn
    .equ    F_PATH, 24              # where this level stores its move

    .equ    P_ROW, 10080
    .equ    O_ROW, 1458

    # One quarter turn of the face whose rows are t3 and t4.
    .macro  STEP
    add     t0, t3, t1
    lhu     t1, 0(t0)
    add     t0, t4, t2
    lhu     t2, 0(t0)
    .endm

    # Look up (t1, t2). Leaves a1 = entry - key: below 16 on a hit, and then
    # it is the move toward solved. Uses t0 and a2.
    .macro  PROBE
    add     t0, s2, t1
    lhu     t0, 0(t0)               # offset of the group of this permutation
    slli    a2, t2, 4               # key
    add     t0, s3, t0
1:
    lhu     a1, 0(t0)
    addi    t0, t0, 2
    bltu    a1, a2, 1b              # the sentinel ends the scan
    sub     a1, a1, a2
    .endm

    .section .rodata
.Lface_letter:
    .ascii  "RBD"

    .text

    .globl  rubik_solve_asm
    .type   rubik_solve_asm, @function
    .align  2
rubik_solve_asm:
    addi    sp, sp, -STACK
    sw      a1, OUT(sp)
    sw      a2, CAP(sp)

    # ---- Parse and validate; only caller-saved registers are in use. ----
    # A NUL inside the 14 characters fails the range check, so nothing past
    # the end of a short string is read.
    li      t0, 0                   # index
    li      t1, 0                   # set of cubies seen
    li      a5, 7
.Lparse_perm:
    add     t2, a0, t0
    lbu     t3, 0(t2)
    addi    t3, t3, -49             # minus '1'
    bgeu    t3, a5, .Linvalid       # not '1'..'7'
    li      t4, 1
    sll     t4, t4, t3
    and     t5, t1, t4
    bnez    t5, .Linvalid           # repeated cubie
    or      t1, t1, t4
    add     t2, sp, t0
    sb      t3, PERM(t2)
    addi    t0, t0, 1
    bne     t0, a5, .Lparse_perm

    li      t0, 0
    li      t1, 0                   # orientation sum
    li      a6, 3
.Lparse_twist:
    add     t2, a0, t0
    lbu     t3, 7(t2)
    addi    t3, t3, -49             # minus '1'
    bgeu    t3, a6, .Linvalid       # not '1'..'3'
    add     t1, t1, t3
    add     t2, sp, t0
    sb      t3, TWIST(t2)
    addi    t0, t0, 1
    bne     t0, a5, .Lparse_twist

    lbu     t3, 14(a0)
    bnez    t3, .Linvalid           # longer than 14 characters
.Lsum_mod3:                         # the sum is at most 14
    bltu    t1, a6, .Lsum_done
    addi    t1, t1, -3
    j       .Lsum_mod3
.Lsum_done:
    bnez    t1, .Linvalid

    # ---- Rank the permutation: Lehmer code, r = r * (7 - i) + smaller. ----
    li      a3, 0                   # r
    li      t0, 0                   # i
    li      a6, 6
.Lrank_outer:
    add     t2, sp, t0
    lbu     t3, PERM(t2)
    li      t4, 0                   # cubies after i that are smaller
    addi    t5, t0, 1
.Lrank_inner:
    add     t2, sp, t5
    lbu     t6, PERM(t2)
    sltu    t6, t6, t3
    add     t4, t4, t6
    addi    t5, t5, 1
    bne     t5, a5, .Lrank_inner
    sub     t5, a5, t0              # 7 - i, at least 2
    li      t6, 0
.Lrank_scale:                       # r * (7 - i) by repeated addition
    add     t6, t6, a3
    addi    t5, t5, -1
    bnez    t5, .Lrank_scale
    add     a3, t6, t4
    addi    t0, t0, 1
    bne     t0, a6, .Lrank_outer    # the last cubie adds nothing
    slli    a3, a3, 1               # P

    # ---- Rank the first six orientations in base 3. ----
    li      a4, 0
    li      t0, 0
.Lrank_twist:
    add     t2, sp, t0
    lbu     t3, TWIST(t2)
    slli    t4, a4, 1
    add     a4, a4, t4
    add     a4, a4, t3
    addi    t0, t0, 1
    bne     t0, a6, .Lrank_twist
    slli    a4, a4, 1               # O

    # ---- The state is valid: save registers and load the constants. ----
    sw      ra, SAVED(sp)
    sw      s0, SAVED+4(sp)
    sw      s1, SAVED+8(sp)
    sw      s2, SAVED+12(sp)
    sw      s3, SAVED+16(sp)
    sw      s4, SAVED+20(sp)
    sw      s5, SAVED+24(sp)
    sw      s6, SAVED+28(sp)
    sw      s7, SAVED+32(sp)
    sw      s8, SAVED+36(sp)
    sw      s9, SAVED+40(sp)
    sw      s10, SAVED+44(sp)
    sw      s11, SAVED+48(sp)
    la      s0, rubik_pnext
    la      s1, rubik_onext
    la      s2, rubik_start
    la      s3, rubik_near
    li      s4, P_ROW
    li      s5, O_ROW
    li      s6, 9
    li      s9, 16
    sw      a3, ROOT_P(sp)
    sw      a4, ROOT_O(sp)

    # ---- k = 0: the state itself is within five moves. ----
    mv      t1, a3
    mv      t2, a4
    li      a3, 0                   # moves found so far
    PROBE
    bltu    a1, s9, .Lfollow

    # ---- k = 1: one move, straight into the leaf level. ----
    lw      a6, ROOT_P(sp)
    lw      a7, ROOT_O(sp)
    mv      t6, s6                  # no face is excluded
    jal     s10, .Lleaf
    bltz    a0, .Ldepth2
    sb      a0, PATH(sp)
    li      a3, 1
    j       .Lfollow

    # ---- k = 2: the two register levels. ----
.Ldepth2:
    lw      a3, ROOT_P(sp)
    lw      a4, ROOT_O(sp)
    mv      a5, s6
    addi    s11, sp, PATH
    jal     ra, .Lbottom2
    li      a3, 2
    bgez    a0, .Lfollow

    # ---- k = 3 to 6: k - 2 upper levels above the register levels. ----
    li      t0, 3
    addi    t1, sp, FRAMES          # deepest frame for k = 3
.Ldeepen:
    sw      t0, DEPTH(sp)
    sw      t1, LAST_FRAME(sp)
    add     s11, sp, t0
    addi    s11, s11, PATH-2        # path[k - 2]

    addi    a2, sp, FRAMES          # frame of level 0
    lw      t5, ROOT_P(sp)
    lw      t6, ROOT_O(sp)
    sw      t5, F_NODE_P(a2)
    sw      t6, F_NODE_O(a2)
    sw      zero, F_MOVE(a2)
    sw      s6, F_SKIP(a2)
    addi    t2, sp, PATH
    sw      t2, F_PATH(a2)

.Lupper:                            # a2 = current frame
    lw      t0, F_MOVE(a2)
    beq     t0, s6, .Lupper_pop     # all nine moves tried

    # Rows and first move of the face that move t0 turns.
    mv      t3, s0
    mv      t4, s1
    li      t1, 0
    slti    t2, t0, 3
    bnez    t2, .Lupper_face
    add     t3, t3, s4
    add     t4, t4, s5
    li      t1, 3
    slti    t2, t0, 6
    bnez    t2, .Lupper_face
    add     t3, t3, s4
    add     t4, t4, s5
    li      t1, 6
.Lupper_face:
    bne     t0, t1, .Lupper_turn    # second or third turn: continue from cur
    lw      t2, F_SKIP(a2)
    bne     t1, t2, .Lupper_first
    addi    t0, t0, 3               # do not turn the same face twice
    sw      t0, F_MOVE(a2)
    j       .Lupper
.Lupper_first:                      # first turn of a face: start from node
    lw      t5, F_NODE_P(a2)
    lw      t6, F_NODE_O(a2)
    sw      t5, F_CUR_P(a2)
    sw      t6, F_CUR_O(a2)
.Lupper_turn:
    lw      t5, F_CUR_P(a2)
    lw      t6, F_CUR_O(a2)
    add     t2, t3, t5
    lhu     t5, 0(t2)
    add     t2, t4, t6
    lhu     t6, 0(t2)
    sw      t5, F_CUR_P(a2)
    sw      t6, F_CUR_O(a2)
    lw      t2, F_PATH(a2)
    sb      t0, 0(t2)               # this level's move
    addi    t0, t0, 1
    sw      t0, F_MOVE(a2)

    lw      t0, LAST_FRAME(sp)
    beq     a2, t0, .Lupper_bottom
    addi    a2, a2, FRAME_SIZE      # push a frame for the new state
    sw      t5, F_NODE_P(a2)
    sw      t6, F_NODE_O(a2)
    sw      zero, F_MOVE(a2)
    sw      t1, F_SKIP(a2)
    addi    t2, t2, 1
    sw      t2, F_PATH(a2)
    j       .Lupper

.Lupper_bottom:                     # the last two moves, in registers
    sw      a2, CUR_FRAME(sp)
    mv      a3, t5
    mv      a4, t6
    mv      a5, t1
    jal     ra, .Lbottom2
    lw      a2, CUR_FRAME(sp)
    bltz    a0, .Lupper
    lw      a3, DEPTH(sp)           # found: k moves so far
    j       .Lfollow

.Lupper_pop:
    addi    t0, sp, FRAMES
    beq     a2, t0, .Lupper_failed
    addi    a2, a2, -FRAME_SIZE
    j       .Lupper

.Lupper_failed:                     # no sequence of k moves: try k + 1
    lw      t0, DEPTH(sp)
    lw      t1, LAST_FRAME(sp)
    addi    t0, t0, 1
    addi    t1, t1, FRAME_SIZE
    li      t2, 7
    bne     t0, t2, .Ldeepen
    li      a0, -1                  # unreachable: every state is within 11
    j       .Lrestore

    # ---- Read the rest of the solution from the table. ----
    # t1, t2 = a state within five moves, a3 = moves in the path so far.
.Lfollow:
    PROBE                           # a1 = move toward solved
    beq     a1, s6, .Lemit          # solved
    add     t0, sp, a3
    sb      a1, PATH(t0)
    addi    a3, a3, 1
    mv      t3, s0                  # rows of the face of move a1
    mv      t4, s1
    slti    t0, a1, 3
    bnez    t0, .Lfollow_turn
    add     t3, t3, s4
    add     t4, t4, s5
    addi    a1, a1, -3
    slti    t0, a1, 3
    bnez    t0, .Lfollow_turn
    add     t3, t3, s4
    add     t4, t4, s5
    addi    a1, a1, -3
.Lfollow_turn:                      # a1 + 1 quarter turns
    STEP
    addi    a1, a1, -1
    bgez    a1, .Lfollow_turn
    j       .Lfollow

    # ---- Write the text: a3 = number of moves. ----
.Lemit:
    lw      a1, OUT(sp)
    lw      a2, CAP(sp)
    # Length: one letter per move, a suffix for half and inverse turns, and
    # a space between moves.
    mv      t0, a3
    beqz    a3, .Llength_done
    addi    t0, t0, -1              # spaces
    li      t1, 0
.Llength:
    add     t2, sp, t1
    lbu     t3, PATH(t2)
    addi    t0, t0, 1               # the face letter
    beqz    t3, .Llength_next       # R
    li      t4, 3
    beq     t3, t4, .Llength_next   # B
    li      t4, 6
    beq     t3, t4, .Llength_next   # D
    addi    t0, t0, 1               # '2' or the apostrophe
.Llength_next:
    addi    t1, t1, 1
    bne     t1, a3, .Llength
.Llength_done:
    bgeu    t0, a2, .Ltoo_small     # the text and its NUL need t0 + 1 bytes

    la      a4, .Lface_letter
    li      t1, 0
    beqz    a3, .Lterminate
.Lwrite:
    beqz    t1, .Lwrite_move
    li      t4, 32                  # space
    sb      t4, 0(a1)
    addi    a1, a1, 1
.Lwrite_move:
    add     t2, sp, t1
    lbu     t3, PATH(t2)
    mv      t5, a4                  # letter of the face; t3 becomes the turn
    slti    t4, t3, 3
    bnez    t4, .Lwrite_letter
    addi    t5, t5, 1
    addi    t3, t3, -3
    slti    t4, t3, 3
    bnez    t4, .Lwrite_letter
    addi    t5, t5, 1
    addi    t3, t3, -3
.Lwrite_letter:
    lbu     t4, 0(t5)
    sb      t4, 0(a1)
    addi    a1, a1, 1
    beqz    t3, .Lwrite_next        # quarter turn: no suffix
    li      t4, 50                  # '2'
    addi    t3, t3, -1
    beqz    t3, .Lwrite_suffix
    li      t4, 39                  # apostrophe
.Lwrite_suffix:
    sb      t4, 0(a1)
    addi    a1, a1, 1
.Lwrite_next:
    addi    t1, t1, 1
    bne     t1, a3, .Lwrite
.Lterminate:
    sb      zero, 0(a1)
    mv      a0, a3

.Lrestore:
    lw      ra, SAVED(sp)
    lw      s0, SAVED+4(sp)
    lw      s1, SAVED+8(sp)
    lw      s2, SAVED+12(sp)
    lw      s3, SAVED+16(sp)
    lw      s4, SAVED+20(sp)
    lw      s5, SAVED+24(sp)
    lw      s6, SAVED+28(sp)
    lw      s7, SAVED+32(sp)
    lw      s8, SAVED+36(sp)
    lw      s9, SAVED+40(sp)
    lw      s10, SAVED+44(sp)
    lw      s11, SAVED+48(sp)
    addi    sp, sp, STACK
    ret

.Ltoo_small:
    li      a0, -2
    beqz    a2, .Lrestore           # no room even for the NUL
    sb      zero, 0(a1)
    j       .Lrestore

.Linvalid:                          # nothing saved yet, out untouched
    li      a0, -1
    addi    sp, sp, STACK
    ret

    # ---- Move k - 1: every turn of the two faces other than a5 / 3. ----
    # In:  a3, a4 = state, a5 = first move of the excluded face (9 = none),
    #      s11 = where to store moves k - 1 and k. Return address in ra.
    # Out: a0 = -1, or the last move after a hit, with the end state in t1, t2.
    # Uses a6, a7 (the state after the turn), t5 (the move), s7, s8, and
    # everything .Lleaf uses.
    .macro  BOTTOM_TURN hit
    add     t0, s7, a6
    lhu     a6, 0(t0)
    add     t0, s8, a7
    lhu     a7, 0(t0)
    jal     s10, .Lleaf
    bgez    a0, \hit
    .endm

.Lbottom2:
    li      t5, 0
    mv      s7, s0
    mv      s8, s1
.Lbottom_face:
    beq     t5, a5, .Lbottom_next
    mv      a6, a3
    mv      a7, a4
    mv      t6, t5                  # the leaf level must not turn it again
    BOTTOM_TURN .Lbottom_hit0
    BOTTOM_TURN .Lbottom_hit1
    BOTTOM_TURN .Lbottom_hit2
.Lbottom_next:
    addi    t5, t5, 3
    add     s7, s7, s4
    add     s8, s8, s5
    bne     t5, s6, .Lbottom_face
    li      a0, -1
    ret
.Lbottom_hit2:
    addi    t5, t5, 1
.Lbottom_hit1:
    addi    t5, t5, 1
.Lbottom_hit0:
    sb      t5, 0(s11)
    sb      a0, 1(s11)
    ret

    # ---- Move k: every turn of the two faces other than t6 / 3, probed. ----
    # In:  a6, a7 = state, t6 = first move of the excluded face (9 = none).
    #      Return address in s10.
    # Out: a0 = the move that led into the table, with the end state in
    #      t1, t2; or a0 = -1.
    # Uses t0 to t4, a1, a2.
    .macro  LEAF_TURN hit
    STEP
    PROBE
    bltu    a1, s9, \hit
    .endm

.Lleaf:
    li      a0, 0
    mv      t3, s0
    mv      t4, s1
.Lleaf_face:
    beq     a0, t6, .Lleaf_next
    mv      t1, a6
    mv      t2, a7
    LEAF_TURN .Lleaf_hit0
    LEAF_TURN .Lleaf_hit1
    LEAF_TURN .Lleaf_hit2
.Lleaf_next:
    addi    a0, a0, 3
    add     t3, t3, s4
    add     t4, t4, s5
    bne     a0, s6, .Lleaf_face
    li      a0, -1
    jr      s10
.Lleaf_hit2:
    addi    a0, a0, 1
.Lleaf_hit1:
    addi    a0, a0, 1
.Lleaf_hit0:
    jr      s10
    .size   rubik_solve_asm, .-rubik_solve_asm
