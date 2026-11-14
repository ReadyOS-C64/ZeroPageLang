# Programming guide coverage

The public guide keeps build and run instructions on linked command pages.
Each chapter uses complete repository sources or labels code as excerpts.
For runnable examples, compare the published blocks with their source and
run the target program when its behavior is part of the lesson.

| Area | Current guide evidence | Sources for the next review |
| --- | --- | --- |
| Types, expressions, imports | Language and record chapters cover layout, effects, control, imported data, casts, optionals, and tagged unions. Worked examples cover carry and inference, early returns, fixed array literals, aliasing through an indexed pointer, and exact/list/range dispatch. | Scalar runtime versus compile-time evaluation and copy behavior through compound pointer paths |
| C64 I/O and assembly | Hardware and assembly chapters cover screen and color RAM, screen-code versus PETSCII bytes, strings, keyboard and timing, byte bindings, flattened fields, indirect access, preservation, terminal vectors, branch distance, word data exchange, and ROM result capture. | An address/length interop example that reads a firmware status flag, and a practical choice between polling and blocking input |
| Memory placement and ABI | Memory and frames chapters cover PRG and raw entry, caller obligations, startup copy, reserved zero page, recursion, mixed calls, and the smallest passing reservation for a nested stack fixture. A map exercise distinguishes borrowed bytes from explicit reservations. The score exercise diagnoses an overlapping REU layout. | Stack-depth analysis, reentrancy, and debugging a placement that crosses a bank boundary |
| Near and far storage | Arena and REU chapters cover byte allocation, pool sizing, handles, raw DMA, rich records, whole and range materialization, type/count mismatch diagnostics, and a working-set program with repeated edits and arena reuse. The score application combines near allocation, far records, and the DLL cache. | Compare measurements for the same data update with and without materialization |
| DLLs | First DLL chapter shows complete named and typed disk call sites. Lifecycle chapter covers disk policies, ownership, state, banking and console output under KERNAL, registry rows, byte-level relocation, rollback preserving an existing owner, and a worked two-window memory plan. The score exercise builds a producer and caller and recovers from a signature mismatch or missing disk entry. | Disk payload corruption or staging-size diagnosis, and two separately active windows observed at runtime |
| Application and validation | Tic-Tac-Toe case study compares standalone and hosted image contracts, input and rendering paths, and ReadyOS transfer vectors. A fixed workload compares the default and KERNAL scratch policies using measured PRG bytes and host cycles. | Check hosted navigation under its real host and connect hardware-specific VICE checks to the application |

Continue to turn runtime contracts into reader-facing exercises with a clear
prediction and observable result. Verify the examples from a fresh clone using
the command pages. The original development checkout is shared with optimization
work. Use the separate public clone for guide edits.
