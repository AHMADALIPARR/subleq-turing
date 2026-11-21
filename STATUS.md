# SUBLEQ Turing Increment — Status

Binary-increment Turing machine lowered to pure SUBLEQ and packaged as
NOVA-ELF. Source semantics transcribed from the Twelf (LF) specification
in Fibonacci-Engine (`elf/transitions/turing.elf`); the Twelf file itself
is NOT copied here. Only its transition table and tape semantics are
re-expressed as a SUBLEQ lowering and a Racket reference model.

## What it is

Node `turing.increment.v1`: the binary-increment machine (states scan,
carry, halt; symbols 0, 1, blank) implemented as a SUBLEQ program.
Input is an 8-bit number written MSB-first on the tape; output is the
incremented number (9 bits on overflow, e.g. 255 -> 256). The head is a
pointer cell; tape access uses patchable triples (raw word triples whose
operand cells are rewritten at runtime with the pointer value before
being jumped to). This is pure SUBLEQ — code is data in a uniform
memory — with no machine extension. A guard blank cell sits immediately
before the tape; the carry phase reads it when it runs off the left end
(the all-ones case), writes 1, and halts, producing the 9-bit result.

## Design

- Tape: 16 cells plus 1 guard cell. Head range is [guard, tape+8].
- State: scan=0, carry=1, halt=2. Symbols: 0, 1, blank=2.
- Main loop: halt check (state==2), read sym via the patchable read
  triple, dispatch on state, dispatch on sym, act, loop.
- Read: patch rd-op with ptr, clear tmp, jump to rd-op (tmp <- -tape[ptr]),
  then sym <- -tmp. Write 0: patch wr0-clr and jump (cell <- 0).
  Write 1: patch wr1-clr and jump (cell <- 0), tmp2 <- -1, patch wr-op
  and jump (cell <- 1).
- Each patchable triple is followed by an explicit jump to its
  continuation. SUBLEQ branches to the C operand only when the result
  is <= 0; otherwise it falls through to triple+3. The write triple
  produces a positive result (1), so without the following jump the
  machine would fall through into the data cells. This was a real bug,
  caught by execution (see below); the C operand covers the <= 0 case
  and the jump covers the > 0 case.

## Bug found and fixed by execution

The first build errored on input 0 after 235 SUBLEQ steps. A step trace
showed the machine jumping to pc=237 (the `tmp` data cell) after the
write triple: the triple wrote 1 (result positive), so the machine fell
through to triple+3 instead of branching to the C operand, landing in
data. Fix: an explicit `(jmp <continuation>)` after every patchable
triple. After the fix, all 13 sample inputs passed, then the exhaustive
test passed.

## Verification by execution

- SUBLEQ vs reference machine: 0 mismatches / 256 inputs (all 8-bit
  values 0..255, exhaustive).
- Reference machine vs n+1: 0 mismatches / 256 inputs.
- Increment from the ELF-loaded image: 0 mismatches / 256 inputs.
- ELF loader preserves the image: Load(ELF(M)) = M, verified.
- ELF round-trips through HEX16, BASE64, BASE32.
- ROMHEX round-trip: decode(encode(cells)) = cells.
- Trace (input 13 -> 14): 12 Turing steps, scan head 0->8, carry
  flips tape[7] 1->0 then tape[6] 0->1, halts with result 14.
- Image: 276 cells (code 246 + data 30, data includes 4 reserved cells).
- SUBLEQ steps over 256 inputs: min 247 (n=0), max 580 (n=255),
  average 39153/128 (~305.9). Step count varies with input, so this
  program is NOT constant-trace (scan and carry lengths are
  data-dependent). The v1 is the exhaustively tested baseline.

## Rosette/Z3 proofs (src/rosette_check.rkt, ~1 second)

- delta totality/determinism: PROVED. For every non-halt state (scan,
  carry) and every symbol (0, 1, blank) there is exactly one rule, and
  it is the rule in the Twelf table.
- halt is identity: PROVED. A step in state halt changes nothing.
- increment for all 8-bit inputs: PROVED. For a symbolic 8-bit n, after
  20 unrolled steps (more than the 18-step maximum) the machine is
  halted and the tape holds n+1.
- Note: an earlier run of the increment proof reported FAILED. That was
  an encoding error, not a counterexample: `extract-value` zero-extended
  a 20-bit cell value to 16 bits, which Rosette rejects, and `verify`
  reported the construction error as FAILED. The fix narrows the cell
  to its low 2 bits first (`extract 1 0`), then zero-extends. After the
  fix the proof passes. The encoding is also validated concretely: the
  unrolled Rosette machine was run on concrete inputs 0, 1, 13, 127,
  254, 255 and produced the right results before the symbolic proof
  was trusted.

## NOVA-ELF artifacts (artifact/)

- Image: `turing_increment.mem`, 276 cells.
  SHA-256 fe289e0931f7bd3a19fe394422213400986fb846b2094700b70914765340d099
- ELF: `turing_increment.nova.elf`, 2,672 bytes.
  SHA-256 db67a7a8493da66f6151607426fc6e6d705d15fd3ea54d3ac058722ea84cfc63
- ROMHEX: `turing_increment.nova.romhex`, 276 lines.
  SHA-256 b8fb21e418d433d7eba5b59759fb840033b324b0d72edfff47767923beed8098
- HEX16: `turing_increment.nova.hex16`.
  SHA-256 c4179b5f5f7442cecb673a3e6272f4ea02848c9f5e6a681e96a0157f7d36903d
- BASE64: `turing_increment.nova.b64`.
  SHA-256 61a4ae7bfd989d03962a41004b3ffa3302943ebef7ef1b0689b0fc73715cbc2b
- Manifest: `manifest.json`. Node record: `turing.increment.v1.json`.
- Evidence: `evidence.txt`.
  SHA-256 54f3d76a6f41fd3b585ac6ed9b9839cedde499eb537d2fce23d6de604edc5bd3

The `.nova.urom` descriptor in this object is self-attesting (see
package.rkt): its digest is the SHA-256 of this canonical image, and
its dispatch words are VERIFY_MANIFEST, LOCK_IMMUTABLE, EXEC_INNER
with inner_pc 0 (the Turing entry), HALT. The GF object instead attests
the NovaDag outer-ROM manifest digest and dispatches to inner_pc 0x040;
this image has no outer ROM and no Dag manifest yet. The `.nova.rodata`
section carries the standard AES S-box as the format's constant table;
the Turing program does not use it. It is included so the object is
structurally identical to the GF object for loader compatibility.

## What is NOT verified here

- Hardware refinement: no VHDL SUBLEQ core exists for this image. The
  equivalence holds within the tested Racket machine model; a formal
  refinement proof that hardware faithfully implements this model is a
  separate, still-required step.
- Constant-trace: not achieved and not claimed. Step counts vary from
  247 to 580 across the input domain.
- The Twelf proofs themselves (delta totality, determinism, trace
  consistency) were re-established here by execution and by Rosette/Z3
  over the transcribed semantics. The Twelf file was read as the
  specification; its proof terms were not imported or checked with Twelf.

## Files

- `src/turing.rkt` — reference model, SUBLEQ emitter, runner, exhaustive test.
- `src/rosette_check.rkt` — Rosette/Z3 proofs (delta, halt, increment).
- `src/trace.rkt` — SUBLEQ-level Turing trace for one input (default 13).
- `src/measure.rkt` — image size and step-count measurements.
- `src/package.rkt` — NOVA-ELF packaging for this image (generalized split).
- `src/verify.rkt` — end-to-end verification and artifact packaging.
- `artifact/` — generated artifacts (image, evidence, ELF, ROMHEX,
  encodings, manifest, node record).
- `LICENSE` — SNAPKITTY OPAQUE SOURCE LICENSE v1.0.

## Reproduce

- `racket src/turing.rkt` loads the module; `(run-turing-all)` runs the
  exhaustive 256-input test.
- `racket src/measure.rkt` prints image size and step statistics.
- `racket src/trace.rkt [n]` prints the Turing-level trace for input n.
- `racket src/rosette_check.rkt` runs the three Rosette/Z3 proofs.
- `racket src/verify.rkt` runs everything and regenerates `artifact/`.
  Racket is at `~/workspace/.tools/racket/bin/racket`.
