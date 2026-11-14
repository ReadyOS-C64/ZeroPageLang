#include "zeropage_peddle.h"

#include "Peddle/Peddle.h"

#include <algorithm>
#include <cstring>
#include <vector>

static constexpr uint32_t ZeroPageReuSize = 16u * 1024u * 1024u;
static constexpr uint16_t ReuRegisterBase = 0xdf00;
static constexpr uint16_t ReuRegisterLast = 0xdf0a;

class ZeroPagePeddleMachine : public peddle::Peddle {
public:
    uint8_t memory[65536];
    std::vector<uint8_t> reu;
    uint8_t reu_regs[11];
    uint8_t reu_status;
    uint64_t instructions;
    uint8_t cia_timer;
    uint8_t raster_toggle;
    uint16_t watched_start = 0;
    uint32_t watched_end = 0;
    uint16_t watched_bytes_written = 0;

    ZeroPagePeddleMachine()
        : reu(ZeroPageReuSize)
    {
        setModel(peddle::MOS_6510);
        clearMemory();
        instructions = 0;
        cia_timer = 0;
        raster_toggle = 0;
        resetCpu();
    }

    void clearMemory()
    {
        std::memset(memory, 0, sizeof(memory));
        std::fill(reu.begin(), reu.end(), 0);
        resetReuRegisters();
    }

    void resetReuRegisters()
    {
        std::memset(reu_regs, 0, sizeof(reu_regs));
        reu_status = 0x10;
        reu_regs[0] = reu_status;
        reu_regs[1] = 0x10;
        reu_regs[6] = 0xf8;
        reu_regs[7] = 0xff;
        reu_regs[8] = 0xff;
        reu_regs[9] = 0x1f;
        reu_regs[10] = 0x3f;
    }

    void resetCpu()
    {
        reset();
        reg.sp = 0xff;
        instructions = 0;
        cia_timer = 0;
        raster_toggle = 0;
        resetReuRegisters();
    }

    void setPc(uint16_t pc)
    {
        reg.pc = pc;
        reg.pc0 = pc;
        next = peddle::fetch;
    }

    void stepInstruction()
    {
        // Peddle leaves the clock to its host. Advance it once per microcycle,
        // including idle/page-crossing cycles, rather than once per instruction.
        do {
            execute();
            clock += 1;
        } while (!inFetchPhase());
        instructions += 1;
    }

protected:
    peddle::u8 read(peddle::u16 addr) override
    {
        if (addr >= ReuRegisterBase && addr <= ReuRegisterLast) {
            return readReuRegister(addr);
        }
        if (addr == 0xdc04) {
            cia_timer = static_cast<uint8_t>(cia_timer + 1);
            return cia_timer;
        }
        if (addr == 0xd012) {
            raster_toggle ^= 1;
            return raster_toggle;
        }
        return memory[addr];
    }

    void write(peddle::u16 addr, peddle::u8 val) override
    {
        if (addr >= ReuRegisterBase && addr <= ReuRegisterLast) {
            writeReuRegister(addr, val);
            return;
        }
        memory[addr] = val;
        if (addr >= watched_start && addr < watched_end) {
            watched_bytes_written = std::max(
                watched_bytes_written, static_cast<uint16_t>(addr - watched_start + 1));
        }
    }

    peddle::u8 readDasm(peddle::u16 addr) const override
    {
        if (addr >= ReuRegisterBase && addr <= ReuRegisterLast) {
            return reu_regs[addr - ReuRegisterBase];
        }
        return memory[addr];
    }

public:
    uint8_t readMemory(uint16_t addr) const
    {
        if (addr >= ReuRegisterBase && addr <= ReuRegisterLast) {
            return reu_regs[addr - ReuRegisterBase];
        }
        return memory[addr];
    }

    void writeMemory(uint16_t addr, uint8_t val)
    {
        if (addr >= ReuRegisterBase && addr <= ReuRegisterLast) {
            writeReuRegister(addr, val);
            return;
        }
        memory[addr] = val;
    }

private:
    uint8_t readReuRegister(uint16_t addr)
    {
        const auto index = static_cast<size_t>(addr - ReuRegisterBase);
        if (index == 0) {
            const uint8_t value = reu_status;
            reu_status &= static_cast<uint8_t>(~0xe0);
            reu_regs[0] = reu_status;
            return value;
        }
        return reu_regs[index];
    }

    void writeReuRegister(uint16_t addr, uint8_t val)
    {
        const auto index = static_cast<size_t>(addr - ReuRegisterBase);
        reu_regs[index] = val;
        memory[addr] = val;
        if (index == 1 && (val & 0x80) != 0) {
            executeReuCommand(val);
        }
    }

    void executeReuCommand(uint8_t command)
    {
        const uint8_t transfer_type = command & 0x03;
        uint16_t c64_addr = static_cast<uint16_t>(reu_regs[2] | (static_cast<uint16_t>(reu_regs[3]) << 8));
        uint32_t reu_addr = static_cast<uint32_t>(reu_regs[4]) |
            (static_cast<uint32_t>(reu_regs[5]) << 8) |
            (static_cast<uint32_t>(reu_regs[6]) << 16);
        uint32_t len = static_cast<uint32_t>(reu_regs[7]) | (static_cast<uint32_t>(reu_regs[8]) << 8);
        if (len == 0) len = 65536;
        const bool fix_c64 = (reu_regs[10] & 0x80) != 0;
        const bool fix_reu = (reu_regs[10] & 0x40) != 0;
        bool verify_fault = false;

        for (uint32_t i = 0; i < len; i++) {
            const uint16_t caddr = fix_c64 ? c64_addr : static_cast<uint16_t>(c64_addr + i);
            const uint32_t raddr = fix_reu ? reu_addr : reu_addr + i;
            if (raddr >= reu.size()) break;
            switch (transfer_type) {
                case 0: // C64 -> REU
                    reu[raddr] = memory[caddr];
                    break;
                case 1: // REU -> C64
                    memory[caddr] = reu[raddr];
                    break;
                case 2: { // swap
                    const uint8_t tmp = memory[caddr];
                    memory[caddr] = reu[raddr];
                    reu[raddr] = tmp;
                    break;
                }
                case 3: // verify/compare
                    if (memory[caddr] != reu[raddr]) {
                        verify_fault = true;
                        i = len;
                    }
                    break;
            }
        }

        reu_status = static_cast<uint8_t>(0x50 | (verify_fault ? 0x20 : 0x00));
        reu_regs[0] = reu_status;
    }
};

struct ZeroPagePeddle {
    ZeroPagePeddleMachine machine;
};

ZeroPagePeddle *zeropage_peddle_create(void)
{
    return new ZeroPagePeddle;
}

void zeropage_peddle_destroy(ZeroPagePeddle *machine)
{
    delete machine;
}

void zeropage_peddle_reset(ZeroPagePeddle *machine)
{
    machine->machine.resetCpu();
}

void zeropage_peddle_clear_memory(ZeroPagePeddle *machine)
{
    machine->machine.clearMemory();
}

void zeropage_peddle_load(ZeroPagePeddle *machine, uint16_t address, const uint8_t *bytes, size_t len)
{
    if (len > 65536u - address) len = 65536u - address;
    std::memcpy(&machine->machine.memory[address], bytes, len);
}

uint8_t zeropage_peddle_read(const ZeroPagePeddle *machine, uint16_t address)
{
    return machine->machine.readMemory(address);
}

uint8_t zeropage_peddle_read_reu(const ZeroPagePeddle *machine, uint32_t address)
{
    if (address >= machine->machine.reu.size()) return 0;
    return machine->machine.reu[address];
}

void zeropage_peddle_write(ZeroPagePeddle *machine, uint16_t address, uint8_t value)
{
    machine->machine.writeMemory(address, value);
}

void zeropage_peddle_set_pc(ZeroPagePeddle *machine, uint16_t pc)
{
    machine->machine.setPc(pc);
}

void zeropage_peddle_set_sp(ZeroPagePeddle *machine, uint8_t sp)
{
    machine->machine.reg.sp = sp;
}

void zeropage_peddle_set_a(ZeroPagePeddle *machine, uint8_t value)
{
    machine->machine.reg.a = value;
}

void zeropage_peddle_set_x(ZeroPagePeddle *machine, uint8_t value)
{
    machine->machine.reg.x = value;
}

void zeropage_peddle_set_y(ZeroPagePeddle *machine, uint8_t value)
{
    machine->machine.reg.y = value;
}

void zeropage_peddle_set_p(ZeroPagePeddle *machine, uint8_t value)
{
    machine->machine.setP(value);
}

void zeropage_peddle_step_instruction(ZeroPagePeddle *machine)
{
    machine->machine.stepInstruction();
}

int zeropage_peddle_run_until_rts(ZeroPagePeddle *machine, uint8_t entry_sp, uint32_t limit)
{
    auto &cpu = machine->machine;
    for (uint32_t count = 0; ; ++count) {
        const auto opcode = cpu.readMemory(cpu.reg.pc);
        if (opcode == 0x60 && cpu.reg.sp == entry_sp) return 0;
        if (opcode == 0x00) return 1;
        if (count == limit) return 2;
        cpu.stepInstruction();
    }
}

ZeroPagePeddleRegs zeropage_peddle_regs(const ZeroPagePeddle *machine)
{
    ZeroPagePeddleRegs regs = {};
    regs.pc = machine->machine.reg.pc;
    regs.pc0 = machine->machine.reg.pc0;
    regs.sp = machine->machine.reg.sp;
    regs.a = machine->machine.reg.a;
    regs.x = machine->machine.reg.x;
    regs.y = machine->machine.reg.y;
    regs.p = machine->machine.getP();
    regs.cycles = static_cast<uint64_t>(machine->machine.clock);
    regs.instructions = machine->machine.instructions;
    return regs;
}

void zeropage_peddle_watch_writes(ZeroPagePeddle *machine, uint16_t start, uint16_t size)
{
    machine->machine.watched_start = start;
    machine->machine.watched_end = static_cast<uint32_t>(start) + size;
    machine->machine.watched_bytes_written = 0;
}

uint16_t zeropage_peddle_write_high_water(const ZeroPagePeddle *machine)
{
    return machine->machine.watched_bytes_written;
}
