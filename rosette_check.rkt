#lang rosette

;; rosette_check.rkt — formal proof (Rosette/Z3) of the binary-increment
;; Turing machine properties.
;;
;; SPDX-License-Identifier: LicenseRef-Sovereign-Leviathan-SL-AGPL3-001
;;
;; What is proved here is about the Turing machine semantics transcribed
;; from the Twelf specification (delta table, step, run), NOT about the
;; SUBLEQ program directly. The SUBLEQ program's equivalence to the
;; reference is established by the exhaustive 256-input test
;; (run-turing-all: 0 mismatches / 256). Together they give:
;;   SUBLEQ program == reference machine (tested, exhaustive over 8 bits)
;;   reference machine == increment (proved symbolically, all 8-bit inputs)
;;
;; Encoding: the tape is 10 cells x 2 bits = a 20-bit bitvector; cell i
;; occupies bits [2i+1 : 2i]. Head is a 4-bit index (0..9); cell 0 is the
;; guard, cells 1..8 hold the input, cell 9 is the blank past the LSB.
;; State is 2-bit: 0 scan, 1 carry, 2 halt. Move is 2-bit: 0 left,
;; 1 stay, 2 right.
;;
;; Check A — delta totality and determinism: for every non-halt state
;; (0, 1) and every symbol (0, 1, 2) there is exactly one rule, and it is
;; the rule in the Twelf table; state 2 (halt) has no rule, so a step
;; there is the identity.
;;
;; Check B — increment correctness: for a symbolic 8-bit input n, after
;; 20 unrolled steps (more than the 18-step maximum: 9 scan + 9 carry)
;; the machine is halted and the tape holds n+1. The step function is
;; the identity at halt, so the extra unrolled steps are harmless.

;; ---------- tape helpers ----------

;; Cell i of the tape (20-bit bv), i a 4-bit bv.
(define (cell-at tape head)
  (define shift (bvshl (zero-extend head (bitvector 20)) (bv 1 20)))
  (bvand (bvlshr tape shift) (bv 3 20)))

;; Write val (20-bit, 0..2) into cell head of the tape.
(define (write-cell tape head val)
  (define shift (bvshl (zero-extend head (bitvector 20)) (bv 1 20)))
  (define mask (bvnot (bvshl (bv 3 20) shift)))
  (bvor (bvand tape mask) (bvshl val shift)))

;; ---------- delta (the Twelf transition table) ----------

;; Returns (list write move next-state). write is 20-bit, move is
;; 2-bit (0 left, 1 stay, 2 right), next-state is 2-bit. A list (not
;; multiple values) is returned because Rosette cannot merge multiple
;; values across symbolic branches.
;; State 2 (halt) has no rule; callers must not apply delta there.
(define (delta state sym)
  (cond
    [(and (bveq state (bv 0 2)) (bveq sym (bv 0 20)))
     (list (bv 0 20) (bv 2 2) (bv 0 2))] ; scan, 0 -> write 0, right, scan
    [(and (bveq state (bv 0 2)) (bveq sym (bv 1 20)))
     (list (bv 1 20) (bv 2 2) (bv 0 2))] ; scan, 1 -> write 1, right, scan
    [(and (bveq state (bv 0 2)) (bveq sym (bv 2 20)))
     (list (bv 2 20) (bv 0 2) (bv 1 2))] ; scan, blank -> write 2, left, carry
    [(and (bveq state (bv 1 2)) (bveq sym (bv 1 20)))
     (list (bv 0 20) (bv 0 2) (bv 1 2))] ; carry, 1 -> write 0, left, carry
    [(and (bveq state (bv 1 2)) (bveq sym (bv 0 20)))
     (list (bv 1 20) (bv 1 2) (bv 2 2))] ; carry, 0 -> write 1, stay, halt
    [(and (bveq state (bv 1 2)) (bveq sym (bv 2 20)))
     (list (bv 1 20) (bv 1 2) (bv 2 2))] ; carry, blank -> write 1, stay, halt
    [else (list (bv 0 20) (bv 1 2) (bv 2 2))])) ; unreachable for valid inputs

;; ---------- one machine step ----------

(define (move-head head move)
  (cond [(bveq move (bv 0 2)) (bvsub head (bv 1 4))]
        [(bveq move (bv 2 2)) (bvadd head (bv 1 4))]
        [else head]))

(define (tm-step tape head state)
  (if (bveq state (bv 2 2))
      (list tape head state)
      (let ([d (delta state (cell-at tape head))])
        (list (write-cell tape head (first d))
              (move-head head (second d))
              (third d)))))

;; ---------- Check A: delta totality and determinism ----------

(define-symbolic qa-state (bitvector 2))
(define-symbolic qa-sym (bitvector 20))

;; For every (state, sym) with state in {0,1} and sym in {0,1,2}, delta
;; returns exactly the table entry. The conjunction below pins all six.
(define (delta-matches-table? state sym)
  (let* ([d (delta state sym)]
         [w (first d)]
         [m (second d)]
         [n (third d)])
    (and
     (=> (and (bveq state (bv 0 2)) (bveq sym (bv 0 20)))
         (and (bveq w (bv 0 20)) (bveq m (bv 2 2)) (bveq n (bv 0 2))))
     (=> (and (bveq state (bv 0 2)) (bveq sym (bv 1 20)))
         (and (bveq w (bv 1 20)) (bveq m (bv 2 2)) (bveq n (bv 0 2))))
     (=> (and (bveq state (bv 0 2)) (bveq sym (bv 2 20)))
         (and (bveq w (bv 2 20)) (bveq m (bv 0 2)) (bveq n (bv 1 2))))
     (=> (and (bveq state (bv 1 2)) (bveq sym (bv 1 20)))
         (and (bveq w (bv 0 20)) (bveq m (bv 0 2)) (bveq n (bv 1 2))))
     (=> (and (bveq state (bv 1 2)) (bveq sym (bv 0 20)))
         (and (bveq w (bv 1 20)) (bveq m (bv 1 2)) (bveq n (bv 2 2))))
     (=> (and (bveq state (bv 1 2)) (bveq sym (bv 2 20)))
         (and (bveq w (bv 1 20)) (bveq m (bv 1 2)) (bveq n (bv 2 2)))))))

(define delta-sol
  (verify
   (assert
    (=> (and (bvult qa-state (bv 2 2)) (bvult qa-sym (bv 3 20)))
        (delta-matches-table? qa-state qa-sym)))))

;; Halt is the identity: a step in state 2 changes nothing.
(define-symbolic qb-tape (bitvector 20))
(define-symbolic qb-head (bitvector 4))
(define halt-sol
  (verify
   (assert
    (let ([r (tm-step qb-tape qb-head (bv 2 2))])
      (and (bveq (first r) qb-tape)
           (bveq (second r) qb-head)
           (bveq (third r) (bv 2 2)))))))

(printf "delta totality/determinism : ~a\n"
        (if (unsat? delta-sol) "PROVED" "FAILED"))
(printf "halt is identity          : ~a\n"
        (if (unsat? halt-sol) "PROVED" "FAILED"))

;; ---------- Check B: increment correctness for a symbolic 8-bit input ----------

(define-symbolic n (bitvector 8))

;; Build the initial tape: guard blank, cells 1..8 = bits of n MSB-first,
;; cell 9 blank. Cell c (1..8) holds bit (8-c) of n.
(define (init-tape n)
  (define guard (bvshl (bv 2 20) (bv 0 20)))
  (define last-blank (bvshl (bv 2 20) (bv 18 20)))
  (define bits
    (for/fold ([t (bv 0 20)]) ([c (in-range 1 9)])
      (define bit
        (zero-extend
         (bvand (bvlshr n (bv (- 8 c) 8)) (bv 1 8))
         (bitvector 20)))
      (bvor t (bvshl bit (bv (* 2 c) 20)))))
  (bvor guard (bvor bits last-blank)))

;; Extract the result number (16-bit) from the final tape: if the guard
;; cell is 1 the result is 9 bits (guard + cells 1..8), else 8 bits
;; (cells 1..8). Cell c contributes bit value times 2^(8-c).
(define (extract-value tape)
  (define guard-one? (bveq (cell-at tape (bv 0 4)) (bv 1 20)))
  (define eight-bit
    (for/fold ([v (bv 0 16)]) ([c (in-range 1 9)])
      ;; cell-at returns a 20-bit value; narrow to its low 2 bits first,
      ;; then zero-extend to 16 bits (zero-extend cannot shrink).
      (define cell (zero-extend (extract 1 0 (cell-at tape (bv c 4))) (bitvector 16)))
      (bvadd v (bvshl cell (bv (- 8 c) 16)))))
  (define nine-bit
    (bvadd (bvshl (bv 1 16) (bv 8 16)) eight-bit))
  (if guard-one? nine-bit eight-bit))

(define init (init-tape n))
(define final-conf
  (let loop ([tape init] [head (bv 1 4)] [state (bv 0 2)] [i 0])
    (if (= i 20)
        (list tape head state)
        (let ([r (tm-step tape head state)])
          (loop (first r) (second r) (third r) (add1 i))))))
(define final-tape (first final-conf))
(define final-head (second final-conf))
(define final-state (third final-conf))

(define increment-sol
  (verify
   (assert
    (and (bveq final-state (bv 2 2))
         (bveq (extract-value final-tape)
               (bvadd (zero-extend n (bitvector 16)) (bv 1 16)))))))

(printf "increment for all 8-bit n : ~a\n"
        (if (unsat? increment-sol) "PROVED" "FAILED"))
