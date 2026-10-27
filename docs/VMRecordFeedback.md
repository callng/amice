# Instruction-local feedback decoding

The fork accepts an optional `decoder.vm` step immediately before
`varint_decode`:

```text
step record_feedback key=function_key
step varint_decode
step bit_unpack schema=instr
```

Existing profiles keep their previous encoding. The parser and verifier reject
duplicate feedback steps and incorrect placement rather than silently emitting
incompatible bytecode. Use the updated compiler plugin for these profiles; the
upstream v0.1.6-beta.1 plugin cannot read this extension.

For every instruction, the encoder initializes a 64-bit state from the function
key and the instruction's byte PC. Each encoded byte is XOR-masked with the
state's low byte. The next state combines a rotation, the feedback ciphertext,
and the current byte offset using wrapping arithmetic. Outer stream transforms
then run as before. The LLVM reader reverses those outer transforms first,
decodes one byte, and advances the same feedback state. Opcode bytes, varint
continuation bytes, and packed operands share that instruction's state. Padding
is encoded too; the runtime skips padding and resets at the next instruction.

The state resets from the destination PC on every dispatch, including branches,
loop backedges, and internal VM calls. It does not depend on an assumed linear
execution path. Two reader-state slots are allocated once on VM entry. There
are no feedback allocations on loop backedges and no global mutable state.
Constant-pool decoding is unchanged.

This removes independent decoding of individual code bytes using only key and
offset. It does not supply a secret, authenticate bytecode, stop whole-program
emulation, or prevent someone from observing and reproducing outputs. An
analyst who reconstructs the recurrence can decode each instruction. No claim
about independent reverse-engineering time follows from the mechanism alone.

Run pure encoder/profile tests with `cargo test -p amice-vm`. Windows smoke
tests include C/C++ feedback execution via `scripts/build_windows.ps1 -SmokeTest`.
For matching Android host LLVM and plugin:

```sh
python3 scripts/test_vm_feedback.py \
  --llvm /path/to/clang-r574158c \
  --plugin /path/to/target/release/libamice.so \
  --bundle /path/to/amice-android-ndk-r30-linux-x86_64 \
  --adb /path/to/adb --serial DEVICE
```

The executable regression compares native output with feedback VMs for call and
inline entry, module and function scope, and O0/O2. It covers conditional
branches, backedges, nested calls, recursion, pointer loads/stores, wide
constants, and constant-pool decoding. Android cases without a serial are
explicitly marked build-only. It never installs a Zygisk module.
