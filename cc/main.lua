require("jit.opt").start(
  "maxmcode=8192",
  "maxtrace=2000"
)

local Vr4300 = require "cc.vr4300.vr4300"

local cpu = Vr4300.new("dillon-n64-tests-simpleboot/sll_simpleboot.z64")
cpu:dillon_simpleboot()
cpu:run()
