# Programming guide coverage

The public guide keeps build and run instructions on linked command pages.
Each chapter uses complete repository sources or labels code as excerpts.
For runnable examples, compare the published blocks with their source and
run the target program when its behavior is part of the lesson.

| Area | Current guide evidence | Sources for the next review |
| --- | --- | --- |
| Types, expressions, imports | Language and record chapters cover layout, effects, control, imported data, casts, optionals, and tagged unions. Worked examples cover carry and inference, early returns, fixed array literals, and aliasing through an indexed pointer. | Scalar runtime versus compile-time evaluation, switch ranges and dispatch costs, copy behavior through compound pointer paths |
| C64 I/O and assembly | Hardware and assembly chapters cover screen and color RAM, strings, keyboard, byte bindings, flattened fields, indirect access, preservation, terminal vectors, branch distance, word data exchange, and ROM result capture. | Screen versus PETSCII encoding, keyboard and timing behavior, and an address/length interop example that reads a firmware status flag |
| Memory placement and ABI | Memory and frames chapters cover PRG and raw entry, startup copy, reserved zero page, recursion, mixed calls, and the smallest passing reservation for a nested stack fixture. A map exercise distinguishes borrowed bytes from explicit reservations. | Raw entry machine assumptions, a deliberate overlap and its repair, stack-depth analysis, and reentrancy |
| Near and far storage | Arena and REU chapters cover byte allocation, pool sizing, handles, raw DMA, rich records, whole and range materialization, type/count mismatch diagnostics, and a working-set program with repeated edits and arena reuse. | A single memory plan combining near allocation, application REU data, and loader cache reservations |
| DLLs | First DLL chapter shows complete named and typed disk call sites. Lifecycle chapter covers disk policies, ownership, state, banking, registry rows, byte-level relocation, rollback preserving an existing owner, and a worked two-window memory plan. | Producer-side ABI compatibility failures, KERNAL-bank console trampoline and tradeoffs, and a standalone source-to-disk recovery exercise |
| Application and validation | Tic-Tac-Toe case study compares standalone and hosted image contracts, input and rendering paths, and ReadyOS transfer vectors. A fixed workload compares the default and KERNAL scratch policies using measured PRG bytes and host cycles. | Check hosted navigation under its real host and connect hardware-specific VICE checks to the application |

Continue to turn runtime contracts into reader-facing exercises with a clear
prediction and observable result. Verify the examples from a fresh clone using
the command pages. The original development checkout is shared with optimization
work. Use the separate public clone for guide edits.
