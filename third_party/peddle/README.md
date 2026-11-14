# Peddle

This directory vendors the Peddle MOS 65xx CPU emulator for ZeroPage host-side
emulation tests.

- Upstream: https://github.com/dirkwhoffmann/Peddle
- Pinned commit: `c23e34a7e6516b284750b8c7caaa8c41948a407a`
- License: MIT, preserved in `LICENSE`

ZeroPage links this dependency only into the host-emulation test runner. The main
`zp64c` compiler and the normal Zig unit-test binary remain pure Zig.

Peddle was chosen for the first host runner because it supports 6502/6507/6510,
offers instruction and cycle stepping, and was designed for C64-class emulation.

The ZeroPage C wrapper also exposes a bounded `run_until_rts` for fast native
function equivalence matrices. It uses the same microcycle stepper, runs nested
calls normally, and stops before the top-level RTS with the entry stack pointer.
BRK and exhausted instruction budgets have distinct statuses. The hook-aware
host fixture runner continues to step individual instructions.
