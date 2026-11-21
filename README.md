# SUBLEQ Turing Increment

The binary-increment Turing machine from Fibonacci-Engine
(`elf/transitions/turing.elf`, a Twelf specification) lowered to pure
SUBLEQ microcode and packaged as NOVA-ELF.

The Twelf file itself is NOT in this repo. Its transition table and tape
semantics were transcribed into a SUBLEQ lowering (`turing.rkt`) and a
Racket reference model, then verified by execution and by Rosette/Z3.

Node: `turing.increment.v1`. Input: an 8-bit number, MSB-first on the
tape. Output: the incremented number (9 bits on overflow, 255 -> 256).

## Results

- Exhaustive: 0 mismatches / 256 inputs (SUBLEQ vs reference, and
  reference vs n+1).
- Rosette/Z3: delta totality/determinism PROVED, halt-is-identity
  PROVED, increment for all 8-bit inputs PROVED.
- Image: 276 cells (code 246 + data 30).
  SHA-256 fe289e0931f7bd3a19fe394422213400986fb846b2094700b70914765340d099
- NOVA-ELF: 2,672 bytes.
  SHA-256 db67a7a8493da66f6151607426fc6e6d705d15fd3ea54d3ac058722ea84cfc63
- SUBLEQ steps: min 247 (n=0), max 580 (n=255). Not constant-trace.

## Files

- `turing.rkt` — reference model, SUBLEQ emitter, runner, exhaustive test.
- `rosette_check.rkt` — Rosette/Z3 proofs.
- `trace.rkt` — SUBLEQ-level Turing trace for one input (default 13).
- `measure.rkt` — image size and step-count measurements.
- `package.rkt` — NOVA-ELF packaging for this image.
- `verify.rkt` — end-to-end verification and artifact packaging.
- `artifact/` — generated artifacts.
- `STATUS.md` — design, verification evidence, and open obligations.

## Reproduce

Racket is at `~/workspace/.tools/racket/bin/racket`.

- `(run-turing-all)` in `turing.rkt`: exhaustive 256-input test.
- `racket measure.rkt`: image size and step statistics.
- `racket trace.rkt [n]`: Turing-level trace for input n.
- `racket rosette_check.rkt`: the three Rosette/Z3 proofs.
- `racket verify.rkt`: everything, regenerates `artifact/`.

See `STATUS.md` for the full evidence, including the fall-through bug
caught by execution and the Rosette encoding error that first made the
increment proof report FAILED.
