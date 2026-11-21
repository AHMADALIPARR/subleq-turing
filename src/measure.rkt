#lang racket

;; measure.rkt — image size and dynamic step measurements for the Turing lowering.
;;
;; SPDX-License-Identifier: LicenseRef-Sovereign-Leviathan-SL-AGPL3-001
;;
;; Reports: image cells, code/data split, and the SUBLEQ step counts
;; (min/max/average) over all 256 inputs. The step count varies with the
;; input (scan length and carry length are data-dependent), so this
;; program is NOT constant-trace; the counts below are the measured
;; evidence for that. The v1 is the exhaustively tested baseline.

(require "turing.rkt"
         "../../subleq-isa-racket/subleq/machine.rkt"
         "../../subleq-isa-racket/subleq/asm.rkt")

(define-values (image labels) (assemble/labels (turing-items)))
(define code-cells (hash-ref labels 'data-start))
(define data-cells (- (length image) code-cells))
(printf "image cells = ~a (code ~a + data ~a, data includes 4 reserved cells)\n"
        (length image) code-cells data-cells)

(define min-steps +inf.0)
(define max-steps 0)
(define total-steps 0)
(define min-n #f)
(define max-n #f)
(for ([n (in-range 256)])
  (define-values (got steps status) (run-turing-steps n))
  (unless (= got (+ n 1))
    (error 'measure "wrong result n=~a got=~a" n got))
  (when (< steps min-steps) (set! min-steps steps) (set! min-n n))
  (when (> steps max-steps) (set! max-steps steps) (set! max-n n))
  (set! total-steps (+ total-steps steps)))
(printf "SUBLEQ steps over 256 inputs: min ~a (n=~a), max ~a (n=~a), avg ~a\n"
        min-steps min-n max-steps max-n (/ total-steps 256))
(printf "step count varies with input: NOT constant-trace (expected: scan and carry lengths are data-dependent)\n")
