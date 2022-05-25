local function sll_a(xx, yy)
    local ffi = require "ffi"
    xx.gpr = ffi.new("uint32_t[64]")
    xx.gpr[4] = 99
end

local xx = {}
sll_a(xx, nil)
print(xx.gpr[4])
