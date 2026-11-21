#lang racket

;; package.rkt — NOVA-ELF packaging for the Turing increment image.
;;
;; SPDX-License-Identifier: LicenseRef-Sovereign-Leviathan-SL-AGPL3-001
;;
;; Mirrors the GF packaging (nova-elf/elf/package.rkt) but computes the
;; code/data split from this image's own labels instead of hardcoding
;; the GF split (705/26). The section structure is identical: the same
;; eight sections, the same standard S-box in .nova.rodata, the same
;; .note.nova. Two fields differ by design and are documented here:
;;
;;   .nova.urom: the GF descriptor attests the NovaDag outer-ROM manifest
;;   digest and dispatches to inner_pc 0x040. This image has no outer ROM
;;   and no Dag manifest yet, so its descriptor is self-attesting: the
;;   digest is the SHA-256 of this canonical image, and the dispatch
;;   words are VERIFY_MANIFEST, LOCK_IMMUTABLE, EXEC_INNER with
;;   inner_pc 0 (the Turing program entry), HALT.
;;   .nova.rodata: the standard AES S-box is the format's constant table.
;;   The Turing program does not use it; it is included so the object is
;;   structurally identical to the GF object for loader compatibility.
;;
;; The SHA-256 digest is kept over the canonical binary image, not over
;; any textual base encoding, so encodings can change without changing
;; the identity of the underlying microcode.

(provide package-turing-image
         load-turing-image
         image-sha256-hex
         turing-code-cells
         turing-data-cells)

(require "turing.rkt"
         "../nova-elf/elf/elf.rkt"
         "../nova-elf/elf/codec.rkt"
         "../subleq-isa-racket/subleq/asm.rkt"
         file/sha1)

;; Code cells: everything before the first data label. Data cells: the
;; rest, including the 4 reserved cells the assembler appends.
(define (turing-code-cells image labels)
  (hash-ref labels 'data-start))

(define (turing-data-cells image labels)
  (- (length image) (hash-ref labels 'data-start)))

;; SHA-256 of the canonical binary image (32-bit signed LE cells),
;; as a lowercase hex string.
(define (image-sha256-hex image)
  (bytes->hex-string (sha256-bytes (cells->bytes image))))

;; Build the NOVA-ELF file (bytes) for a Turing SUBLEQ image.
;; image-sha256 is the hex digest of the canonical image (from
;; image-sha256-hex). proof-json and dag-json are strings (UTF-8)
;; placed in their sections.
(define (package-turing-image image labels image-sha256 proof-json dag-json)
  (define code-cells (turing-code-cells image labels))
  (define code (take image code-cells))
  (define data (drop image code-cells))
  (define urom-content
    (bytes-append
     (u32 1) ; urom descriptor version
     (hex-string->bytes image-sha256) ; digest: SHA-256 of this image
     (u32 #x20000000) ; VERIFY_MANIFEST
     (u32 #x40000000) ; LOCK_IMMUTABLE
     (u32 #x30000000) ; EXEC_INNER, inner_pc=0 (Turing entry)
     (u32 #xf0000000))) ; HALT
  (define sections
    (list
     (list ".nova.text" 1 6 4 (cells->bytes code))
     (list ".nova.data" 1 3 4 (cells->bytes data))
     (list ".nova.rodata" 1 2 1 SBOX)
     (list ".nova.urom" 1 2 4 urom-content)
     (list ".nova.proof" 1 0 1 (string->bytes/utf-8 proof-json))
     (list ".nova.codec" 1 0 1 (string->bytes/utf-8 "NOVA-BASE256 v1"))
     (list ".nova.dag" 1 0 1 (string->bytes/utf-8 dag-json))
     (list ".note.nova" 7 0 4 (note-nova-bytes))))
  (nova-elf-write sections))

;; Load a NOVA-ELF file (bytes) back into a flat SUBLEQ image.
;; Verifies Load(ELF(M)) = M is the caller's check; this returns the image.
(define (load-turing-image elf-bytes)
  (define parsed (nova-elf-read elf-bytes))
  (define secs (nova-elf-sections parsed))
  (define text (hash-ref secs ".nova.text"))
  (define data (hash-ref secs ".nova.data"))
  (define (bytes->cells bs)
    (for/list ([i (in-range 0 (bytes-length bs) 4)])
      (integer-bytes->integer (subbytes bs i (+ i 4)) #t #f)))
  (append (bytes->cells text) (bytes->cells data)))

;; Local helpers (elf.rkt exports cells->bytes and note-nova-bytes;
;; u32 and hex-string->bytes are local to this module).
(define (u32 v) (integer->integer-bytes v 4 #f #f))

(define (hex-string->bytes s)
  (list->bytes
   (for/list ([i (in-range 0 (string-length s) 2)])
     (string->number (substring s i (+ i 2)) 16))))
