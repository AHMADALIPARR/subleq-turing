#lang racket

;; turing.rkt — Racket lowering engine: binary-increment Turing machine -> SUBLEQ microcode.
;;
;; SPDX-License-Identifier: LicenseRef-Sovereign-Leviathan-SL-AGPL3-001
;;
;; Source semantics transcribed from the Twelf (LF) specification of the
;; binary-increment machine (Fibonacci-Engine, elf/transitions/turing.elf).
;; The Twelf file itself is NOT copied here; only its transition table and
;; tape semantics are re-expressed as a SUBLEQ lowering and a Racket
;; reference model. The Twelf proofs (delta totality, determinism, trace
;; consistency) are re-established here by execution and by Rosette/Z3
;; (see rosette_check.rkt); they are not imported.
;;
;; The machine:
;;   States: scan (0), carry (1), halt (2).
;;   Symbols: t0 (0), t1 (1), tb blank (2).
;;   Tape: zipper; cells beyond the ends read as blank. The machine
;;   increments a binary number written MSB-first: scan right to the
;;   end, then carry left flipping 1s to 0s until a 0 (flip to 1, halt)
;;   or a blank (write 1, halt).
;;
;; Transition table (delta), one rule per (state, symbol):
;;   scan,  0 -> write 0, move Right, scan
;;   scan,  1 -> write 1, move Right, scan
;;   scan,  2 -> write 2, move Left,  carry
;;   carry, 1 -> write 0, move Left,  carry
;;   carry, 0 -> write 1, move Stay,  halt
;;   carry, 2 -> write 1, move Stay,  halt
;;
;; Target: the SUBLEQ machine (subleq-isa-racket/subleq/machine.rkt)
;; and macro assembler (subleq-isa-racket/subleq/asm.rkt).
;;   mem[B] <- mem[B] - mem[A]; if result <= 0, pc <- C, else pc <- pc + 3.
;;   One instruction, three cells per step, 65536 cells of memory.
;;
;; Tape representation in SUBLEQ memory: a guard cell (blank) immediately
;; before a 16-cell tape region. The head is a pointer cell `ptr` holding
;; the address of the current tape cell; it starts at the tape base and
;; moves by inc/dec. The guard cell is what the carry phase reads when it
;; runs off the left end (the all-ones case, e.g. 255 -> 256): the Twelf
;; shift/L-end rule reads blank there, so the machine writes 1 and halts,
;; producing a 9-bit result. The head never leaves [guard, tape+8].
;;
;; Indirect access (tape[ptr]) uses patchable triples: raw word triples
;; placed after the halt whose operand cells are rewritten at runtime with
;; the current pointer value before the triple is jumped to. This is pure
;; SUBLEQ (code is data in a uniform memory); no machine extension.
;;   rd-op : tmp <- -tape[ptr]          (A operand patched with ptr)
;;   wr0-clr, wr1-clr : tape[ptr] <- 0  (A and B operands patched with ptr)
;;   wr-op : tape[ptr] <- 1             (B operand patched with ptr;
;;                                        A is tmp2 holding -1, cell pre-cleared)

(require "../../subleq-isa-racket/subleq/machine.rkt"
         "../../subleq-isa-racket/subleq/asm.rkt")

(provide tm-step-ref
         turing-run-ref
         turing-increment-ref
         tape-bits->number
         number->tape-bits
         turing-items
         run-turing
         run-turing-all
         run-turing-steps
         extract-result
         TAPE-CELLS)

(define TAPE-CELLS 16)

;; ---------- reference model (direct transcription of the Twelf semantics) ----------

;; A tape is a vector of 17 cells: index 0 is the guard (left of the tape),
;; indices 1..16 are the tape cells. Head is an index into this vector.
;; Symbols: 0, 1, 2 (blank). States: 0 scan, 1 carry, 2 halt.
(struct tm-state (tape head state) #:transparent #:mutable)

(define (tm-step-ref st)
  (define tape (tm-state-tape st))
  (define head (tm-state-head st))
  (define state (tm-state-state st))
  (define sym (vector-ref tape head))
  (cond
    [(= state 0) ; scan
     (cond
       [(= sym 0) (set-tm-state-head! st (+ head 1))]
       [(= sym 1) (set-tm-state-head! st (+ head 1))]
       [(= sym 2)
        (set-tm-state-head! st (- head 1))
        (set-tm-state-state! st 1)])]
    [(= state 1) ; carry
     (cond
       [(= sym 1)
        (vector-set! tape head 0)
        (set-tm-state-head! st (- head 1))]
       [(= sym 0)
        (vector-set! tape head 1)
        (set-tm-state-state! st 2)]
       [(= sym 2)
        (vector-set! tape head 1)
        (set-tm-state-state! st 2)])]
    [else (void)])) ; halt: step is the identity

;; Run the reference machine on input n (0..255). Returns the final tm-state.
(define (turing-run-ref n)
  (define tape (make-vector 17 2))
  (define bits (number->tape-bits n 8))
  (for ([b (in-list bits)] [i (in-naturals 1)])
    (vector-set! tape i b))
  (define st (tm-state tape 1 0))
  (let loop ([fuel 100])
    (cond
      [(= (tm-state-state st) 2) st]
      [(= fuel 0) (error 'turing-run-ref "reference did not halt for n=~a" n)]
      [else (tm-step-ref st) (loop (sub1 fuel))])))

;; Bits of n, MSB-first, exactly w bits.
(define (number->tape-bits n w)
  (for/list ([i (in-range (sub1 w) -1 -1)])
    (bitwise-and (arithmetic-shift n (- i)) 1)))

;; Fold a list of bits (MSB-first) into a number. Blank cells (2) are not
;; expected inside the field; they count as 0 if present.
(define (tape-bits->number bits)
  (for/fold ([v 0]) ([b (in-list bits)])
    (+ (* v 2) (if (= b 2) 0 b))))

;; The incremented value of n, as computed by the reference machine:
;; 9 bits if the guard became 1 (overflow), else the 8 tape bits.
(define (turing-increment-ref n)
  (define st (turing-run-ref n))
  (define tape (tm-state-tape st))
  (define bits
    (if (= (vector-ref tape 0) 1)
        (for/list ([i (in-range 0 9)]) (vector-ref tape i))
        (for/list ([i (in-range 1 9)]) (vector-ref tape i))))
  (tape-bits->number bits))

;; ---------- SUBLEQ program ----------
;; Layout: main loop, then the patchable triples (after halt, never fallen
;; through to), then the data cells. The first data label is data-start;
;; its address is the code size used by the NOVA-ELF split.

(define (turing-items)
  (list
   ;; --- main loop ---
   `(label step-loop)
   ;; halt check: t = state - 1; if t > 0 (state == 2) -> halt
   `(mov state t)
   `(sub k1 t)
   `(jpos t L-halt)
   ;; read sym = tape[ptr] through the patchable triple
   `(mov ptr rd-op)
   `(clr tmp)
   `(jmp rd-op)
   `(label rd-after)
   `(clr sym)
   `(sub tmp sym)
   ;; dispatch on state: 0 -> scan, 1 -> carry
   `(jle state L-scan)
   ;; --- carry: sym==0 -> write 1, halt; sym==1 -> write 0, ptr--; sym==2 -> write 1, halt
   `(jle sym L-carry-0)
   `(mov sym t)
   `(sub k1 t)
   `(jle t L-carry-1)
   ;; sym == 2: fall through to write-1
   `(label L-carry-w1)
   `(mov ptr wr1-clr)
   `(mov ptr wr1-clr-b)
   `(jmp wr1-clr)
   `(label L-w1-mid)
   `(clr tmp2)
   `(sub k1 tmp2)
   `(mov ptr wr-op-b)
   `(jmp wr-op)
   `(label L-w1-after)
   `(mov k2 state)
   `(jmp step-loop)
   `(label L-carry-0)
   `(jmp L-carry-w1)
   `(label L-carry-1)
   `(mov ptr wr0-clr)
   `(mov ptr wr0-clr-b)
   `(jmp wr0-clr)
   `(label L-carry-1-after)
   `(dec ptr)
   `(jmp step-loop)
   ;; --- scan: sym==0 or 1 -> advance; sym==2 -> ptr--, state = carry
   `(label L-scan)
   `(jle sym L-scan-adv)
   `(mov sym t)
   `(sub k1 t)
   `(jle t L-scan-adv)
   `(dec ptr)
   `(mov k1 state)
   `(jmp step-loop)
   `(label L-scan-adv)
   `(inc ptr)
   `(jmp step-loop)
   `(label L-halt)
   `(halt)
   ;; --- patchable triples (executed only via jmp; never fallen through to) ---
   ;; Each triple is followed by an explicit jump to its continuation.
   ;; SUBLEQ branches to the C operand only when the result is <= 0;
   ;; otherwise it falls through to triple+3. The write triple produces
   ;; a positive result (1), so without the following jump the machine
   ;; would fall through into the data cells. The C operand covers the
   ;; <= 0 case; the jump covers the > 0 case; both reach the same label.
   ;; rd-op: tmp <- tmp - mem[ptr]; tmp was cleared, so tmp <- -tape[ptr].
   `(label rd-op)
   `(word 0)
   `(word tmp)
   `(word rd-after)
   `(jmp rd-after)
   ;; wr0-clr: mem[ptr] <- mem[ptr] - mem[ptr] = 0 (carry-1 write-0 path).
   `(label wr0-clr)
   `(word 0)
   `(label wr0-clr-b)
   `(word 0)
   `(word L-carry-1-after)
   `(jmp L-carry-1-after)
   ;; wr1-clr: mem[ptr] <- 0 (carry write-1 path, first half).
   `(label wr1-clr)
   `(word 0)
   `(label wr1-clr-b)
   `(word 0)
   `(word L-w1-mid)
   `(jmp L-w1-mid)
   ;; wr-op: mem[ptr] <- mem[ptr] - tmp2; cell is 0 and tmp2 is -1, so mem[ptr] <- 1.
   `(label wr-op)
   `(word tmp2)
   `(label wr-op-b)
   `(word 0)
   `(word L-w1-after)
   `(jmp L-w1-after)
   ;; --- data ---
   `(label data-start)
   `(label ptr)   `(word tape)
   `(label state) `(word 0)
   `(label sym)   `(word 0)
   `(label tmp)   `(word 0)
   `(label tmp2)  `(word 0)
   `(label t)     `(word 0)
   `(label k0)    `(word 0)
   `(label k1)    `(word 1)
   `(label k2)    `(word 2)
   `(label guard) `(word 2)
   `(label tape)  `(word 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2)))

;; ---------- run ----------

;; Extract the result number from a halted machine's memory.
;; The guard cell (tape-1) is 1 only on overflow (input 255); otherwise the
;; result is the 8 tape bits. Returns two values: the number and the state cell.
(define (extract-result m tape-addr)
  (define mem (machine-mem m))
  (define guard-val (vector-ref mem (- tape-addr 1)))
  (define bits
    (if (= guard-val 1)
        (for/list ([i (in-range -1 8)]) (vector-ref mem (+ tape-addr i)))
        (for/list ([i (in-range 0 8)]) (vector-ref mem (+ tape-addr i)))))
  (values (tape-bits->number bits) guard-val))

;; Run the SUBLEQ program on input n. Returns the incremented number.
(define (run-turing n)
  (define-values (image labels) (assemble/labels (turing-items)))
  (define m (make-machine))
  (machine-load! m image)
  (define tape-addr (hash-ref labels 'tape))
  (define bits (number->tape-bits n 8))
  (for ([b (in-list bits)] [i (in-naturals)])
    (vector-set! (machine-mem m) (+ tape-addr i) b))
  (define status (machine-run m))
  (unless (eq? status 'halted)
    (error 'run-turing "machine did not halt: ~a (n=~a)" status n))
  (define-values (got guard-val) (extract-result m tape-addr))
  (define state-val (vector-ref (machine-mem m) (hash-ref labels 'state)))
  (unless (= state-val 2)
    (error 'run-turing "machine halted in wrong state: ~a (n=~a)" state-val n))
  got)

;; Run the SUBLEQ program on input n, counting SUBLEQ steps.
;; Returns three values: result number, SUBLEQ steps taken, final status.
(define (run-turing-steps n)
  (define-values (image labels) (assemble/labels (turing-items)))
  (define m (make-machine))
  (machine-load! m image)
  (define tape-addr (hash-ref labels 'tape))
  (define bits (number->tape-bits n 8))
  (for ([b (in-list bits)] [i (in-naturals)])
    (vector-set! (machine-mem m) (+ tape-addr i) b))
  (define steps 0)
  (let loop ()
    (cond
      [(not (eq? (machine-status m) 'running)) (void)]
      [else (machine-step! m) (set! steps (add1 steps)) (loop)]))
  (define status (machine-status m))
  (unless (eq? status 'halted)
    (error 'run-turing-steps "machine did not halt: ~a (n=~a)" status n))
  (define-values (got guard-val) (extract-result m tape-addr))
  (values got steps status))

;; Exhaustive test: all 8-bit inputs 0..255. The SUBLEQ result must equal
;; the reference machine's result, which must equal n+1.
(define (run-turing-all)
  (define-values (image labels) (assemble/labels (turing-items)))
  (define tape-addr (hash-ref labels 'tape))
  (define state-addr (hash-ref labels 'state))
  (define mismatches 0)
  (define ref-mismatches 0)
  (for ([n (in-range 256)])
    (define m (make-machine))
    (machine-load! m image)
    (define bits (number->tape-bits n 8))
    (for ([b (in-list bits)] [i (in-naturals)])
      (vector-set! (machine-mem m) (+ tape-addr i) b))
    (define status (machine-run m))
    (unless (eq? status 'halted)
      (error 'run-turing-all "machine did not halt: ~a (n=~a)" status n))
    (define-values (got guard-val) (extract-result m tape-addr))
    (define state-val (vector-ref (machine-mem m) state-addr))
    (unless (= state-val 2)
      (error 'run-turing-all "machine halted in wrong state: ~a (n=~a)" state-val n))
    (define want-ref (turing-increment-ref n))
    (define want (+ n 1))
    (unless (= got want-ref)
      (set! mismatches (add1 mismatches))
      (when (< mismatches 10)
        (printf "MISMATCH n=~a got=~a ref=~a\n" n got want-ref)))
    (unless (= want-ref want)
      (set! ref-mismatches (add1 ref-mismatches))
      (when (< ref-mismatches 10)
        (printf "REF MISMATCH n=~a ref=~a want n+1=~a\n" n want-ref want))))
  (printf "turing SUBLEQ vs reference: mismatches = ~a / 256\n" mismatches)
  (printf "turing reference vs n+1: mismatches = ~a / 256\n" ref-mismatches)
  (printf "image cells = ~a\n" (length image))
  (values mismatches ref-mismatches))
