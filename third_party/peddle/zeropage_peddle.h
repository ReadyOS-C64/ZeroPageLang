#ifndef ZEROPAGE_PEDDLE_H
#define ZEROPAGE_PEDDLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZeroPagePeddle ZeroPagePeddle;

typedef struct ZeroPagePeddleRegs {
    uint16_t pc;
    uint16_t pc0;
    uint8_t sp;
    uint8_t a;
    uint8_t x;
    uint8_t y;
    uint8_t p;
    uint64_t cycles;
    uint64_t instructions;
} ZeroPagePeddleRegs;

ZeroPagePeddle *zeropage_peddle_create(void);
void zeropage_peddle_destroy(ZeroPagePeddle *machine);
void zeropage_peddle_reset(ZeroPagePeddle *machine);
void zeropage_peddle_clear_memory(ZeroPagePeddle *machine);
void zeropage_peddle_load(ZeroPagePeddle *machine, uint16_t address, const uint8_t *bytes, size_t len);
uint8_t zeropage_peddle_read(const ZeroPagePeddle *machine, uint16_t address);
uint8_t zeropage_peddle_read_reu(const ZeroPagePeddle *machine, uint32_t address);
void zeropage_peddle_write(ZeroPagePeddle *machine, uint16_t address, uint8_t value);
void zeropage_peddle_set_pc(ZeroPagePeddle *machine, uint16_t pc);
void zeropage_peddle_set_sp(ZeroPagePeddle *machine, uint8_t sp);
void zeropage_peddle_set_a(ZeroPagePeddle *machine, uint8_t value);
void zeropage_peddle_set_x(ZeroPagePeddle *machine, uint8_t value);
void zeropage_peddle_set_y(ZeroPagePeddle *machine, uint8_t value);
void zeropage_peddle_set_p(ZeroPagePeddle *machine, uint8_t value);
void zeropage_peddle_step_instruction(ZeroPagePeddle *machine);
/* 0: reached top-level RTS, 1: BRK, 2: budget exhausted. Does not execute RTS. */
int zeropage_peddle_run_until_rts(ZeroPagePeddle *machine, uint8_t entry_sp, uint32_t limit);
ZeroPagePeddleRegs zeropage_peddle_regs(const ZeroPagePeddle *machine);
/* Measure the highest byte written by the CPU, relative to the watched start. */
void zeropage_peddle_watch_writes(ZeroPagePeddle *machine, uint16_t start, uint16_t size);
uint16_t zeropage_peddle_write_high_water(const ZeroPagePeddle *machine);

#ifdef __cplusplus
}
#endif

#endif
