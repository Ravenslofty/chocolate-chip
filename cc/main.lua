local bc = require "cc.bytecode"

local test = bc.Proto.new(nil, 0, 1)
test.explret = true
test:op_add(2, 0, 1)
test:op_ret1(2)
test:close_proto()
local dump = bc.Dump.new(test, "test.lua"):pack()

local f = loadstring(dump)

local ljbc = require "jit.bc"
ljbc.dump(f)

print(f(2, 2))
