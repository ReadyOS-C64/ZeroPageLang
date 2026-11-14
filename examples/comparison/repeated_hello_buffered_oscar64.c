/* Oscar64-specific alternative; the portable buffered C version is retained.
 * Native VIC/CIA definitions, screen-code strings and memory intrinsics.
 * Compile/static inspection only; frame timing has not been validated.
 */
#include <c64/vic.h>
#include <c64/cia.h>
#include <string.h>

typedef char ScreenRow[40];
ScreenRow * const front = (ScreenRow *)0x0400;
ScreenRow * const ring = (ScreenRow *)0x2800;
ScreenRow * back = (ScreenRow *)0x2400;

static const char greeting[] = s"Hello, World!";
static byte head, cursor_row;
static bool pending;
static volatile byte irq_acknowledged;

static bool stop_requested(void)
{
    cia1.pra = 0x7f;
    byte rows = cia1.prb;
    cia1.pra = 0xff;
    return !(rows & 0x80);
}

static void print_line(void)
{
    if (cursor_row == 25) {
        memset(ring[head], 32, sizeof(ScreenRow));
        if (++head == 25) head = 0;
        cursor_row = 24;
    }
    byte physical_row = head + cursor_row;
    if (physical_row >= 25) physical_row -= 25;
    memcpy(ring[physical_row], greeting, sizeof(greeting) - 1);
    ++cursor_row;
}

static void copy_page(void)
{
    /* A rotated ring is two contiguous spans. Let Oscar64 lower memcpy. */
    byte tail_rows = 25 - head;
    memcpy(back, ring + head, (word)tail_rows * sizeof(ScreenRow));
    memcpy(back + tail_rows, ring, (word)head * sizeof(ScreenRow));
    pending = true;
}

int main(void)
{
    vic_setmode(VICM_TEXT, (char *)front, (char *)0x1800);
    memset(front, 32, 1000);
    memset((char *)0xd800, *(volatile byte *)0x0286, 1000);
    cia1.icr = 0x7f;
    irq_acknowledged = cia1.icr;
    vic.intr_enable = 0;
    vic.intr_ctrl = VIC_INTR_RST | VIC_INTR_MBC | VIC_INTR_MMC | VIC_INTR_ILP;
    memset(ring, 32, 1024);

    byte frames_left = 10;
    for (;;) {
        vic_waitFrame();
        if (pending) {
            vic.memptr ^= 0x80;
            back = (ScreenRow *)((word)back ^ 0x2000);
            pending = false;
        }
        if (--frames_left == 0) {
            frames_left = 9;
            print_line();
            copy_page();
        }
        if (stop_requested()) break;
    }
    while (stop_requested()) {}
    __asm { jmp $fe66 }
    for (;;) {}
    return 0;
}
