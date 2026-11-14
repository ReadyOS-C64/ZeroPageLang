/* Shared buffered C source for cc65 and Oscar64. Display logic is ordinary C;
 * only the terminal ROM jump uses compiler-specific inline-asm syntax.
 * Two screen matrices ($0400/$2400), a 1 KB ring ($2800), row-wise copy,
 * deferred page flip, nine-frame countdown, and RUN/STOP after release.
 * Compile/static inspection only: frame timing has not been validated.
 */
typedef unsigned char u8;
typedef unsigned int u16;

#define IO(address) (*(volatile u8 *)(address))
#define RAM(address) ((u8 *)(address))

static const u8 greeting[13] = {
    0x48, 0x05, 0x0c, 0x0c, 0x0f, 0x2c, 0x20,
    0x57, 0x0f, 0x12, 0x0c, 0x04, 0x21
};
static u8 head, cursor_row, pending;
/* Retain the CIA acknowledgement read in both compilers' optimized output. */
static volatile u8 irq_acknowledged;
static u8 screen_select = 0x17;
static u16 back_address = 0x2400;
static u8 frames_left = 10;

static u8 acknowledge_cia(void)
{
    /* Keep this read separate from the preceding write: cc65 -O otherwise
     * forwards the mask value despite the hardware's read/write semantics. */
    return IO(0xdc0du);
}

static void display_init(void)
{
    u16 offset;
    u8 color = IO(0x0286u);
    IO(0xd018u) = screen_select;
    /* Explicit C clear instead of the ZeroPage modules' KERNAL clear call. */
    for (offset = 0; offset < 1000; ++offset) {
        RAM(0x0400u)[offset] = 32;
        RAM(0xd800u)[offset] = color;
    }
    IO(0xdc0du) = 0x7f;
    irq_acknowledged = acknowledge_cia();
    IO(0xd01au) = 0;
    IO(0xd019u) = 0x0f;
    for (offset = 0; offset < 1024; ++offset)
        RAM(0x2800u)[offset] = 32;
}

static void wait_frame(void)
{
    while ((IO(0xd011u) & 0x80) != 0) {}
    while ((IO(0xd011u) & 0x80) == 0) {}
}

static u8 frame(void)
{
    if (pending) {
        screen_select ^= 0x80;
        IO(0xd018u) = screen_select;
        back_address ^= 0x2000u;
        pending = 0;
    }
    --frames_left;
    if (frames_left == 0) {
        frames_left = 9;
        return 1;
    }
    return 0;
}

static void print_line(void)
{
    u8 column, physical_row;
    u16 offset;
    if (cursor_row == 25) {
        offset = (u16)head * 40u;
        for (column = 0; column < 40; ++column)
            RAM(0x2800u)[offset++] = 32;
        ++head;
        if (head == 25) head = 0;
        cursor_row = 24;
    }
    physical_row = head + cursor_row;
    if (physical_row >= 25) physical_row -= 25;
    offset = (u16)physical_row * 40u;
    for (column = 0; column < 13; ++column)
        RAM(0x2800u)[offset++] = greeting[column];
    ++cursor_row;
}

static void copy_page(void)
{
    u8 row, column, source_row = head;
    u8 *target = RAM(back_address);
    for (row = 0; row < 25; ++row) {
        const u8 *source = RAM(0x2800u + (u16)source_row * 40u);
        for (column = 0; column < 40; ++column)
            target[column] = source[column];
        target += 40;
        ++source_row;
        if (source_row == 25) source_row = 0;
    }
    pending = 1;
}

static u8 stop_requested(void)
{
    u8 rows;
    IO(0xdc00u) = 0x7f;
    rows = IO(0xdc01u);
    IO(0xdc00u) = 0xff;
    return (rows & 0x80) == 0;
}

int main(void)
{
    display_init();
    for (;;) {
        wait_frame();
        if (frame()) {
            print_line();
            copy_page();
        }
        if (stop_requested()) break;
    }
    while (stop_requested()) {}
    /* Same terminal ROM jump as the ZeroPage module drivers. An integer-cast
     * function-pointer call crashes this Oscar64 version's optimizer. */
#ifdef __CC65__
    __asm__("jmp $fe66");
#else
    __asm { jmp $fe66 }
#endif
    for (;;) {}
    return 0;
}
