-- for this to work, you need to copy stonereplace.plug.dll into the hack/plugins/ directory
-- and copy stonereplace.lua into the hack/lua/plugins/ directory.
local m = dfhack.matinfo.find('INORGANIC:PLASTCRETE_ID_NULL')
require('plugins.stonereplace').run_replacement(m.type, m.index)
