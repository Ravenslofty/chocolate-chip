local bit = require "bit"
local ffi = require "ffi"
local ljbc = require "jit.bc"

local bc = require "cc.bytecode"
local MipsDecoder = require "cc.vr4300.decode_mips"

---@class Vr4300
Vr4300 = {
    gpr = nil,  ---@type ffi.cdata*
    cp0r = nil, ---@type ffi.cdata*
    cp1r = nil, ---@type ffi.cdata*
    pc = 0,
    ram = nil,  ---@type ffi.cdata*
    rom = nil,  ---@type ffi.cdata*
    cache = {}
}

---@param addr integer
---@return integer
function Vr4300:read8(addr)
    addr = bit.band(addr, 0x1FFFFFFF)
    if addr >= 0x00000000 and addr <= 0x003FFFFF then
        return self.ram[addr]
    elseif addr >= 0x10000000 and addr <= 0x1FBFFFFF then
        return self.rom[addr - 0x10000000]
    else
        assert(false, string.format("unrecognised read8 from %08x", addr))
    end
end

---@param addr integer
---@return integer
function Vr4300:read16(addr)
    if bit.band(addr, 1) ~= 0 then
        assert(bit.band(addr, 1) == 0, string.format("unaligned read16 from %08x", addr))
    end
    addr = bit.band(addr, 0x1FFFFFFF)
    local data = bit.bor(self:read8(addr+1), bit.lshift(self:read8(addr), 8))
    return data
end

---@param addr integer
---@return integer
function Vr4300:read32(addr)
    if bit.band(addr, 3) ~= 0 then
        assert(bit.band(addr, 3) == 0, string.format("unaligned read32 from %08x", addr))
    end
    addr = bit.band(addr, 0x1FFFFFFF)
    return bit.bor(self:read16(addr+2), bit.lshift(self:read16(addr), 16))
end

---@param addr integer
---@param data integer
---@return nil
function Vr4300:write8(addr, data)
    addr = bit.band(addr, 0x1FFFFFFF)
    if addr >= 0x00000000 and addr <= 0x003FFFFF then
        self.ram[addr] = data
    else
        assert(false, string.format("unrecognised write8 to %08x", addr))
    end
end

function Vr4300:write32(addr, data)
    addr = bit.band(addr, 0x1FFFFFFF)
    if addr >= 0x00000000 and addr <= 0x003FFFFF then
        self.ram[addr] = data
    elseif addr >= 0x1FC007C0 and addr <= 0x1FC007FF then
        -- ignore PIF RAM writes for now.
    else
        assert(false, string.format("unrecognised write32 to %08x", addr))
    end
end

function Vr4300:dillon_simpleboot()
    -- high-level emulate the IPL's ROM to RAM copy.
    for addr=0,0x100000 do
        local byte = self.rom[0x1000 + addr]
        self.ram[0x1000 + addr] = byte
    end

    self.pc = self:read32(0x10000008)
    assert(self.pc == bit.tobit(0x80001000))
end

function Vr4300:before_trace(bytecode)
    bytecode.explret = true
    -- presently nothing to do.
end

---@type Proto bytecode
function Vr4300:after_trace(bytecode, gpr_cache)
    -- Write all registers.
    -- TODO: write only used registers, because LuaJIT dies if you store above slot 84.
    bytecode:op_tget(3, 0, 'S', bytecode:const("gpr"))

    for gpr=1,31 do
        if gpr_cache[gpr] then
            bytecode:op_tset(3, 'B', 2*gpr, MipsDecoder.gpr_lo(gpr))
            bytecode:op_tset(3, 'B', 2*gpr + 1, MipsDecoder.gpr_hi(gpr))
        end
    end

    bytecode:op_move(1, 0)
    bytecode:op_tget(0, 1, 'S', bytecode:const("run"))
    bytecode:op_callt(0, 1, 1)

    bytecode:close_proto()
end

function Vr4300:build_trace()
    local bytecode = bc.Proto.new(nil, 0, 4)
    local gpr_cache = {}

    io.write("-- MIPS ASM --\n")

    self:before_trace(bytecode)

    for offset=0,68,4 do
        bytecode:line(offset)
        io.write(string.format("%04x    ", offset))
        local insn = self:read32(self.pc + offset)
        MipsDecoder.decode(bytecode, gpr_cache, insn)
    end

    self:after_trace(bytecode, gpr_cache)
    local dump = bc.Dump.new(bytecode, string.format("%08x.vr4300.s", self.pc)):pack()
    self.cache[self.pc] = loadstring(dump)

    ljbc.dump(self.cache[self.pc])
end

function Vr4300:run()
    print(string.format("==> %08x", self.pc))
    if self.cache[self.pc] == nil then
        self:build_trace()
        assert(self.cache[self.pc] ~= nil)
    end
    return self.cache[self.pc](self)
end

---@param rom_file string
---@return Vr4300
function Vr4300.new(rom_file)
    local cpu = Vr4300
    local f = assert(io.open(rom_file, "r")) ---@type file*
    local data = f:read("*a")
    f:close()
    cpu.gpr = ffi.new("uint32_t[64]") -- Because LJ uses 32-bit ints, we need to turn 32 64-bit ints into 32*2 32-bit ints.
    cpu.cp0r = ffi.new("uint32_t[64]")
    cpu.cp1r = ffi.new("double[32]")
    cpu.ram = ffi.new("uint8_t[4*1024*1024]")
    cpu.rom = ffi.new("uint8_t[1052672]", data)
    cpu.cache = {}

    ffi.fill(cpu.gpr, 64, 0)

    assert(cpu.rom[0] == 0x80 and cpu.rom[1] == 0x37 and cpu.rom[2] == 0x12 and cpu.rom[3] == 0x40, "ROM must be big-endian Z64")
    return cpu
end

return Vr4300