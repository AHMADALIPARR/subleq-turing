#lang racket

;; trace.rkt — SUBLEQ-level trace of the Turing machine for one input.
;;
;; SPDX-License-Identifier: LicenseRef-Sovereign-Leviathan-SL-AGPL3-001
;;
;; Steps the SUBLEQ machine and records the Turing-level configuration
;; (state, head position, tape) each time execution reaches the top of
;; the main loop. This shows the SUBLEQ program actually walking through
;; the expected Turing configurations, not just producing the right final
;; answer. Default input is 13 (00001101 -> 00001110 = 14).

(require "turing.rkt"
         "../subleq-isa-racket/subleq/machine.rkt"
         "../subleq-isa-racket/subleq/asm.rkt")

(define (trace-one n)
  (define-values (image labels) (assemble/labels (turing-items)))
  (define m (make-machine))
  (machine-load! m image)
  (define tape-addr (hash-ref labels 'tape))
  (define step-loop-addr (hash-ref labels 'step-loop))
  (define state-addr (hash-ref labels 'state))
  (define ptr-addr (hash-ref labels 'ptr))
  (define bits (number->tape-bits n 8))
  (for ([b (in-list bits)] [i (in-naturals)])
    (vector-set! (machine-mem m) (+ tape-addr i) b))
  (printf "input n=~a, tape=~a\n" n bits)
  (define step-no 0)
  (let loop ()
    (cond
      [(not (eq? (machine-status m) 'running)) (void)]
      [else
       (when (= (machine-pc m) step-loop-addr)
         (define mem (machine-mem m))
         (define state-val (vector-ref mem state-addr))
         (define ptr-val (vector-ref mem ptr-addr))
         (define head (- ptr-val tape-addr))
         (define tape-snapshot
           (for/list ([i (in-range -1 9)])
             (vector-ref mem (+ tape-addr i))))
         (printf "tm-step ~a: state=~a head=~a tape[guard..+8]=~a\n"
                 step-no state-val head tape-snapshot)
         (set! step-no (add1 step-no)))
       (machine-step! m)
       (loop)]))
  (define-values (got guard-val) (extract-result m tape-addr))
  (printf "halted: result=~a (want ~a), status=~a\n" got (+ n 1) (machine-status m)))

(module+ main
  (trace-one (if (> (vector-length (current-command-line-arguments)) 0)
                 (string->number (vector-ref (current-command-line-arguments) 0))
                 13)))
