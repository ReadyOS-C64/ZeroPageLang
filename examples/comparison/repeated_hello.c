/* Shared cc65/Oscar64 port of the ZeroPage repeated-greeting example.
 * No inline assembly, ROM console, printf, back screen, or ring buffer.
 * Console operations mirror ZeroPage's existing direct-screen runtime.
 */
typedef unsigned char u8;
typedef unsigned int u16;

#define RASTER_CONTROL (*(volatile u8 *)0xd011)
#define RAM(address) ((u8 *)(address))
#define ROWS(base, shift) \
    (u8)(((base) + 40u * 0u) >> (shift)), \
    (u8)(((base) + 40u * 1u) >> (shift)), \
    (u8)(((base) + 40u * 2u) >> (shift)), \
    (u8)(((base) + 40u * 3u) >> (shift)), \
    (u8)(((base) + 40u * 4u) >> (shift)), \
    (u8)(((base) + 40u * 5u) >> (shift)), \
    (u8)(((base) + 40u * 6u) >> (shift)), \
    (u8)(((base) + 40u * 7u) >> (shift)), \
    (u8)(((base) + 40u * 8u) >> (shift)), \
    (u8)(((base) + 40u * 9u) >> (shift)), \
    (u8)(((base) + 40u * 10u) >> (shift)), \
    (u8)(((base) + 40u * 11u) >> (shift)), \
    (u8)(((base) + 40u * 12u) >> (shift)), \
    (u8)(((base) + 40u * 13u) >> (shift)), \
    (u8)(((base) + 40u * 14u) >> (shift)), \
    (u8)(((base) + 40u * 15u) >> (shift)), \
    (u8)(((base) + 40u * 16u) >> (shift)), \
    (u8)(((base) + 40u * 17u) >> (shift)), \
    (u8)(((base) + 40u * 18u) >> (shift)), \
    (u8)(((base) + 40u * 19u) >> (shift)), \
    (u8)(((base) + 40u * 20u) >> (shift)), \
    (u8)(((base) + 40u * 21u) >> (shift)), \
    (u8)(((base) + 40u * 22u) >> (shift)), \
    (u8)(((base) + 40u * 23u) >> (shift)), \
    (u8)(((base) + 40u * 24u) >> (shift))

static const u8 screen_lo[25] = { ROWS(0x0400u, 0) };
static const u8 screen_hi[25] = { ROWS(0x0400u, 8) };
static const u8 color_lo[25] = { ROWS(0xd800u, 0) };
static const u8 color_hi[25] = { ROWS(0xd800u, 8) };
/* Numeric PETSCII avoids compiler-specific source-character mappings. */
static const u8 greeting[13] = {
    0x48, 0x45, 0x4c, 0x4c, 0x4f, 0x2c, 0x20,
    0x57, 0x4f, 0x52, 0x4c, 0x44, 0x21
};
static u8 cursor_x, cursor_y;

static void console_clear(void)
{
    u8 x = 0;
    do {
        RAM(0x0400u)[x] = 32;
        RAM(0x0500u)[x] = 32;
        RAM(0x0600u)[x] = 32;
        RAM(0x06e8u)[x] = 32;
        ++x;
    } while (x != 0);
    cursor_x = 0;
    cursor_y = 0;
}

static void console_scroll(void)
{
    u8 x = 0;
    do {
        RAM(0x0400u)[x] = RAM(0x0428u)[x];
        RAM(0x0500u)[x] = RAM(0x0528u)[x];
        RAM(0x0600u)[x] = RAM(0x0628u)[x];
        RAM(0xd800u)[x] = RAM(0xd828u)[x];
        RAM(0xd900u)[x] = RAM(0xd928u)[x];
        RAM(0xda00u)[x] = RAM(0xda28u)[x];
        ++x;
    } while (x != 0);
    for (x = 0; x < 192; ++x) {
        RAM(0x0700u)[x] = RAM(0x0728u)[x];
        RAM(0xdb00u)[x] = RAM(0xdb28u)[x];
    }
    for (x = 0; x < 40; ++x) RAM(0x07c0u)[x] = 32;
    for (x = 0; x < 40; ++x) RAM(0xdbc0u)[x] = 1;
}

static void console_newline(void)
{
    cursor_x = 0;
    ++cursor_y;
    if (cursor_y >= 25) {
        cursor_y = 24;
        console_scroll();
    }
}

static void console_putchar(u8 ch)
{
    u8 *ptr = (u8 *)((u16)screen_lo[cursor_y] |
                     ((u16)screen_hi[cursor_y] << 8));
    ptr[cursor_x] = ch;
    ptr = (u8 *)((u16)color_lo[cursor_y] |
                ((u16)color_hi[cursor_y] << 8));
    ptr[cursor_x] = 1;
    ++cursor_x;
    if (cursor_x >= 40) console_newline();
}

static u8 petscii_to_screen(u8 ch)
{
    if (ch >= 65 && ch < 91) return ch - 64;
    if (ch >= 97 && ch < 123) return ch - 96;
    return ch;
}

static void console_puts(const u8 *text, u8 length)
{
    u8 i;
    for (i = 0; i < length; ++i) {
        u8 ch = text[i];
        if (ch == 10 || ch == 13) console_newline();
        else console_putchar(petscii_to_screen(ch));
    }
}

int main(void)
{
    u8 frames_left = 10;
    u8 first_line = 1;
    /* cc65's stock startup selects lowercase; match the BASIC/ZeroPage font. */
    (*(volatile u8 *)0xd018u) = 0x14;
    console_clear();
    for (;;) {
        while ((RASTER_CONTROL & 0x80) != 0) {}
        while ((RASTER_CONTROL & 0x80) == 0) {}
        --frames_left;
        if (frames_left == 0) {
            frames_left = 9;
            if (!first_line) console_newline();
            console_puts(greeting, 13);
            first_line = 0;
        }
    }
    return 0;
}
