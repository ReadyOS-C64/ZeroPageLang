# Programming guide coverage

The public guide keeps build and run instructions on linked command pages.
Each chapter uses complete repository sources or labels code as excerpts.
For runnable examples, compare the published blocks with their source and
run the target program when its behavior is part of the lesson.

| Area | Current guide evidence | Sources for the next review |
| --- | --- | --- |
| Types, expressions, imports | Language and record chapters cover layout, effects, control, imported data, casts, optionals, and tagged unions. Worked examples cover carry and inference, early returns, fixed array literals, aliasing through an indexed pointer, and exact/list/range dispatch. | Scalar runtime versus compile-time evaluation and copy behavior through compound pointer paths |
| C64 I/O and assembly | Hardware and assembly chapters cover screen and color RAM, screen-code versus PETSCII bytes, strings, keyboard and timing, byte bindings, flattened fields, indirect access, preservation, terminal vectors, branch distance, word data exchange, and ROM result capture. | An address/length interop example that reads a firmware status flag, and a practical choice between polling and blocking input |
| Memory placement and ABI | Memory and frames chapters cover PRG and raw entry, startup copy, zero-page ownership, recursion, mixed calls, and exact-fit stack reservations. The nested trace explains link storage, live frame bytes verified in VICE, and A/X return cleanup. Exercises measure both frame policies, repair an illegal banked table read, and diagnose an overlapping REU layout. | Trace an ordinary static aggregate return and an external routine's ABI separately |
| Near and far storage | Arena and REU chapters cover byte allocation, pool sizing, handles, raw DMA, rich records, whole and range materialization, and type/count errors. The working-set program compares direct updates against materialization in VICE. A 40-sector map exercise derives both capacities and tests an invalid start and a one-byte shortage. The score application combines near allocation, far records, and the DLL cache. | Teach immutable asset loading and choosing separate tables for data with different access patterns |
| DLLs | Complete named and typed disk calls lead into loading policies, ownership, saved state, banking, relocation, and graph rollback. The lifecycle chapter verifies a packaged disk file byte-for-byte, shows two windows staying active independently, and traces direct versus loader calls and state restoration through unload and reload. The score exercise demonstrates sidecar mismatch and missing-disk recovery. | Cover export shapes and compare the initialization contracts for embedded, preload, and on-demand rows in one exercise |
| Application and validation | Tic-Tac-Toe case study compares standalone and hosted image contracts, input and rendering paths, and ReadyOS transfer vectors. A fixed workload compares the default and KERNAL scratch policies using measured PRG bytes and host cycles. | Check hosted navigation under its real host and connect hardware-specific VICE checks to the application |

The REU chapter compares direct far updates with materialization using the
same workload, VICE stopwatch readings, DMA counts, and RAM cost. The ABI
chapter compares both stack budgets on a nested host fixture. The DLL
lifecycle chapter verifies a D64 entry byte-for-byte against the producer
artifact and explains why the caller and disk need to come from the same build.

Continue to turn runtime contracts into reader-facing exercises with a clear
prediction and observable result. Verify the examples from a fresh clone using
the command pages. The original development checkout is shared with optimization
work. Use the separate public clone for guide edits.
