local bit = require "bit"

local bc = require "cc.bytecode"

local band = bit.band
local rshift = bit.rshift

-- NOTE:
-- These have been carefully "worded" to avoid hitting the LuaJIT
--   loop unroll limit. Every tail call counts towards that limit
--   so they should be avoided where feasible.

local function opcode(instruction)
    assert(tonumber(instruction), "instruction must be numeric")
    local x = band(rshift(instruction, 26), 0x3F)
    return x
end

local function first_source(instruction)
    assert(tonumber(instruction), "instruction must be numeric")
    local x = band(rshift(instruction, 21), 0x1F)
    return x
end

local function second_source(instruction)
    assert(tonumber(instruction), "instruction must be numeric")
    local x = band(rshift(instruction, 16), 0x1F)
    return x
end

local function destination(instruction)
    assert(tonumber(instruction), "instruction must be numeric")
    local x = band(rshift(instruction, 11), 0x1F)
    return x
end

local function shift_amount(instruction)
    assert(tonumber(instruction), "instruction must be numeric")
    local x = band(rshift(instruction, 6), 0x1F)
    return x
end

local function function_field(instruction)
    assert(tonumber(instruction), "instruction must be numeric")
    local x = band(rshift(instruction, 0), 0x3F)
    return x
end

local function immediate16(instruction)
    assert(tonumber(instruction), "instruction must be numeric")
    local x = band(instruction, 0xFFFF)
    return x
end

MipsDecoder = {
    decode_table = {},
    decode_alu_table = {},
    GPR_OFFSET = 32,
    REG_LO = 0,
    REG_HI = 1,
}
do
    local ljbc = require "jit.bc"
    local function f(x) end
    local function g()
        f(1)
    end
    -- LJ_FR2 => 0002    KSHORT   2   1
    -- !LJ_FR2 => 0002    KSHORT   1   1
    local ans = {
        ["0002    KSHORT   2   1\n"] = true,
        ["0002    KSHORT   1   1\n"] = false,
    }
    MipsDecoder.IsFR2 = ans[ljbc.line(g, 2)];
end
assert(MipsDecoder.IsFR2 ~= nil)
MipsDecoder.CallPadding = MipsDecoder.IsFR2 and 1 or 0

---@type integer gpr
---@return integer
function MipsDecoder.gpr_lo(gpr)
    return MipsDecoder.GPR_OFFSET + MipsDecoder.REG_LO + 2*gpr
end

---@type integer gpr
---@return integer
function MipsDecoder.gpr_hi(gpr)
    return MipsDecoder.GPR_OFFSET + MipsDecoder.REG_HI + 2*gpr
end

function MipsDecoder.sign_extend(bytecode, rd, rs)
    bytecode:op_gget(2, "require")
    bytecode:op_load(3, "bit")
    bytecode:op_call(2, 1, 1)
    bytecode:op_tget(4, 2, 'S', bytecode:const("arshift"))
    bytecode:op_move(5, rs)
    bytecode:op_load(6, 31)
    bytecode:op_call(4, 1, 2)
    bytecode:op_move(rd, 4)
end

function MipsDecoder.fetch_gpr_if_needed(bytecode, gpr_cache, gpr)
    if gpr == 0 then
        bytecode:op_load(MipsDecoder.gpr_lo(gpr), 0)
        bytecode:op_load(MipsDecoder.gpr_hi(gpr), 0)
        return
    end

    if gpr_cache[gpr] then
        return
    end

    bytecode:op_tget(3, 0, 'S', bytecode:const("gpr"))
    bytecode:op_tget(MipsDecoder.gpr_lo(gpr), 3, 'B', 2*gpr)
    bytecode:op_tget(MipsDecoder.gpr_hi(gpr), 3, 'B', 2*gpr + 1)

    gpr_cache[gpr] = true
end

function MipsDecoder.after_insn(bytecode)
    bytecode:op_tget(2, 0, 'S', bytecode:const("pc"))
    bytecode:op_load(3, 4)
    bytecode:op_add(2, 2, 3)
    bytecode:op_tset(0, 'S', bytecode:const("pc"), 2)
end

-- Decode a MIPS instruction
function MipsDecoder.decode(bytecode, gpr_cache, instruction)
    assert(tonumber(instruction), "instruction must be numeric")
    local op = opcode(instruction)
    local rs = first_source(instruction)
    local rt = second_source(instruction)
    local rd = destination(instruction)
    local sa = shift_amount(instruction)
    local fn = function_field(instruction)

    --print(string.format("%08x", instruction))
    --print(string.format("%02o %d %d %d %d %02o", op, rs, rt, rd, sa, fn))
    -- print(op, rs, rt, rd, sa, fn)

    MipsDecoder.decode_table[op](bytecode, gpr_cache, instruction)
end

function MipsDecoder.alu_insn(bytecode, gpr_cache, instruction)
    local fn = function_field(instruction)
    MipsDecoder.decode_alu_table[fn](bytecode, gpr_cache, instruction)
end

function MipsDecoder.alu_imm(bytecode, gpr_cache, instruction)
    local op = opcode(instruction)
    local rt = second_source(instruction)
    local rs = first_source(instruction)
    local imm = immediate16(instruction)

    local insn_name = {
        [12] = "ANDI",
        [13] = "ORI ",
    }

    local alu_fn = {
        [12] = bytecode:const("band"),
        [13] = bytecode:const("bor"),
    }

    if rt ~= 0 then
        print(string.format("%s    $%d   $%d   0x%04x", insn_name[op], rt, rs, imm))
        MipsDecoder.fetch_gpr_if_needed(bytecode, gpr_cache, rs)
        bytecode:op_gget(2, "require")
        bytecode:op_load(3, "bit")
        bytecode:op_call(2, 1, 1)
        bytecode:op_tget(3, 2, 'S', alu_fn[op])
        bytecode:op_move(4, MipsDecoder.gpr_lo(rs))
        bytecode:op_load(5, imm)
        bytecode:op_call(3, 1, 2)
        bytecode:op_move(MipsDecoder.gpr_lo(rt), 3)
        bytecode:op_tget(3, 2, 'S', alu_fn[op])
        bytecode:op_move(4, MipsDecoder.gpr_hi(rs))
        bytecode:op_call(3, 1, 2)
        bytecode:op_move(MipsDecoder.gpr_hi(rt), 3)
        gpr_cache[rt] = true
    end

    MipsDecoder.after_insn(bytecode)
end

function MipsDecoder.lui(bytecode, gpr_cache, instruction)
    local rt = second_source(instruction)
    local imm = immediate16(instruction)

    if rt ~= 0 then
        print(string.format("LUI     $%d   0x%04x", rt, imm))
        bytecode:op_load(MipsDecoder.gpr_lo(rt), bit.lshift(imm, 16))
        MipsDecoder.sign_extend(bytecode, MipsDecoder.gpr_hi(rt), MipsDecoder.gpr_lo(rt))
        gpr_cache[rt] = true
    end

    MipsDecoder.after_insn(bytecode)
end

function MipsDecoder.lw(bytecode, gpr_cache, instruction)
    local rs = first_source(instruction)
    local rt = second_source(instruction)
    local imm = immediate16(instruction)
    print(string.format("LW      $%d   $%d(0x%04x)", rt, rs, imm))

    MipsDecoder.fetch_gpr_if_needed(bytecode, gpr_cache, rs)

    bytecode:op_move(4, 0)
    bytecode:op_load(5, imm)
    bytecode:op_add(5, 5, MipsDecoder.gpr_lo(rs))
    bytecode:op_tget(3, 0, 'S', bytecode:const("read32"))
    bytecode:op_call(3, 2, 2)
    bytecode:op_move(MipsDecoder.gpr_lo(rt), 3)
    MipsDecoder.sign_extend(bytecode, MipsDecoder.gpr_hi(rt), MipsDecoder.gpr_lo(rt))

    gpr_cache[rt] = true

    MipsDecoder.after_insn(bytecode)
end

function MipsDecoder.sw(bytecode, gpr_cache, instruction)
    local rs = first_source(instruction)
    local rt = second_source(instruction)
    local imm = immediate16(instruction)
    print(string.format("SW      $%d   $%d(0x%04x)", rt, rs, imm))

    MipsDecoder.fetch_gpr_if_needed(bytecode, gpr_cache, rs)
    MipsDecoder.fetch_gpr_if_needed(bytecode, gpr_cache, rt)

    bytecode:op_move(4, 0)
    bytecode:op_load(5, imm)
    bytecode:op_add(5, 5, MipsDecoder.gpr_lo(rs))
    bytecode:op_move(6, MipsDecoder.gpr_lo(rt))
    bytecode:op_tget(3, 0, 'S', bytecode:const("write32"))
    bytecode:op_call(3, 3, 3)

    MipsDecoder.after_insn(bytecode)
end

MipsDecoder.decode_table = {
    [0]  = MipsDecoder.alu_insn,
    [12] = MipsDecoder.alu_imm,
    [13] = MipsDecoder.alu_imm,
    [15] = MipsDecoder.lui,
    [35] = MipsDecoder.lw,
    [43] = MipsDecoder.sw,
}

function MipsDecoder.shift32(bytecode, gpr_cache, instruction)
    local fn = function_field(instruction)
    local rs = first_source(instruction)
    local rt = second_source(instruction)
    local rd = destination(instruction)
    local sa = shift_amount(instruction)

    local insn_name = {
        [0] = "SLL",
        [2] = "SRL",
        [3] = "SRA",
        [4] = "SLLV",
        [6] = "SRLV",
        [7] = "SRAV",
    }

    local shift_fn = {
        [0] = bytecode:const("lshift"),
        [2] = bytecode:const("rshift"),
        [3] = bytecode:const("arshift"),
        [4] = bytecode:const("lshift"),
        [6] = bytecode:const("rshift"),
        [7] = bytecode:const("arshift")
    }

    local variable_shift = band(fn, 4)

    if rd ~= 0 then
        MipsDecoder.fetch_gpr_if_needed(bytecode, gpr_cache, rt)
        if variable_shift then
            print(string.format("%s $%d, $%d, $%d", insn_name[fn], rd, rt, rs))
            MipsDecoder.fetch_gpr_if_needed(bytecode, gpr_cache, rs)
        else
            print(string.format("%s $%d, $%d, %d", insn_name[fn], rd, rt, sa))
        end
        bytecode:op_gget(2, "require")
        bytecode:op_load(3, "bit")
        bytecode:op_call(2, 1, 1)
        bytecode:op_tget(3, 2, 'S', shift_fn[fn])
        bytecode:op_move(4, MipsDecoder.gpr_lo(rt))
        if variable_shift then
            bytecode:op_move(5, MipsDecoder.gpr_lo(rs))
        else
            bytecode:op_load(5, sa)
        end
        bytecode:op_call(3, 1, 2)
        bytecode:op_move(MipsDecoder.gpr_lo(rd), 3)
        MipsDecoder.sign_extend(bytecode, MipsDecoder.gpr_hi(rd), MipsDecoder.gpr_lo(rd))
        gpr_cache[rd] = true
    else
        print("NOP")
    end

    MipsDecoder.after_insn(bytecode)
end

MipsDecoder.decode_alu_table = {
    [0] = MipsDecoder.shift32,
    [2] = MipsDecoder.shift32,
    [3] = MipsDecoder.shift32,
    [4] = MipsDecoder.shift32,
    [6] = MipsDecoder.shift32,
    [7] = MipsDecoder.shift32,
}

return MipsDecoder
