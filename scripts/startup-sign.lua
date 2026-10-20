-- Boot: the ccbridge agent (ccbridge.lua, updates itself in place) plus the monitor sign.
parallel.waitForAll(
  function() shell.run("ccbridge.lua") end,
  function() shell.run("sign.lua") end
)
