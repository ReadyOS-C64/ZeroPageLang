# Programming guide coverage

The public guide keeps build and run instructions on linked command pages.
Each chapter uses complete repository sources or labels code as excerpts.
For runnable examples, compare the published blocks with their source and
run the target program when its behavior is part of the lesson.

| Area | Current guide evidence | Sources for the next review |
| --- | --- | --- |
| Types, expressions, imports | Language and record chapters cover layout, effects, control, imported data, casts, optionals, and tagged unions | Scalar and control parity fixtures for carry, wrapping, inferred locals, and return paths |
| C64 I/O and assembly | Hardware and assembly chapters cover screen and color RAM, strings, keyboard, byte bindings, flattened fields, indirect access, preservation, and terminal vectors | Built-in smoke tests, branch diagnostics, and assembly binding tests |
| Memory placement and ABI | Memory and frames chapters cover PRG and raw entry, startup copy, reserved zero page, recursion, and mixed calls | Native lifecycle fixtures for restoration, stack limits, and zero-page allocation, plus explicit placement compile failures |
| Near and far storage | Arena and REU chapters cover byte allocation, pools, handles, raw DMA, rich records, and whole and range materialization | Allocation rejection fixtures and view type/count mismatch fixtures |
| DLLs | First DLL chapter shows complete named and typed disk call sites. Lifecycle chapter covers disk policies, ownership, graph rollback, state, banking, and sidecars | Registry rows, failed loads with existing ownership, and relocation tests |
| Application and validation | Tic-Tac-Toe case study, target tests, and map reading connect the language to a runnable application | Compare normal and hosted app behavior, and work through a reproducible size and timing comparison |

The next editorial pass should turn selected scalar, zero-page, stack, and
loader edge cases into reader-facing exercises with a clear prediction and
observable result. Verify the examples from a fresh clone using the command
pages. The original development checkout is shared with optimization work.
Use the separate public clone for guide edits.
