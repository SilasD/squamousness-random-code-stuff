-- for this to work, you need to copy TheLongNight.plug.dll into the hack/plugins/ directory
-- and copy TheLongNight.lua into the hack/lua/plugins/ directory.
local library = require('plugins.TheLongNight')
local m = dfhack.matinfo.find('INORGANIC:PLASTCRETE_ID_NULL')
local r = library.run_replacement(m.type, m.index)
local ticks = library.ticks()
local freq = 1.0 * library.freq()
print(string.format("converted %d tiles from %s to %s", r, dfhack.matinfo.decode(0,-1):getToken(), m:getToken()))
print(string.format("conversion time: %0.9f seconds", ticks / freq))