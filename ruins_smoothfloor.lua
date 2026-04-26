-- ruins_smoothfloor.lua
-- SWD: if you use a longquote string or a lonquote comment with four ====,
--      DFHack will treat the string or comment as help text,
--      and will e.g. show it in the Launcher.
--[====[
    ruins_smoothfloor enable
    ruins_smoothfloor disable
    ruins_smoothfloor force
    ruins_smoothfloor status
--]====]

-- SWD: renamed these, added SCAN_MODE, changed to raw frames (i.e. FPS),
--      otherwise, the conversion only runs when the adventure moves.
local INITIAL_DELAY  = 5
local DELAY_INTERVAL  = 1
local DELAY_MODE = 'frames'

local SMOOTH_CLASSES = {
    HEAVY_STRUCTURE  = { floor=true, wall=true  },
    MIDDLE_STRUCTURE = { floor=true, wall=true  },
    LIGHT_STRUCTURE  = { floor=true, wall=true  },
    MACHINERY        = { floor=true, wall=false },
}

-- ============================================================================
-- TILETYPE CONSTANTS
-- ============================================================================

local STONE_MAT      = df.tiletype_material.STONE
local LAVA_STONE_MAT = df.tiletype_material.LAVA_STONE
local SHAPE_WALL     = df.tiletype_shape.WALL
local SPECIAL_SMOOTH = df.tiletype_special.SMOOTH
local BASIC_FLOOR    = df.tiletype_shape_basic.Floor

-- SWD: These are constants.  You can hard-code the names.  Much faster.
local SMOOTH_FLOOR_TT = df.tiletype.StoneFloorSmooth
local SMOOTH_LAVA_FLOOR_TT = df.tiletype.LavaFloorSmooth
local OPEN_SPACE_TT  = df.tiletype.OpenSpace

--[[
local SMOOTH_FLOOR_TT = (function()
    for i = 0, 65535 do
        local a = df.tiletype.attrs[i]
        if a and a.material == STONE_MAT and a.special == SPECIAL_SMOOTH then
            local sa = df.tiletype_shape.attrs[a.shape]
            if sa and sa.basic_shape == BASIC_FLOOR then return i end
        end
    end
end)()
assert(SMOOTH_FLOOR_TT == df.tiletype.StoneFloorSmooth)
--]]

--[[
local SMOOTH_LAVA_FLOOR_TT = (function()
    for i = 0, 65535 do
        local a = df.tiletype.attrs[i]
        if a and a.material == LAVA_STONE_MAT and a.special == SPECIAL_SMOOTH then
            local sa = df.tiletype_shape.attrs[a.shape]
            if sa and sa.basic_shape == BASIC_FLOOR then return i end
        end
    end
end)()
assert(SMOOTH_LAVA_FLOOR_TT == df.tiletype.LavaFloorSmooth)
--]]

--[[    SWD: This code took about 75 milliseconds to fill its tables.
local smooth_stone_wall_by_suffix = {}
local smooth_lava_wall_by_suffix  = {}
local smooth_stone_wall_fallback  = nil  -- "" suffix = isolated pillar
local smooth_lava_wall_fallback   = nil  -- SWD: the above statement is false; there is NO tile
                                         --      named StoneWallSmooth or LavaWallSmooth.
                                         -- SWD: testing showed the fallbacks were never set.
do
    for i = 0, 65535 do
        local name  = df.tiletype[i]
        local attrs = df.tiletype.attrs[i]
        if name and attrs and attrs.special == SPECIAL_SMOOTH and attrs.shape == SHAPE_WALL then
            local sname = tostring(name)    -- SWD: that was not necessary; name was already a string.
                                            --      (You already checked that it is not nil.)
            local suf = sname:match("^StoneWallSmooth([LRUD]*)$")
                                            -- this match was buggy; '2' is also legal in suffixes.
            if suf ~= nil then
                smooth_stone_wall_by_suffix[suf] = i
                if suf == "" then smooth_stone_wall_fallback = i end
            end
            local lsuf = sname:match("^LavaWallSmooth([LRUD]*)$")
            if lsuf ~= nil then
                smooth_lava_wall_by_suffix[lsuf] = i
                if lsuf == "" then smooth_lava_wall_fallback = i end
            end
        end
    end
    if next(smooth_lava_wall_by_suffix) == nil then
        smooth_lava_wall_by_suffix = smooth_stone_wall_by_suffix
        smooth_lava_wall_fallback  = smooth_stone_wall_fallback
    end
end --]]

-- SWD: In contrast, this code runs in less than half a millisecond; almost too small to measure.
local smooth_stone_wall_by_suffix = {}
local smooth_lava_wall_by_suffix  = {}
local smooth_stone_wall_fallback  = df.tiletype.StonePillar
local smooth_lava_wall_fallback   = df.tiletype.LavaPillar

for prefix, table in pairs{
    Stone = smooth_stone_wall_by_suffix,
    Lava = smooth_lava_wall_by_suffix,
} do
    for _,L in ipairs{'', 'L'} do
        for _,R in ipairs{'', 'R'} do
            for _,U in ipairs{'', 'U'} do
                for _,D in ipairs{'', 'D'} do
                    local suffix = L .. R .. U .. D
                    local name = prefix .. "WallSmooth" .. suffix
                    local num = df.tiletype[name]
                    if num then
                        table[suffix] = num
                    end
                end
            end
        end
    end
end

-- Per-tiletype kind lookup built once at load

-- SWD: these mappings could easily be put in the smooth_xxx_wall_by_suffix table.  just saying.
local smooth_stone_wall_tt_set = {}
local smooth_lava_wall_tt_set  = {}
for _, i in pairs(smooth_stone_wall_by_suffix) do smooth_stone_wall_tt_set[i] = true end
if smooth_lava_wall_by_suffix ~= smooth_stone_wall_by_suffix then
    for _, i in pairs(smooth_lava_wall_by_suffix) do smooth_lava_wall_tt_set[i] = true end
end

local tt_kind = (function()
    local t = {}
    -- SWD: This for loop does a lot of extra processing, which slows it down quite a bit.
    --for i = 0, 65535 do
    -- SWD: I changed the for loop to process only existing tiletypes.  Much faster.
    --      In general, you should always process tiletypes as ipairs(), which will give
    --      you tiletype numbers as the key and tiletype names as the value.
    for i,name in ipairs(df.tiletype) do
        local a = df.tiletype.attrs[i]
        --if a then
        -- SWD: 'a' will always contain data.  it might not be valid though!
        --      df.tiletype.attrs always returns a table, even if it has data of '-1', etc.
        -- SWD: with the new loop limiting to the number of tiletypes, 'a' will always be valid.
            local mat   = a.material
            local sa    = df.tiletype_shape.attrs[a.shape]
            local basic = sa and sa.basic_shape
            if a.special ~= SPECIAL_SMOOTH then
                if mat == STONE_MAT then
                    if basic == BASIC_FLOOR      then t[i] = 'sf'
                    elseif a.shape == SHAPE_WALL then t[i] = 'sw' end
                elseif mat == LAVA_STONE_MAT then
                    if basic == BASIC_FLOOR      then t[i] = 'lf'
                    elseif a.shape == SHAPE_WALL then t[i] = 'lw' end
                end
            elseif a.shape == SHAPE_WALL then
                if smooth_stone_wall_tt_set[i] then
                    t[i] = 'sw_r'
                elseif smooth_lava_wall_tt_set[i] then
                    t[i] = 'lw_r'
                end
            end
        --end
    end
    return t
end)()

-- ============================================================================
-- STATE
-- ============================================================================

-- SWD: I still don't understand why you need this kind of super-global,
--      and I also don't believe that you need to use rawget() on it.
--      I think I would write it as
--      _G.__smoothfloor_state = _G.__smoothfloor_state or {
--          init table stuff
--      }
--      local S = _G.__smoothfloor_state
--
-- SWD: granted, it is good to have watcher_enabled, scan_gen, and the new
--      current_timeout_id as a super-global so that the data is available
--      even when the script is edited.
local S = rawget(_G, "__smoothfloor_state")
if not S then
    S = {
        watcher_enabled  = false,
        scan_gen         = 0,
        --init_gen         = 0,     -- SWD: removed
        processed_blocks = {},
        --last_site_id     = nil,   -- SWD: removed in favor of new function map_changed()
        --last_block_count = 0,     -- SWD: removed in favor of new function map_changed()
        --biome_cache      = {},    -- SWD: removed
        current_timeout_id = -1,    -- SWD: new
    }
    _G.__smoothfloor_state = S
end
if S.scan_gen         == nil then S.scan_gen         = 0 end
--if S.init_gen         == nil then S.init_gen         = 0 end  -- SWD: removed
--if S.last_block_count == nil then S.last_block_count = 0 end  -- SWD: removed

-- ============================================================================
-- LIBRARY FUNCTIONS
-- ============================================================================

-- SWD: string.format() moved into this function.  That's much better
--      than requiring every caller that needs formatting to do it itself.
local function log(msg, ...) print("[smoothfloor] " .. string.format(msg, ...)) end

-- ============================================================================
-- INORGANIC CACHE
-- ============================================================================

local smooth_inorganic_cache = nil

local function build_inorganic_cache()
    smooth_inorganic_cache = {}
    local count = 0
    -- SWD: using ipairs() means you don't have to think about whether to start
    --      the for loop at 0 or 1, and whether to end at #array-1 or #array.
    --local all   = df.global.world.raws.inorganics.all
    --for i = 0, #all - 1 do
    for i, m in ipairs(df.global.world.raws.inorganics.all) do
        --local mat = all[i].material
        -- SWD: also, you should almost always use ipairs(), not pairs(),
        --      on Dwarf Fortress's data structures.
        --      if it's a vector or a raw array, use ipairs().
        --for _, rc in pairs(mat.reaction_class) do
        local mat = m.material
        for _, rc in ipairs(mat.reaction_class) do
            assert(type(rc.value) == "string")
            local cfg = SMOOTH_CLASSES[rc.value]
            if cfg then
                smooth_inorganic_cache[i] = cfg
                count = count + 1
                break
            end
        end
    end
    log("inorganic cache built: %d matching", count)
end

local function get_biome_for_tile(wx, wy, wz)
    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)
    -- SWD: note: this is not necessary; a valid tile will always have a biome region.
    if not rx then return nil end
    -- SWD: getRegionBiome() is *extremely* fast, even after the slowdown of
    --      converting two Lua integer variables into C++ integer variables.
    --      it is almost certainly faster than trying to manage a cache in Lua.
    local ri = dfhack.maps.getRegionBiome(rx, ry)
    -- SWD: yeah, even with a .find(), the C++ code is probably faster.
    --local b = df.world_geo_biome.find(ri.geo_index)
    -- SWD: is the .find() even necessary?  it looks like you can just get
    --      your geo_biome by indexing the vector.  testing that.  A: yes, it works.
    local b = df.world_geo_biome.get_vector()[ri.geo_index]
    do return b end
    -- SWD: remaining code disabled as unnecessary.

    -- SWD: I can't tell what this code does.  is it fallback code?
    local max_z = df.global.world.map.z_count - 1
    for dz = 1, math.min(300, max_z - wz) do
        local rx2, ry2 = dfhack.maps.getTileBiomeRgn(wx, wy, wz + dz)
        if not rx2 then break end
        local key2 = rx2 .. "," .. ry2
        if key2 ~= key then
            local v2 = S.biome_cache[key2]
            if v2 == nil then
                local ri2 = dfhack.maps.getRegionBiome(rx2, ry2)
                v2 = ri2 and df.world_geo_biome.find(ri2.geo_index) or false
                S.biome_cache[key2] = v2
            end
            if v2 then
                S.biome_cache[key] = v2
                return v2
            end
        end
    end
    S.biome_cache[key] = false
    return nil
end

-- ============================================================================
-- WALL SUFFIX HELPERS
-- ============================================================================

local function wall_at(nx, ny, nz)
    local tt = dfhack.maps.getTileType(nx, ny, nz)
    local a  = tt and df.tiletype.attrs[tt]
    return a ~= nil and a.shape == SHAPE_WALL
end

local function get_wall_suffix(wx, wy, wz)
    return (wall_at(wx-1, wy,   wz) and "L" or "")
        .. (wall_at(wx+1, wy,   wz) and "R" or "")
        .. (wall_at(wx,   wy-1, wz) and "U" or "")
        .. (wall_at(wx,   wy+1, wz) and "D" or "")
end

local function pick_smooth_wall_tt(tbl, fallback, wx, wy, wz)
    return tbl[get_wall_suffix(wx, wy, wz)] or fallback
end

-- ============================================================================
-- SCAN LOGIC
-- ============================================================================

local function scan_block(block, resuffix)
    if not smooth_inorganic_cache then return 0, 0, false end
    local floors, walls = 0, 0
    local has_hidden    = false
    local bx = block.map_pos.x
    local by = block.map_pos.y
    local bz = block.map_pos.z

    -- Pass 1: layer stones (STONE_MAT / LAVA_STONE_MAT).
    for lx = 0, 15 do
        for ly = 0, 15 do
            local tt   = block.tiletype[lx][ly]
            local kind = tt_kind[tt]
            if kind == 'sf' or kind == 'sw' or kind == 'lf' or kind == 'lw' then
                -- SWD: why are you not rewriting hidden blocks?  Just for speed?
                if block.designation[lx][ly].hidden then
                    has_hidden = true
                elseif tt == OPEN_SPACE_TT then
                    -- do nothing; empty air can't be smoothed.
                else
                    local b = get_biome_for_tile(bx+lx, by+ly, bz)
                    -- SWD: this test is not necessary; a valid tile will always have a biome.
                    if b then
                        local layer = b.layers[block.designation[lx][ly].geolayer_index]
                        -- SWD: the first test is not necessary; you will always have a layer.
                        local cfg = layer and smooth_inorganic_cache[layer.mat_index]
                        if not cfg then
                            -- SWD: do remember that pairs() ordering is not guaranteed to be linear.
                            --      It usually is for DF data types, but I wouldn't trust that.  Use ipairs().
                            for _, fl in pairs(b.layers) do
                                cfg = smooth_inorganic_cache[fl.mat_index]
                                if cfg then break end
                            end
                        end
                        if cfg then
                            if (kind == 'sf' or kind == 'lf') and cfg.floor then
                                local ftt = (kind == 'sf') and SMOOTH_FLOOR_TT or SMOOTH_LAVA_FLOOR_TT
                                if ftt then block.tiletype[lx][ly] = ftt end
                                floors = floors + 1
                            elseif (kind == 'sw' or kind == 'lw') and cfg.wall then
                                local tbl = (kind == 'sw') and smooth_stone_wall_by_suffix or smooth_lava_wall_by_suffix
                                local fb  = (kind == 'sw') and smooth_stone_wall_fallback  or smooth_lava_wall_fallback
                                local wtt = pick_smooth_wall_tt(tbl, fb, bx+lx, by+ly, bz)
                                if wtt then block.tiletype[lx][ly] = wtt end
                                walls = walls + 1
                            end
                        end
                    end
                end
            elseif resuffix and (kind == 'sw_r' or kind == 'lw_r') then
                if not block.designation[lx][ly].hidden then
                    local tbl = (kind == 'sw_r') and smooth_stone_wall_by_suffix or smooth_lava_wall_by_suffix
                    local fb  = (kind == 'sw_r') and smooth_stone_wall_fallback  or smooth_lava_wall_fallback
                    local wtt = pick_smooth_wall_tt(tbl, fb, bx+lx, by+ly, bz)
                    if wtt and wtt ~= tt then
                        block.tiletype[lx][ly] = wtt
                        walls = walls + 1
                    end
                -- SWD: shouldn't there be an else clause where you set has_hidden = true ?
                end
            end
        end
    end

    return floors, walls, has_hidden
end

local function get_site_id()
    local site = dfhack.world.getCurrentSite and dfhack.world.getCurrentSite()
    return site and site.id or -1
end

local function is_player_map()
    if dfhack.world.isFortressMode and dfhack.world.isFortressMode() then return true end
    local site = dfhack.world.getCurrentSite and dfhack.world.getCurrentSite()
    return site ~= nil and site.type == df.world_site_type.PlayerFortress
end

local function convert_all(force)
    if not dfhack.isMapLoaded() then return end
    if not smooth_inorganic_cache then build_inorganic_cache() end

    -- SWD: map_changed() is now dealing with sanity checks.
    --local site_id = get_site_id()
    --if force or site_id ~= S.last_site_id then
    --    S.processed_blocks  = {}
    --    S.last_site_id      = site_id
    --    S.last_block_count  = 0
    --end

    local tf, tw = 0, 0
    -- SWD: This is the biggest problem this script has.  An adventurer-mode map
    --      has approximately then thousand blocks, so the inner loop of scan_block()
    --      runs two and a half million times.
    for _, block in ipairs(df.global.world.map.map_blocks) do
        local bk = ("%d,%d,%d"):format(block.map_pos.x, block.map_pos.y, block.map_pos.z)
        if not S.processed_blocks[bk] then
            -- SWD: I really don't understand the logic for partial aka has_hidden.
            local f, w, partial = scan_block(block, force)
            if not partial then S.processed_blocks[bk] = true end
            tf = tf + f; tw = tw + w
        end
    end

    if tf + tw > 0 then
        log("Smoothed: floors=%d walls=%d", tf, tw)
    end
end

-- ============================================================================
-- MAP CHANGED?
-- ============================================================================

-- SWD: Test these DF variables to see if the map changed.
-- SWD Q: should this be part of the super-global?
-- This array should contain individual tables containing functions
--      that take no parameters and return a primitive value to track.
--      These values should be numbers or strings.
--      Implementation note: the return values are cached as the second
--      elements of the tables.
local map_changed_tests = {
    { get_site_id },
    { function() return df.global.world.world_data.midmap_data.adv_region_x end },
    { function() return df.global.world.world_data.midmap_data.adv_region_y end },
    { function() return df.global.world.world_data.midmap_data.adv_emb_x end },
    { function() return df.global.world.world_data.midmap_data.adv_emb_y end },
    { function() return #df.global.world.map.map_blocks end },      -- vector size
}

-- SWD: Returns true iff the map changed.  Called very frequently!
local function map_changed()
    local changed = false
    for i,test in ipairs(map_changed_tests) do
        if test[2] ~= (test[1])() then changed = true; end
    end
    if not changed then return false end

    log("map_changed() detected a map change.")
    for i,test in ipairs(map_changed_tests) do
        test[2] = (test[1])()
    end
    return true
end

-- ============================================================================
-- WATCHER
-- ============================================================================

local function stop_watcher()
    dfhack.timeout_active(S.current_timeout_id, nil)     -- if a timeout is active, cancel it.
    S.current_timeout_id = -1
    S.watcher_enabled = false
    S.scan_gen        = S.scan_gen + 1
end

-- Called very frequently!
-- Checks for map-changed every frame; only runs convert_all when the map changes.
-- delay is an optional parameter, used for the initial startup delay.
-- SWD: I rewrote most of this logic.
-- SWD: I think this is cheap enough to run on every single frame.
--      My only concern is that the call to dfhack.timeout creates a new closure
--      (that is, defines a new temporary function) every time.
local function timeout_callback(gen, delay)
    S.current_timeout_id = -1   -- no longer valid.
    if not S.watcher_enabled then return end
    if gen ~= S.scan_gen     then return end
    if not dfhack.isMapLoaded()  then return end

    -- SWD: I suppose you're checking is_player_map() so that you don't corrupt a player fort?
    if not delay and not is_player_map() and map_changed() then
        convert_all(false)
    end

    delay = delay or DELAY_INTERVAL
    S.current_timeout_id = dfhack.timeout(DELAY_INTERVAL, DELAY_MODE, function() timeout_callback(gen) end)
end

-- SWD: minor rewrite of this logic.
local function start_watcher()
    dfhack.timeout_active(S.current_timeout_id, nil)     -- if a timeout is active, cancel it.
    S.watcher_enabled = true
    S.scan_gen        = S.scan_gen + 1
    S.current_timeout_id = dfhack.timeout(INITIAL_DELAY, DELAY_MODE, function() timeout_callback(S.scan_gen) end)
end

-- SWD: I combined this with start_watcher.
--local function schedule_initial()
--    S.init_gen    = S.init_gen + 1
--    local gen     = S.init_gen
--    dfhack.timeout(INITIAL_DELAY, DELAY_MODE, function()
--        if gen ~= S.init_gen then return end
--        convert_all(false)
--    end)
--end


-- ============================================================================
-- COMMANDS
-- ============================================================================

local args = { ... }
local cmd  = args[1] or "enable"

if cmd == "enable" then
    -- SWD: smooth_inorganic_cache is also built in convert_all, which is a better place.
    --if not smooth_inorganic_cache then build_inorganic_cache() end
    --SWD removed this call; only timeout_callback and "force" should call convert_all.
    --convert_all(false)
    start_watcher()
elseif cmd == "force" then
    -- SWD: smooth_inorganic_cache is also built in convert_all, which is a better place.
    --if not smooth_inorganic_cache then build_inorganic_cache() end
    map_changed()       -- call this for the side effects.
    convert_all(true)
elseif cmd == "disable" then
    stop_watcher()
    smooth_inorganic_cache = nil
    S.processed_blocks     = {}
    --S.last_site_id         = nil      -- SWD: removed in favor of map_changed()
    --S.last_block_count     = 0        -- SWD: removed in favor of map_changed()
    S.biome_cache          = {}         -- SWD: removed.
elseif cmd == "status" then
    local n = 0; for _ in pairs(smooth_stone_wall_by_suffix) do n = n + 1 end
    log("watcher=%s timeout_active=%s cache=%s floor_tt=%s wall_variants=%d",
        tostring(S.watcher_enabled),
        tostring(dfhack.timeout_active(S.current_timeout_id)),
        tostring(smooth_inorganic_cache ~= nil),
        -- SWD: this will always, *always* be 43, StoneFloorSmooth.  df.tiletype numbers and names are *constants*.
        tostring(SMOOTH_FLOOR_TT),
        n)
else
    log("Usage: ruins_smoothfloor [enable|disable|force|status]")
end
