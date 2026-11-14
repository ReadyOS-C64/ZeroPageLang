# Programming guide coverage

The public guide keeps build and run instructions on linked command pages.
Each chapter uses complete repository sources or labels code as excerpts.
For runnable examples, compare the published blocks with their source and
run the target program when its behavior is part of the lesson.

The tutorial now has its own reading sequence from the first PRG through a
sector survey, screen and device access, scratch storage, REU pages, disk DLLs,
and diagnosis. Use chapter links for the learning path and guide links for
reference. In the programming chapters, demonstrate the result through screen
output or target memory. Keep compiler test hooks in compiler testing material.

Chapter pages use the tutorial or guide order for their navigation. The
desktop sidebar marks the current chapter, and the mobile chapter picker
uses the same links. Keep section anchors in the separate control below
the title so they remain available without competing with chapter links.

| Area | Current guide evidence | Sources for the next review |
| --- | --- | --- |
| Types, expressions, imports | Language and record chapters cover layout, effects, control, imported data, casts, optionals, and tagged unions. Worked examples cover carry and inference, early returns, fixed array literals, exact/list/range dispatch, and copied records with shared and subsequently rebound pointers. A layout example distinguishes compile-time queries from runtime functions. | Scalar, composite, pointer, control-flow, and layout parity fixtures |
| C64 I/O and assembly | Hardware and assembly chapters cover screen and color RAM, screen-code versus PETSCII bytes, strings, keyboard and timing, byte bindings, flattened fields, indirect access, preservation, terminal vectors, branch distance, word data exchange, and ROM results. VICE exercises a polling loop and a checked KERNAL LOAD with string address and length operands. | Keyboard, strings, inline assembly, and hardware integration tests |
| Memory placement and ABI | Memory and frames chapters cover PRG and raw entry, startup copy, zero-page ownership, recursion, mixed calls, and exact-fit stack reservations. The nested trace explains link storage, live frame bytes verified in VICE, and A/X return cleanup. A static record example follows parameter cells and return storage across two calls. | Raw entry, banked placement, frame layout, overflow, and lifecycle tests |
| Near and far storage | Arena and REU chapters cover byte allocation, pool sizing, handles, raw DMA, rich records, whole and range materialization, and type/count errors. Examples measure DMA costs, size a 40-sector map, guard transfer length, and give artwork and mutable tile state separate transfer paths. The original high-address DMA demo is linked alongside the newer transfer examples. | Verify the strongest safe advice for handling distinct REU capacities across common emulator and physical configurations |
| DLLs | Complete named and typed disk calls lead into loading policies, ownership, saved state, banking, relocation, and graph rollback. The lifecycle chapter verifies D64 bytes, checks independent active windows and state restoration, and compares preload, on-demand, and manual loading. The reusable producer exercise builds FixedMath once and boots two callers that use the same disk bytes with different loading policies. | Cross-check producer and caller window restrictions for differently sized windows and link the tested cases from the reference |
| Application and validation | Tic-Tac-Toe case study compares standalone and hosted image contracts, input and rendering paths, and ReadyOS transfer vectors. A fixed workload compares the default and KERNAL scratch policies using measured PRG bytes and host cycles. | Check hosted navigation under its real host and connect hardware-specific VICE checks to the application |

The current edition also exercises the REU layouts at 128 and 256 KiB in
VICE, checks firmware carry on a present and missing disk file, and compares
default DLL window validation with explicit assignment to a different
address and larger window. These tests cover the command paths shown in the
guide. Physical REU configurations and hosted ReadyOS navigation have not
been exercised by this documentation pass.

The REU chapter compares direct far updates with materialization using the
same workload, VICE stopwatch readings, DMA counts, and RAM cost. The ABI
chapter compares both stack budgets on a nested host fixture. The DLL
lifecycle chapter verifies a D64 entry byte-for-byte against the producer
artifact and explains why the caller and disk need to come from the same build.

## Publication audit

- All 33 generated HTML pages were checked for local links, repository file
  links, and unique section IDs. The setup and linked command pages contain
  terminal blocks. The reading pages contain source examples and command links.
- The two complete disk-call mains match their source files. Both produced
  identical PRG and disk-payload bytes, and both booted in VICE. A disk with no
  payload displayed the documented load failure.
- The original REU materialization, rich record, and range failure lessons are
  represented in the current chapter. The original high-address copy demo is
  linked. The chapter also explains all raw transfer forms, capacity and
  bounds, far allocation, whole and range views, and application working sets.
- All 28 sources under `docs/tutorial-examples/` compiled. The full Peddle suite
  passed 203 language examples, 566 expected compile failures, 9 expected
  runtime failures, and 109 smoke cases. The end-to-end build checked all 96
  small demos.
- The VICE checks above cover the documented emulator paths. They do not
  constitute validation of every hardware REU or of ReadyOS launcher behavior.
  The guide labels the ReadyOS host assumptions and current implementation limits.

Future guide edits should continue to turn runtime contracts into exercises
with a prediction and observable result. The original development checkout is
shared with optimization work. Use the separate public clone for guide edits.
