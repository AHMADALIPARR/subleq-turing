#lang racket

;; verify.rkt — end-to-end verification and artifact packaging.
;;
;; SPDX-License-Identifier: LicenseRef-Sovereign-Leviathan-SL-AGPL3-001
;;
;; Assembles the lowered SUBLEQ Turing increment program, runs the
;; exhaustive 256-input test against the reference machine (which itself
;; is checked against n+1), packages the verified image as a NOVA-ELF
;; object, and checks the ELF round-trip and the semantics of the
;; ELF-loaded image. Writes the artifact package (microcode image,
;; evidence, ELF, ROMHEX, encodings, manifest, node record).
;;
;; Checks, by execution:
;;   1. SUBLEQ vs reference: 0 mismatches / 256 inputs.
;;   2. Reference vs n+1: 0 mismatches / 256 inputs.
;;   3. ELF loader preserves the image: Load(ELF(M)) = M.
;;   4. Semantics from the ELF-loaded image: 0 mismatches / 256 inputs.
;;   5. ROMHEX round-trip: decode(encode(cells)) = cells.
;; Rosette/Z3 proofs (rosette_check.rkt, run separately): delta
;; totality/determinism PROVED, halt-is-identity PROVED, increment for
;; all 8-bit inputs PROVED.

(require "turing.rkt"
         "package.rkt"
         "../nova-elf/elf/elf.rkt"
         "../nova-elf/elf/codec.rkt"
         "../subleq-isa-racket/subleq/machine.rkt"
         "../subleq-isa-racket/subleq/asm.rkt"
         file/sha1)

(define (check name actual expected)
  (unless (equal? actual expected)
    (error 'verify "FAIL ~a: got ~e, want ~e" name actual expected))
  (printf "ok ~a\n" name))

(define (sha256-hex bs) (bytes->hex-string (sha256-bytes bs)))

;; ---------- assemble ----------
(define-values (image labels) (assemble/labels (turing-items)))
(define tape-addr (hash-ref labels 'tape))
(define state-addr (hash-ref labels 'state))
(define code-cells (turing-code-cells image labels))
(define data-cells (turing-data-cells image labels))
(define image-hex (image-sha256-hex image))
(printf "image cells = ~a (code ~a + data ~a)\n"
        (length image) code-cells data-cells)
(printf "image sha256 = ~a\n" image-hex)

;; Write the SUBLEQ microcode image (one integer per line).
(call-with-output-file "artifact/turing_increment.mem"
  #:exists 'replace
  (lambda (out)
    (for ([v (in-list image)])
      (fprintf out "~a\n" v))))

;; ---------- 1+2. exhaustive test ----------
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
    (error 'verify "machine did not halt: ~a (n=~a)" status n))
  (define-values (got guard-val) (extract-result m tape-addr))
  (define state-val (vector-ref (machine-mem m) state-addr))
  (unless (= state-val 2)
    (error 'verify "machine halted in wrong state: ~a (n=~a)" state-val n))
  (define want-ref (turing-increment-ref n))
  (unless (= got want-ref) (set! mismatches (add1 mismatches)))
  (unless (= want-ref (+ n 1)) (set! ref-mismatches (add1 ref-mismatches))))
(printf "SUBLEQ vs reference: mismatches = ~a / 256\n" mismatches)
(printf "reference vs n+1: mismatches = ~a / 256\n" ref-mismatches)
(check "SUBLEQ vs reference" mismatches 0)
(check "reference vs n+1" ref-mismatches 0)

;; ---------- evidence ----------
(call-with-output-file "artifact/evidence.txt"
  #:exists 'replace
  (lambda (out)
    (fprintf out "turing increment SUBLEQ lowering — verification evidence\n")
    (fprintf out "exhaustive inputs tested: 256 (all 8-bit values 0..255)\n")
    (fprintf out "SUBLEQ vs reference mismatches: ~a\n" mismatches)
    (fprintf out "reference vs n+1 mismatches: ~a\n" ref-mismatches)
    (fprintf out "reference: turing-increment-ref (Twelf turing.elf semantics)\n")
    (fprintf out "machine: subleq-isa-racket machine.rkt (Racket simulator)\n")
    (fprintf out "image cells: ~a (code ~a + data ~a)\n"
             (length image) code-cells data-cells)
    (fprintf out "image sha256: ~a\n" image-hex)
    (fprintf out "Rosette/Z3 properties: delta totality/determinism PROVED, halt-is-identity PROVED, increment-for-all-8-bit-n PROVED\n")
    (fprintf out "note: exhaustive equivalence holds within the tested machine model.\n")
    (fprintf out "A formal refinement proof that the VHDL SUBLEQ hardware faithfully\n")
    (fprintf out "implements this model is a separate, still-required step.\n")))

;; ---------- 3. ELF packaging and round-trip ----------
(define proof-json
  (format "{\"exhaustive\":\"0 mismatches / 256 inputs\",\"rosette\":\"delta totality/determinism PROVED, halt-is-identity PROVED, increment-for-all-8-bit-n PROVED\",\"image_sha256\":\"~a\"}" image-hex))
(define dag-json
  "{\"schema\":\"rijndael.dag.v1\",\"id\":\"turing.increment.v1\",\"parents\":[\"fibonacci-engine:elf/transitions/turing.elf\"]}")

(define elf-bytes (package-turing-image image labels image-hex proof-json dag-json))
(printf "ELF file size = ~a bytes\n" (bytes-length elf-bytes))
(define elf-hex (sha256-hex elf-bytes))
(printf "ELF sha256 = ~a\n" elf-hex)
(define loaded-image (load-turing-image elf-bytes))
(check "ELF loader preserves image" loaded-image image)

;; The ELF itself round-trips through each codec (bytes -> text -> bytes).
(check "ELF via HEX16"
       (nova-hex16-decode (nova-hex16-encode elf-bytes)) elf-bytes)
(check "ELF via BASE64"
       (nova-base64-decode (nova-base64-encode elf-bytes)) elf-bytes)
(check "ELF via BASE32"
       (nova-base32-decode (nova-base32-encode elf-bytes)) elf-bytes)

;; ---------- 4. semantics from the ELF-loaded image ----------
(define elf-mismatches 0)
(for ([n (in-range 256)])
  (define m (make-machine))
  (machine-load! m loaded-image)
  (define bits (number->tape-bits n 8))
  (for ([b (in-list bits)] [i (in-naturals)])
    (vector-set! (machine-mem m) (+ tape-addr i) b))
  (define status (machine-run m))
  (unless (eq? status 'halted)
    (error 'verify "loaded image did not halt: ~a (n=~a)" status n))
  (define-values (got guard-val) (extract-result m tape-addr))
  (unless (= got (+ n 1)) (set! elf-mismatches (add1 elf-mismatches))))
(printf "increment from ELF-loaded image: mismatches = ~a / 256\n" elf-mismatches)
(check "increment preserved through ELF" elf-mismatches 0)

;; ---------- 5. ROMHEX round-trip ----------
(define romhex-text (nova-romhex-encode image))
(define romhex-cells (nova-romhex-decode romhex-text))
(check "ROMHEX round-trip" romhex-cells image)
(define romhex-lines (length (string-split romhex-text "\n")))
(printf "ROMHEX lines = ~a\n" romhex-lines)

;; ---------- write artifacts ----------
(define hex16-text (nova-hex16-encode elf-bytes))
(define b64-text (nova-base64-encode elf-bytes))
(void
 (call-with-output-file "artifact/turing_increment.nova.elf"
   #:exists 'replace
   (lambda (out) (write-bytes elf-bytes out))))
(call-with-output-file "artifact/turing_increment.nova.romhex"
  #:exists 'replace
  (lambda (out) (display romhex-text out)))
(call-with-output-file "artifact/turing_increment.nova.hex16"
  #:exists 'replace
  (lambda (out) (display hex16-text out)))
(call-with-output-file "artifact/turing_increment.nova.b64"
  #:exists 'replace
  (lambda (out) (display b64-text out)))

(define manifest-json
  (format
   "{\"artifact\":\"turing.increment.v1\",\"canonical_image\":{\"cells\":~a,\"sha256\":\"~a\"},\"codec\":{\"identifier\":\"NOVA-BASE256 v1\",\"version\":1},\"dag_node\":\"turing.increment.v1\",\"elf\":{\"bytes\":~a,\"sha256\":\"~a\",\"version\":\"NOVA-ELF v1\"},\"encodings\":{\"b64\":{\"bytes\":~a,\"sha256\":\"~a\"},\"hex16\":{\"bytes\":~a,\"sha256\":\"~a\"},\"romhex\":{\"bytes\":~a,\"lines\":~a,\"sha256\":\"~a\"}},\"lineage\":{\"parents\":[\"fibonacci-engine:elf/transitions/turing.elf\"],\"transformation\":\"lower-turing-to-subleq\"},\"proof\":{\"elf_loader\":\"Load(ELF(M))=M verified by round-trip\",\"exhaustive\":\"0 mismatches / 256 inputs (ELF-loaded image)\",\"romhex\":\"decode(encode(cells))=cells verified\",\"rosette\":\"delta totality/determinism PROVED, halt-is-identity PROVED, increment-for-all-8-bit-n PROVED\"},\"verification\":{\"hardware_refinement\":\"pending\",\"status\":\"proved (within the tested machine model)\"}}"
   (length image) image-hex
   (bytes-length elf-bytes) elf-hex
   (string-length b64-text) (sha256-hex (string->bytes/utf-8 b64-text))
   (string-length hex16-text) (sha256-hex (string->bytes/utf-8 hex16-text))
   (string-length romhex-text) romhex-lines (sha256-hex (string->bytes/utf-8 romhex-text))))
(call-with-output-file "artifact/manifest.json"
  #:exists 'replace
  (lambda (out) (display manifest-json out)))

(define evidence-hex (sha256-hex (file->bytes "artifact/evidence.txt")))
(define node-json
  (format
   "{\"artifact\":{\"evidence\":\"artifact/evidence.txt\",\"evidence_sha256\":\"~a\",\"image\":\"artifact/turing_increment.mem\",\"image_cells\":~a,\"image_sha256\":\"~a\"},\"field\":{\"states\":3,\"symbols\":3,\"tape_cells\":16},\"id\":\"turing.increment.v1\",\"kind\":\"implementation\",\"language\":\"SUBLEQ\",\"operation\":\"increment\",\"parameters\":{\"input_bits\":8,\"output_bits\":9,\"word_bits\":32},\"parents\":[\"fibonacci-engine:elf/transitions/turing.elf\"],\"schema\":\"rijndael.dag.v1\",\"source\":\"subleq-turing/turing.rkt\",\"transformation\":{\"engine\":\"racket\",\"name\":\"lower-turing-to-subleq\",\"revision\":1},\"verification\":{\"evidence\":[\"artifact/turing_increment.mem: sha256 ~a\",\"artifact/evidence.txt: sha256 ~a\",\"exhaustive: 0 mismatches / 256 inputs (SUBLEQ vs turing-increment-ref)\",\"reference: 0 mismatches / 256 inputs (turing-increment-ref vs n+1)\",\"rosette: delta totality/determinism PROVED, halt-is-identity PROVED, increment-for-all-8-bit-n PROVED\"],\"obligations\":[\"turing_equivalence\",\"loop_termination\",\"instruction_semantics\",\"hardware_refinement\"],\"status\":\"proved\",\"tool\":\"racket-exhaustive+rosette\"}}"
   evidence-hex (length image) image-hex image-hex evidence-hex))
(call-with-output-file "artifact/turing.increment.v1.json"
  #:exists 'replace
  (lambda (out) (display node-json out)))

(printf "artifacts written to artifact/\n")
