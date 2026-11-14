# Programming guide coverage

The public guide keeps build and run instructions on linked command pages.
Each chapter uses complete repository sources or labels code as excerpts.
For runnable examples, compare the published blocks with their source and
run the target program when its behavior is part of the lesson.

| Area | Current guide evidence | Sources for the next review |
| --- | --- | --- |
| Types, expressions, imports | Language and record chapters cover layout, effects, control, imported data, casts, optionals, and tagged unions. A runnable width example demonstrates carry, overflow, masks, and inference. | Return paths, array initializer variants, and restrictions around pointer-derived expressions |
| C64 I/O and assembly | Hardware and assembly chapters cover screen and color RAM, strings, keyboard, byte bindings, flattened fields, indirect access, preservation, terminal vectors, and expanding an out-of-range branch. | Built-in smoke tests, word data exchange across an assembly block, and ROM result capture |
| Memory placement and ABI | Memory and frames chapters cover PRG and raw entry, startup copy, reserved zero page, recursion, mixed calls, and the smallest passing reservation for a nested stack fixture. A map exercise distinguishes borrowed bytes from explicit reservations. | Raw entry machine assumptions, a full memory plan with bank conflicts, and reentrancy |
| Near and far storage | Arena and REU chapters cover byte allocation, pool sizing, handles, raw DMA, rich records, whole and range materialization, and type/count mismatch diagnostics. | An end-to-end working set with multiple edits, reset/reuse, and a caller-selected start |
| DLLs | First DLL chapter shows complete named and typed disk call sites. Lifecycle chapter covers disk policies, ownership, graph rollback, state, banking, registry rows, and byte-level relocation. | A graph failure after an existing owner has loaded a shared dependency, and a worked multi-window layout |
| Application and validation | Tic-Tac-Toe case study, target tests, and map reading connect the language to a runnable application. A fixed workload compares the default and KERNAL scratch policies using measured PRG bytes and host cycles. | Compare normal and hosted app behavior and connect hardware-specific VICE checks to the application |

Continue to turn runtime contracts into reader-facing exercises with a clear
prediction and observable result. Verify the examples from a fresh clone using
the command pages. The original development checkout is shared with optimization
work. Use the separate public clone for guide edits.
