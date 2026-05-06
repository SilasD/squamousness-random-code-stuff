local quickfort = reqscript('quickfort')
local z=127

df.global.gamemode=0
local qf_stats = quickfort.apply_blueprint( { mode='dig', data='s(144x144)', pos=xyz2pos(0,0,z), dry_run=false,} )

dfhack.run_command('dig-now', '0,0,'..z, '143,143,'..z)
df.global.gamemode=1
printall_recurse(qf_stats)


--[[
works! but smooths everything.  a little bit slow since the blueprint is applied by Lua code.
z=127;df.global.gamemode=0;printall_recurse(quickfort.apply_blueprint({mode='dig',data='s(144x144)',pos=xyz2pos(0,0,z),dry_run=false,}));dfhack.run_command('dig-now','0,0,'..z,'143,143,'..z);df.global.gamemode=1
does not work: main command processor wont invoke digl, maybe it is looking for the dwarfmode viewscreen being active?  no, it's not able to get the console.
df.global.gamemode=0;q=copyall(df.global.cursor);df.global.cursor:assign(require('gui.dwarfmode').getCursorPos());dfhack.run_command('digl');df.global.cursor:assign(q);df.global.gamemode=1
--]]