-- Boot: the ccbridge agent (ccbridge.lua, updates itself in place) plus lavabot.
parallel.waitForAll(
  function() shell.run("ccbridge.lua") end,
  function() shell.run("lavabot.lua") end
)
