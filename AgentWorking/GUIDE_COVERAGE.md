# Programming guide coverage

The public guide keeps build and run instructions on linked command pages.
Each chapter uses complete repository sources or labels code as excerpts.
For runnable examples, compare the published blocks with their source and
run the target program when its behavior is part of the lesson.

The tutorial has twenty chapters in three parts. The reader starts with a
PRG, byte and word arithmetic, and an interactive sector survey. Local imports
and typed input events lead into screen access, inline assembly, and a firmware
call with string operands and a carry result. The memory
part covers near arenas, banked placements, software-stack frames, fixed-block
pools, and paged REU storage. The final part introduces typed and named DLL
calls, builds two producers that share one execution window, compares load
policies and graph ownership, saves and restores module state, and combines
a scoring DLL with a separate REU arena. The game
chapter follows a complete Tic-Tac-Toe round from input through rules and
rendering, then changes the winning border without changing the moves. The
VICE monitor lesson traces the cache behavior. Use chapter links for the learning
path and guide links for reference. Demonstrate results through screen output
or target memory. Keep compiler test hooks in compiler testing material.

Chapter pages use the tutorial or guide order for their navigation. The
desktop sidebar marks the current chapter, and the mobile chapter picker
uses the same links. Keep section anchors in the separate control below
the title so they remain available without competing with chapter links.

The shared-window exercise was checked with a 256 KiB REU in VICE. Its trace
hits two disk loader paths followed by three activations in Terrain, FixedMath,
Terrain order. A disk missing FixedMath takes the red-border failure path.
The REU exercise runs with and without the scratch reset. The pool exercise
checks the original two-block layout and the three-block variation. VICE also
checks all four survey input events, the banked lookup, recursive and nested
calls, the exact-fit frame budget and the one-byte-short trap, and both DLL
state policies. The combined score disk runs with a 256 KiB REU. The compiler
rejects a direct resident read of hidden data and an overlapping score arena.

The firmware chapter checks the string copy and indirect read in VICE, then
boots both the present and missing tile disks. The game chapter checks the
first move, repeated occupied-cell move, and top-row win from the published
disk and a fresh build. The modified build keeps the same result and sets a
green winning border. The hosted game discussion remains in the guide.

The DLL policy chapter uses the published commands to build three policy
disks and two graph disks. VICE checks the initial registry state, the
successful Boolean false result, the missing on-demand payload, and both
graph outcomes. With Terrain absent, its acquire fails while the existing
FixedMath owner still receives its bonus. The final release makes the
manual binding unavailable.

The enemy-roster lesson processes 200 twelve-byte records in groups of 20.
VICE with a 128 KiB REU confirms the first and last records and the damage
count. The trace between initialization and display confirms ten transfers
in each direction. A 239-byte scratch reservation exercises batch exhaustion.

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
