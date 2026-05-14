do dfhack.printerr("attempt to run a profiled script!"); return; end;  local profile = "1"; myprofiler = reqscript("myprofiler"); myprofiler.stop(); if profile then _G.__ruins_state = nil; myprofiler.start(); end --[====[ ruins.lua
Converts fake-construction grass plants into real DFHack construction records.

Usage:
    ruins enable
    ruins force
    ruins disable
    ruins status
    ruins debug
    ruins debug-roads
--]====]

local getTimestamp          = dfhack.QueryPerformanceCounter     or os.clock
local getTimestampDivisor   = dfhack.QueryPerformanceFrequency   or function()return 1.0;end

local clocktime = -getTimestamp()

local PLASTCRETE_TOKEN      = "INORGANIC:PLASTCRETE_ID_NULL"
local SUPERSTRUCTURE_TOKEN  = "INORGANIC:SUPERSTRUCTURE_ID_NULL"
local INITIAL_DELAY_TICKS   = 120
local SCAN_INTERVAL_TICKS = 150
local SCAN_RADIUS         = 96

-- Maximum wall height (in tiles) per biome.
local BIOME_MAX_HEIGHT = {
    [df.biome_type.DESERT_SAND]                     = 10,
    [df.biome_type.GRASSLAND_TEMPERATE]             = 10,
    [df.biome_type.GRASSLAND_TROPICAL]              = 10,
    [df.biome_type.SHRUBLAND_TEMPERATE]             = 20,
    [df.biome_type.SHRUBLAND_TROPICAL]              = 20,
    [df.biome_type.SAVANNA_TEMPERATE]               = 40,
    [df.biome_type.SAVANNA_TROPICAL]                = 40,
    [df.biome_type.DESERT_BADLAND]                  = 20,
    [df.biome_type.DESERT_ROCK]                     = 40,
    [df.biome_type.MOUNTAIN]                        = 15,
    [df.biome_type.SUBTERRANEAN_WATER]              = 20,
    [df.biome_type.SUBTERRANEAN_CHASM]              = 20,
    [df.biome_type.SUBTERRANEAN_LAVA]               = 20,
    -- Wetlands here so i can add them later maybe
    -- [df.biome_type.SWAMP_TEMPERATE_FRESHWATER]   = X,
    -- [df.biome_type.SWAMP_TEMPERATE_SALTWATER]    = X,
    -- [df.biome_type.MARSH_TEMPERATE_FRESHWATER]   = X,
    -- [df.biome_type.MARSH_TEMPERATE_SALTWATER]    = X,
    -- [df.biome_type.SWAMP_TROPICAL_FRESHWATER]    = X,
    -- [df.biome_type.SWAMP_TROPICAL_SALTWATER]     = X,
    -- [df.biome_type.SWAMP_MANGROVE]               = X,
    -- [df.biome_type.MARSH_TROPICAL_FRESHWATER]    = X,
    -- [df.biome_type.MARSH_TROPICAL_SALTWATER]     = X,
}
local DEFAULT_MAX_HEIGHT = 5   -- fallback for biomes not listed above
local STAIR_PROB         = 2   -- % chance a wall tower becomes an up-down staircase column
local FORT_PROB          = 10  -- % chance a wall tower in a SUPERSTRUCTURE biome becomes a fortification

local NO_WALL_SPANS       = false -- set true to skip horizontal wall span generation
local NO_FLOOR_SPANS      = false -- set true to skip floor slab span generation
local NO_CATWALK_SPANS    = false -- set true to skip catwalk span generation

local MAX_SPAN            = 12  -- max tiles a span extends from a tower
local SPAN_WALL_GAP_PROB  = 20  -- % chance a wall span step terminates the span
local SPAN_WALL_FORT_PROB = 15  -- % chance a non-gap wall span step uses a fortification tile
local SPAN_SIDE_PROB      = 50  -- % chance a perpendicular side tile is attempted (floor spans)
local SPAN_SIDE_GAP_PROB  = 25  -- % chance an attempted side tile is a gap

-- Biomes whose constructions use SUPERSTRUCTURE_ID_NULL instead of PLASTCRETE_ID_NULL.
local SUPERSTRUCTURE_BIOMES = {
    [df.biome_type.FOREST_TAIGA]                    = true,
    [df.biome_type.FOREST_TEMPERATE_CONIFER]        = true,
    [df.biome_type.FOREST_TEMPERATE_BROADLEAF]      = true,
    [df.biome_type.FOREST_TROPICAL_CONIFER]         = true,
    [df.biome_type.FOREST_TROPICAL_DRY_BROADLEAF]   = true,
    [df.biome_type.FOREST_TROPICAL_MOIST_BROADLEAF] = true,
}

-- Wall tiles in these biomes are always degraded to floors but there arent any
local FLOOR_ONLY_BIOMES = {
}


local FLOOR_PLANT_IDS = { TILE1=true, TILE2=true, TILE3=true }
local WALL_PLANT_IDS  = { CONCRETE=true }
-- SWD: note that v7.13 doesn't have a plant named CONCRETE.  Do you want CONCRETE1?
--      also, there v7.13 has a plant named CONCRETE4, should it be in the list?
WALL_PLANT_IDS.CONCRETE1 = true     -- SWD added

local PLASTCRETE_MAT_TYPE
local PLASTCRETE_MAT_INDEX
local SUPERSTRUCTURE_MAT_TYPE
local SUPERSTRUCTURE_MAT_INDEX

local OPEN_SPACE_TT = df.tiletype.OpenSpace; assert(OPEN_SPACE_TT)
local RAMP_TOP_TT = df.tiletype.RampTop; assert(RAMP_TOP_TT)

local CONSTRUCTED_FLOOR_TT = df.tiletype.ConstructedFloor
--local CONSTRUCTED_FLOOR_TT = (function()
--    local constr = df.tiletype_material.CONSTRUCTION
--    for i = 0, 65535 do
--        local attrs = df.tiletype.attrs[i]
--        if attrs and attrs.material == constr and tostring(df.tiletype[i]) == "ConstructedFloor" then
--            return i
--        end
--    end
--end)()

local CONSTRUCTED_RAMP_TT = df.tiletype.ConstructedRamp
--local CONSTRUCTED_RAMP_TT = (function()
--    local constr = df.tiletype_material.CONSTRUCTION
--    for i = 0, 65535 do
--        local attrs = df.tiletype.attrs[i]
--        if attrs and attrs.material == constr and tostring(df.tiletype[i] or ""):find("^ConstructedRamp") then
--            return i
--        end
--    end
--end)()


if false then   -- SWD: 75 milliseconds
local runtime = -getTimestamp()
local constructed_wall_by_suffix = (function()
    local t = {}
    local constr = df.tiletype_material.CONSTRUCTION
    for i = 0, 65535 do
        local name  = df.tiletype[i]
        local attrs = df.tiletype.attrs[i]
        if name and attrs and attrs.material == constr then
            -- SWD: oh dear.  Walls can have the digit '2' in their tile names.  Only the digit '2'.
            local raw = tostring(name):match("^ConstructedWall([LRUD0-9]*)$")
            if raw ~= nil then
                local sfx = raw:gsub("%d+", "")
                if not t[sfx] or not raw:find("%d") then t[sfx] = i end
            end
        end
    end
    return t
end)()
runtime = (runtime + getTimestamp()) / getTimestampDivisor()
print(string.format("OLD constructed_wall_by_suffix runtime: %0.6f seconds", runtime))
end

--local runtime = -getQueryPerformanceCounter()
local constructed_wall_by_suffix = {}
do  -- SWD: a quarter of a millisecond, a 300x speedup.
    local table = constructed_wall_by_suffix
    for _,L in ipairs{'', 'L', 'L2'} do
        for _,R in ipairs{'', 'R', 'R2'} do
            for _,U in ipairs{'', 'U', 'U2'} do
                for _,D in ipairs{'', 'D', 'D2'} do
                    local suffix = L .. R .. U .. D
                    local name = "ConstructedWall" .. suffix
                    local num = df.tiletype[name]
                    if num then
                        table[suffix] = num
                        table[name] = num
                        table[num] = true
                    end
                end
            end
        end
    end
end
-- Suffixes with no matching tiletype (single-connection stubs) become pillars.
for _,suffix in ipairs{'', 'L', 'R', 'U', 'D'} do
    constructed_wall_by_suffix[suffix] = df.tiletype.ConstructedPillar
end
--runtime = (runtime + getQueryPerformanceCounter()) / getQueryPerformanceFrequency()
--print(string.format("NEW constructed_wall_by_suffix runtime: %0.6f seconds", runtime))


--local CONSTRUCTED_WALL_TT = constructed_wall_by_suffix["LRUD"]
--    or constructed_wall_by_suffix[""]
local CONSTRUCTED_WALL_TT = df.tiletype.ConstructedWallLRUD

--local CONSTRUCTED_PILLAR_TT = (function()
--    local constr = df.tiletype_material.CONSTRUCTION
--    for i = 0, 65535 do
--        local attrs = df.tiletype.attrs[i]
--        if attrs and attrs.material == constr and tostring(df.tiletype[i]) == "ConstructedPillar" then
--            return i
--        end
--    end
--end)()
local CONSTRUCTED_PILLAR_TT = df.tiletype.ConstructedPillar

--local CONSTRUCTED_STAIR_UD_TT = (function()
--    local constr         = df.tiletype_material.CONSTRUCTION
--    local stair_ud_shape = df.tiletype_shape.STAIR_UPDOWN
--    for i = df.tiletype._first_item, df.tiletype._last_item do
--        local attrs = df.tiletype.attrs[i]
--        local name  = df.tiletype[i]
--        if attrs and name and attrs.material == constr then
--            if stair_ud_shape and attrs.shape == stair_ud_shape then return i end
--            local s = tostring(name):lower()
--            if s:find("stair") and (s:find("updown") or s:find("ud") or (s:find("up") and s:find("down"))) then
--                return i
--            end
--        end
--    end
--end)()
local CONSTRUCTED_STAIR_UD_TT = df.tiletype.ConstructedStairUD

--local CONSTRUCTED_STAIR_UP_TT = (function()
--    local constr = df.tiletype_material.CONSTRUCTION
--    local shape  = df.tiletype_shape and df.tiletype_shape.STAIR_UP
--    for i = df.tiletype._first_item, df.tiletype._last_item do
--        local attrs = df.tiletype.attrs[i]
--        local name  = df.tiletype[i]
--        if attrs and name and attrs.material == constr then
--            if shape and attrs.shape == shape then return i end
--            if tostring(name) == "ConstructedStairUp" then return i end
--        end
--    end
--end)()
local CONSTRUCTED_STAIR_UP_TT = df.tiletype.ConstructedStairU

--local CONSTRUCTED_STAIR_DOWN_TT = (function()
--    local constr = df.tiletype_material.CONSTRUCTION
--    local shape  = df.tiletype_shape and df.tiletype_shape.STAIR_DOWN
--    for i = df.tiletype._first_item, df.tiletype._last_item do
--        local attrs = df.tiletype.attrs[i]
--        local name  = df.tiletype[i]
--        if attrs and name and attrs.material == constr then
--            if shape and attrs.shape == shape then return i end
--            if tostring(name) == "ConstructedStairDown" then return i end
--        end
--    end
--end)()
local CONSTRUCTED_STAIR_DOWN_TT = df.tiletype.ConstructedStairD

--local CONSTRUCTED_FORTIFICATION_TT = (function()
--    local constr = df.tiletype_material.CONSTRUCTION
--    for i = 0, 65535 do
--        local attrs = df.tiletype.attrs[i]
--        if attrs and attrs.material == constr
--           and tostring(df.tiletype[i]) == "ConstructedFortification" then
--            return i
--        end
--    end
--end)()
local CONSTRUCTED_FORTIFICATION_TT = df.tiletype.ConstructedFortification

--local SOIL_FLOOR_TT = (function()
--    for i = 0, 65535 do
--        if tostring(df.tiletype[i]) == "SoilFloor1" then return i end
--    end
--end)()
local SOIL_FLOOR_TT = df.tiletype.SoilFloor1

local function original_tile_for(tt)                                                                                    --   63204  0.395s
    local attrs = df.tiletype.attrs[tt]                                                                                 --    8670
    if attrs then                                                                                                       --    3285
        local m = attrs.material                                                                                        --    3840
        if m == df.tiletype_material.GRASS_DARK or m == df.tiletype_material.GRASS_LIGHT then                           --   31339
            -- SWD: Q: what about GRASS_DRY and GRASS_DEAD ?
            return SOIL_FLOOR_TT or tt                                                                                  --   15814
        end
    end
    return tt                                                                                                           --     256
end

-- Suffixes with no matching tiletype (single-connection stubs) become pillars.
local function wall_tt(suffix)                                                                                          --     561  0.008s
    return constructed_wall_by_suffix[suffix]                                                                           --     561
    -- SWD: the five special cases have been added to this table,
    --      so this fallback code is no longer necessary.
    --local tt = constructed_wall_by_suffix[suffix]
    --if tt then return tt end
    --return CONSTRUCTED_PILLAR_TT or CONSTRUCTED_WALL_TT
end

-- plant_type index → "floor" or "wall"; populated on first use.
local plant_role_cache = nil    ---@type table<integer, "floor"|"wall">

local S = rawget(_G, "__ruins_state")
if not S then
    S = {
        watcher_enabled     = false,
        watcher_gen         = 0,
        scan_gen            = 0,
        init_gen            = 0,
        processed_blocks    = {},
        last_site_id        = nil,
        biome_height_cache  = {},
        biome_mat_cache     = {},
        biome_floor_cache   = {},
        debug               = false,
        last_scan_x         = nil,
        last_scan_y         = nil,
    }
    _G.__ruins_state = S
end
S.debug = true  -- SWD: override during active development.

-- ============================================================================
-- LIBRARY FUNCTIONS
-- ============================================================================

-- SWD: string.format() moved into this function.  That's much better
--      than requiring every caller that needs formatting to do it itself.
local function log(msg, ...) print("[smoothfloor] " .. string.format(msg, ...)) end                                     --       7  0.005s

local function dlog(msg, ...) if S.debug then log("DIAG: " .. msg, ...) end end                                         --       3  0.006s (self 0.001s) [child 0.005s]

local function find_materials()
    local info = dfhack.matinfo.find(PLASTCRETE_TOKEN)
    if not info then
        log("%s not found in raws — ruins conversion disabled", PLASTCRETE_TOKEN)
        return false
    end
    PLASTCRETE_MAT_TYPE  = info.type
    PLASTCRETE_MAT_INDEX = info.index
    local sinfo = dfhack.matinfo.find(SUPERSTRUCTURE_TOKEN)
    if sinfo then
        SUPERSTRUCTURE_MAT_TYPE  = sinfo.type
        SUPERSTRUCTURE_MAT_INDEX = sinfo.index
    else
        log("%s not found — mountain/forest ruins will use plastcrete", SUPERSTRUCTURE_TOKEN)
        SUPERSTRUCTURE_MAT_TYPE  = PLASTCRETE_MAT_TYPE
        SUPERSTRUCTURE_MAT_INDEX = PLASTCRETE_MAT_INDEX
    end
    return true
end

local function build_plant_cache()                                                                                      --       9  0.002s
    plant_role_cache = {}
    local all = df.global.world.raws.plants.all
    local floors, walls = 0, 0
    for i = 0, #all - 1 do
        local id = tostring(all[i].id or "")
        if FLOOR_PLANT_IDS[id] then
            plant_role_cache[i] = "floor"
            floors = floors + 1
        elseif WALL_PLANT_IDS[id] then
            plant_role_cache[i] = "wall"
            walls = walls + 1
        end
    end
    dlog("plant cache built: floor_species=%d wall_species=%d", floors, walls)
end

--------------------------------------------------------------------------------
---@class key_xyz
---@field value unknown

--------------------------------------------------------------------------------
---@param x integer
---@param y integer
---@param z integer
---@return key_xyz
local function key_xyz(x, y, z)                                                                                         --   44313  0.404s
    ---@diagnostic disable-next-line: return-type-mismatch
    return ("%d,%d,%d"):format(x, y, z)                                                                                 --   44313
end

-- SWD: disabled.
---- Build a Lua table from a block list for O(1) block lookups without C++ calls.
--local function make_block_map(block_list)
--    local m = {}
--    for _, block in ipairs(block_list) do
--        m[block.map_pos.x .. "," .. block.map_pos.y .. "," .. block.map_pos.z] = block
--    end
--    return m
--end

--local function block_from_map(bmap, wx, wy, wz)
--      dfhack.maps.getTileBlock() is lightning fast compared to this,
--      even before factoring in the time to digest 10000 blocks into
--      the block_list.  in short, don't do it this way.
-- SWD: disabled.
--    return bmap[(wx - wx % 16) .. "," .. (wy - wy % 16) .. "," .. wz]
--end

local function is_player_map()
    if dfhack.world.isFortressMode and dfhack.world.isFortressMode() then return true end
    if dfhack.world.getCurrentSite then
        local site = dfhack.world.getCurrentSite()
        return site ~= nil and site.type == df.world_site_type.PlayerFortress
    end
    return false
end

-- prevents roads from being built over
local ROAD_KEYS = {
    "ZONE_ROAD_CENTER",
    "ZONE_ROAD_EXIT_NORTH",
    "ZONE_ROAD_EXIT_SOUTH",
    "ZONE_ROAD_EXIT_EAST",
    "ZONE_ROAD_EXIT_WEST",
}

-- SWD rewrote all of the logic in this.
local function build_road_set( --[[ block_map SWD disabled ]] )                                                         --       2  0.002s
    local bother    = df.global.world.buildings.other
    local tested    = {}    -- key_xyz == true  -- SWD added logic to skip multiple tests on any tiles instead of just skipping road tiles.
    local road_set  = {}    -- key_xyz == true
    local road_tiles= {}    -- flat: {x1,y1,z1, x2,y2,z2, ...}
    local queue     = {}    -- flat: {x1,y1,z1, x2,y2,z2, ...}  SWD converted this to flat array for speed

    local function seed(b)
        --dlog("road seed %d,%d,%d", b.x1, b.y1, b.z)
        for rx = b.x1, b.x2 do
            for ry = b.y1, b.y2 do
                table.insert(queue, rx); table.insert(queue, ry); table.insert(queue, b.z)
            end
        end
    end

    for _, key in ipairs(ROAD_KEYS) do
        local vec = bother[key]
        if vec then for _, b in ipairs(vec) do seed(b) end end
    end
    local any_road = bother.ANY_ROAD
    if any_road then for _, b in ipairs(any_road) do seed(b) end end

    local DF_tiletype_shape_FLOOR = df.tiletype_shape.FLOOR
    local DF_tiletype_shape_RAMP = df.tiletype_shape.RAMP
    local DF_tiletype_shape_RAMP_TOP = df.tiletype_shape.RAMP_TOP
    local dx = {-1, 1,  0, 0}
    local dy = { 0, 0, -1, 1}
    local i = 1
    while i <= #queue do
        -- probe this tile; if it is a road, record it and queue up the tiles around it.
        local x, y, z = queue[i], queue[i+1], queue[i+2]; i = i + 3
        local key = key_xyz(x, y, z)
        if tested[key] then goto continue end
        tested[key] = true
        local tt = dfhack.maps.getTileType(x, y, z) or OPEN_SPACE_TT
        local shape = df.tiletype.attrs[tt].shape

        -- only floors and ramps can be roads, but see below.
        if shape == DF_tiletype_shape_FLOOR or shape == DF_tiletype_shape_RAMP then
            local des, occ = dfhack.maps.getTileFlags(x, y, z)            
            if occ.no_grow and occ.building == 0 then
                road_set[key] = true
                table.insert(road_tiles, x); table.insert(road_tiles, y); table.insert(road_tiles, z)
                -- and queue up the orthoganal tiles to be tested.
                for d = 1, 4 do
                    local nx, ny = x + dx[d], y + dy[d]
                    local k = key_xyz(nx, ny, z)
                    if not tested[k] then
                        table.insert(queue, nx); table.insert(queue, ny); table.insert(queue, z)
                    end
                end
            end
        end
        -- for road ramps, check if the tile above is a ramp top, meaning this ramp usable.
        --   if so, mark the ramp top as tested and road, and also queue up its orthoganal tiles.
        if shape == DF_tiletype_shape_RAMP and road_set[key] then
            local zup = z + 1
            local keyup = key_xyz(x, y, zup)
            local ttup = dfhack.maps.getTileType(x, y, zup) or OPEN_SPACE_TT
            local shapeup = df.tiletype.attrs[ttup].shape
            if shapeup == DF_tiletype_shape_RAMP_TOP then
                tested[keyup] = true
                road_set[keyup] = true
                table.insert(road_tiles, x); table.insert(road_tiles, y); table.insert(road_tiles, zup)
                -- queue up the orthoganal tiles to be tested.
                for d = 1, 4 do
                    local nx, ny = x + dx[d], y + dy[d]
                    local k = key_xyz(nx, ny, zup)
                    if not tested[k] then
                        table.insert(queue, nx); table.insert(queue, ny); table.insert(queue, zup)
                    end
                end
            end
        end
        -- if it's a ramp top, queue up the ramp tile directly below.
        if shape == DF_tiletype_shape_RAMP_TOP then
            local keydown = key_xyz(x, y, z - 1)
            if not tested[keydown] then
                table.insert(queue, x); table.insert(queue, y); table.insert(queue, z - 1)
                -- the tile below will determine whether this tile is flagged as road.
            end
        end
        ::continue::
    end

    dlog("road_set built: %d tiles, tested %d tiles", #road_tiles / 3, #queue / 3)
    return road_set, road_tiles
end


local function build_existing_set()
    local existing = {}
    local constructions = df.global.world.event.constructions
    for i,c in ipairs(constructions) do
        existing[key_xyz(c.pos.x, c.pos.y, c.pos.z)] = true
    end
    dlog("existing set built: %d tiles", #constructions)
    return existing
end

-- Deterministic per-position hash.
-- Uses bit.band(h, 0x7FFFFFFF) instead of % 2147483647: equivalent to % 2^31,
-- one CPU instruction vs. a 64-bit division.  Hash outputs differ numerically
-- from the previous version, so saves will see different ruin geometry on reload.
local function hash_percent(x, y, z)                                                                                    --   77630  0.372s
    local h = 1234567                                                                                                   --   13349
    h = (h * 1103515245 + x + 12345) & 0x7FFFFFFF                                                                       --    4165
    h = (h * 1103515245 + y + 12345) & 0x7FFFFFFF                                                                       --   17397
    h = (h * 1103515245 + z + 12345) & 0x7FFFFFFF                                                                       --   26962
    return h % 100                                                                                                      --   15757
end

-- Returns the maximum wall height.
local function get_biome_max_height(wx, wy, wz)                                                                         --   46784  0.083s
    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)                                                              --   10938
    local ck     = rx .. "," .. ry                                                                                      --   11138
    if S.biome_height_cache[ck] then return S.biome_height_cache[ck] end                                                --   24708
    local btype  = dfhack.maps.getBiomeType(rx, ry)
    local max_h  = BIOME_MAX_HEIGHT[btype] or DEFAULT_MAX_HEIGHT
    S.biome_height_cache[ck] = max_h
    return max_h
end

-- Returns (mat_type, mat_index) for the construction material at (wx,wy,wz).
local function get_biome_mat(wx, wy, wz)                                                                                --   83295  0.232s
    local block = dfhack.maps.getTileBlock(wx, wy, wz)                                                                  --   10629
    if block and block.designation[wx % 16][wy % 16].subterranean then                                                  --   37635
        return SUPERSTRUCTURE_MAT_TYPE, SUPERSTRUCTURE_MAT_INDEX                                                        --   25408
    end

    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)                                                              --    2732
    local ck     = rx .. "," .. ry                                                                                      --    1964
    if S.biome_mat_cache[ck] then                                                                                       --    1559
        local m = S.biome_mat_cache[ck]                                                                                 --    1210
        return m[1], m[2]                                                                                               --    2157
    end
    local btype = dfhack.maps.getBiomeType(rx, ry)
    local mt, mi
    if SUPERSTRUCTURE_BIOMES[btype] then
        mt, mi = SUPERSTRUCTURE_MAT_TYPE, SUPERSTRUCTURE_MAT_INDEX
    else
        mt, mi = PLASTCRETE_MAT_TYPE, PLASTCRETE_MAT_INDEX
    end
    S.biome_mat_cache[ck] = { mt, mi }
    return mt, mi
end

-- True if walls should be degraded to floors
local function is_floor_only_biome(wx, wy, wz)                                                                          --   12485  0.056s
    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)                                                              --     509
    local ck     = rx .. "," .. ry                                                                                      --     737
    if S.biome_floor_cache[ck] ~= nil then return S.biome_floor_cache[ck] end                                           --   11235
    local btype  = dfhack.maps.getBiomeType(rx, ry)
    local result = FLOOR_ONLY_BIOMES[btype] or false
    S.biome_floor_cache[ck] = result
    return result
end

local function has_adjacent_door(wx, wy, wz)
    local dirs = {{-1,0},{1,0},{0,-1},{0,1}}
    for _, d in ipairs(dirs) do
        local bld = dfhack.buildings.findAtTile(wx + d[1], wy + d[2], wz)
        if bld and bld:getType() == df.building_type.Door then return true end
    end
    return false
end

-- Returns the target height for the tower 
local function get_tower_height(wx, wy, wz, max_h)                                                                      --    6242  0.033s (self 0.015s) [child 0.018s]
    local roll = hash_percent(wx + 31337, wy + 271, wz)                                                                 --     588
    return 1 + math.floor(roll * max_h / 100)                                                                           --    5654
end

-- True if the CONCRETE tile at (wx,wy,wz) will have an upper wall at z+tier.
local function will_have_tier(wx, wy, wz, wall_set, tier)                                                               --    2181  0.133s (self 0.054s) [child 0.080s]
    if not wall_set[key_xyz(wx, wy, wz)] then return false end                                                          --    1802
    local max_h = get_biome_max_height(wx, wy, wz)                                                                      --     107
    if tier > max_h - 1 then return false end                                                                           --      30
    return get_tower_height(wx, wy, wz, max_h) > tier                                                                   --     242
end

-- Collect positions of all CONCRETE grass tiles from a block list.
local function collect_wall_positions(block_list)                                                                       --   19684  0.424s (self 0.385s) [child 0.039s]
    local wall_set = {}
    for _, block in ipairs(block_list) do                                                                               --     272
        for _, ev in ipairs(block.block_events) do                                                                      --    1497
            if getmetatable(ev) == "block_square_event_grassst"                                                         --     784
                ---@cast ev df.block_square_event_grassst
                    and plant_role_cache[ev.plant_index] == "wall" then                                                 --      96
                for lx = 0, 15 do                                                                                       --     201
                    for ly = 0, 15 do                                                                                   --    3383
                        if ev.amount[lx][ly] > 0 then                                                                   --    9793
                            wall_set[key_xyz(                                                                           --     390
                                block.map_pos.x + lx,                                                                   --     573
                                block.map_pos.y + ly,                                                                   --     595
                                block.map_pos.z)] = true                                                                --    2100
                        end
                    end
                end
            end
        end
    end
    return wall_set
end

local DF_TILETYPE_MATERIAL_CONSTRUCTION = df.tiletype_material.CONSTRUCTION
local DF_TILETYPE_SHAPE_WALL            = df.tiletype_shape.WALL
local DF_TILETYPE_SHAPE_PILLAR          = df.tiletype_shape.PILLAR

local function is_constructed_wall_tt(tt)                                                                               --    4350  0.066s
    if not tt then return false end                                                                                     --     254
    local attrs = df.tiletype.attrs[tt]                                                                                 --    1086
    if not attrs then return false end                                                                                  --     933
    if attrs.material ~= DF_TILETYPE_MATERIAL_CONSTRUCTION then return false end                                        --    1305
    local s = attrs.shape                                                                                               --     162
    return s == DF_TILETYPE_SHAPE_WALL or s == DF_TILETYPE_SHAPE_PILLAR                                                 --     610
end

-- True if (wx,wy) is a wall neighbour at z-level zt:
-- either a CONCRETE grass tile or an already-converted ConstructedWall.
local function is_wall_neighbour(wx, wy, wz, wall_set)                                                                  --    7981  0.079s (self 0.051s) [child 0.028s]
    if wall_set[key_xyz(wx, wy, wz)] then return true end                                                               --    5790
    return is_constructed_wall_tt(dfhack.maps.getTileType(wx, wy, wz))                                                  --    2191
end

local function wall_suffix(wx, wy, wz, wall_set)                                                                        --   13465  0.175s (self 0.096s) [anon child 0.052s] [child 0.079s]
    local s = ""
    if is_wall_neighbour(wx - 1, wy,     wz, wall_set) then s = s .. "L" end                                            --   10418
    if is_wall_neighbour(wx + 1, wy,     wz, wall_set) then s = s .. "R" end                                            --     989
    if is_wall_neighbour(wx,     wy - 1, wz, wall_set) then s = s .. "U" end                                            --     268
    if is_wall_neighbour(wx,     wy + 1, wz, wall_set) then s = s .. "D" end                                            --    1658
    return s                                                                                                            --     115
end

-- Suffix for an upper tier at (wx,wy,wz+tier): checks which cardinal neighbours
-- will also have that tier (via hash), falling back to existing ConstructedWall
-- tiles at the same z+tier level for already-converted neighbours.
local function upper_wall_suffix(wx, wy, wz, wall_set, tier)                                                            --    1070  0.218s (self 0.024s) [anon child 0.014s] [child 0.194s]
    local zt = wz + tier                                                                                                --     187

    local function has_upper(nx, ny)
        if will_have_tier(nx, ny, wz, wall_set, tier) then return true end
        return is_constructed_wall_tt(dfhack.maps.getTileType(nx, ny, zt))
    end

    local s = ""                                                                                                        --      54
    if has_upper(wx - 1, wy    ) then s = s .. "L" end                                                                  --      35
    if has_upper(wx + 1, wy    ) then s = s .. "R" end                                                                  --     119
    if has_upper(wx,     wy - 1) then s = s .. "U" end                                                                  --     166
    if has_upper(wx,     wy + 1) then s = s .. "D" end                                                                  --     452
    return s                                                                                                            --      47
end

-- Zero all grass events at a specific tile in a block.
-- Prevents grass from re-triggering conversion if a construction is later demolished.
local function zero_grass_at(block, lx, ly)                                                                             --    2357  0.009s
    for _, ev in ipairs(block.block_events) do                                                                          --    2041
        if getmetatable(ev) == "block_square_event_grassst" then                                                        --     215
            ---@cast ev df.block_square_event_grassst
            ev.amount[lx][ly] = 0                                                                                       --      57
        end
    end
end                                                                                                                     --      44

-- Try to insert a wall construction at (wx,wy,wz). Returns true on success.
-- override_tt: if non-nil, sets the tiletype directly instead of computing a wall suffix.
local function insert_upper_wall(wx, wy, wz, existing, wall_set, tier, mat_type, mat_index, override_tt)                --  112736  0.515s (self 0.263s) [child 0.252s]
    local k = key_xyz(wx, wy, wz)                                                                                       --    1373
    if existing[k] then return false end                                                                                --    2079
    local block = dfhack.maps.getTileBlock(wx, wy, wz)                                                                  --    5855
    if not block then return false end                                                                                  --    1087
    local lx, ly = wx % 16, wy % 16                                                                                     --    2827
    local attrs = df.tiletype.attrs[block.tiletype[lx][ly]]                                                             --   12952
    if not attrs or attrs.material ~= df.tiletype_material.AIR then return false end                                    --   18250

    local c = df.construction:new()                                                                                     --    8627
    c.pos.x     = wx                                                                                                    --    4749
    c.pos.y     = wy                                                                                                    --    4983
    c.pos.z     = wz                                                                                                    --    5196
    c.mat_type  = mat_type                                                                                              --    2730
    c.mat_index = mat_index                                                                                             --    2748
    c.item_type = df.item_type.BLOCKS                                                                                   --   11277
    c.original_tile = original_tile_for(block.tiletype[lx][ly])                                                         --   14725
    c.flags.no_build_item = true                                                                                        --     216

    if not dfhack.constructions.insert(c) then return false end                                                         --     752

    existing[k] = true                                                                                                  --     137
    if override_tt then                                                                                                 --     139
        block.tiletype[lx][ly] = override_tt
    else
        local suffix = upper_wall_suffix(wx, wy, wz - tier, wall_set, tier)                                             --    1133
        local tt = wall_tt(suffix)                                                                                      --     295
        if tt then block.tiletype[lx][ly] = tt end                                                                      --    3201
    end
    zero_grass_at(block, lx, ly)                                                                                        --    7165
    return true                                                                                                         --     239
end

-- Insert a ConstructedFloor cap above the topmost wall tier.
-- This replicates what DF's normal wall-placement does automatically:
-- setting the tile directly above the wall to a walkable floor surface.
local function insert_cap_floor(wx, wy, wz, existing, mat_type, mat_index)                                              --   16511  0.156s (self 0.120s) [child 0.036s]
    local k = key_xyz(wx, wy, wz)                                                                                       --    2251
    if existing[k] then return end                                                                                      --     256
    local block = dfhack.maps.getTileBlock(wx, wy, wz)                                                                  --     970
    if not block then return end                                                                                        --     248
    local lx, ly = wx % 16, wy % 16                                                                                     --     505
    local attrs  = df.tiletype.attrs[block.tiletype[lx][ly]]                                                            --    2578
    if not attrs or attrs.material ~= df.tiletype_material.AIR then return end                                          --    3327
    local c = df.construction:new()                                                                                     --     903
    c.pos.x     = wx                                                                                                    --     515
    c.pos.y     = wy                                                                                                    --     547
    c.pos.z     = wz                                                                                                    --     574
    c.mat_type  = mat_type                                                                                              --     278
    c.mat_index = mat_index                                                                                             --     287
    c.item_type = df.item_type.BLOCKS                                                                                   --    1127
    c.original_tile = original_tile_for(block.tiletype[lx][ly])                                                         --    1622
    c.flags.no_build_item = true                                                                                        --      97
    if dfhack.constructions.insert(c) then                                                                              --     193
        existing[k] = true
        if CONSTRUCTED_FLOOR_TT then                                                                                    --      35
            block.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT                                                               --     107
        end
    end
end                                                                                                                     --      77

-- ── Span helpers ─────────────────────────────────────────────────────────────

-- Wall sections extending horizontally.
-- Two-pass: all tiles are inserted first (with a plain-wall placeholder tiletype), then
-- re-suffixed so each tile connects correctly to its neighbours. Fortification tiles are
local function do_wall_span(wx, wy, wz, dx, dy, existing, mat_type, mat_index)                                          --    7283  0.490s (self 0.227s) [child 0.263s]
    local placed = {}  -- { {nx, ny, is_fort}, ... }                                                                    --     311

    for step = 1, MAX_SPAN do                                                                                           --     337
        local nx, ny   = wx + dx * step, wy + dy * step                                                                 --     139
        local block    = dfhack.maps.getTileBlock(nx, ny, wz)                                                           --     452
        if not block then break end                                                                                     --      46
        local lx, ly   = nx % 16, ny % 16                                                                               --     132
        local attrs    = df.tiletype.attrs[block.tiletype[lx][ly]]                                                      --     392
        if not attrs or attrs.material ~= df.tiletype_material.AIR then break end                                       --     338
        if hash_percent(nx + 313, ny + 17, wz) < SPAN_WALL_GAP_PROB then break end                                      --     272
        local k = key_xyz(nx, ny, wz)                                                                                   --      98
        if not existing[k] then                                                                                         --      69
            local is_fort = CONSTRUCTED_FORTIFICATION_TT ~= nil                                                         --     146
                            and mat_type == SUPERSTRUCTURE_MAT_TYPE                                                     --      73
                            and mat_index == SUPERSTRUCTURE_MAT_INDEX                                                   --     130
                            and hash_percent(nx, ny + 500, wz) < SPAN_WALL_FORT_PROB                                    --      36
            local c = df.construction:new()                                                                             --     155
            c.pos.x = nx; c.pos.y = ny; c.pos.z = wz                                                                    --     105
            c.mat_type = mat_type; c.mat_index = mat_index                                                              --      54
            c.item_type = df.item_type.BLOCKS                                                                           --     232
            c.original_tile = original_tile_for(block.tiletype[lx][ly])                                                 --     198
            c.flags.no_build_item = true
            if dfhack.constructions.insert(c) then                                                                      --      27
                existing[k] = true
                block.tiletype[lx][ly] = CONSTRUCTED_WALL_TT  -- placeholder                                            --      93
                placed[#placed + 1] = { nx, ny, is_fort }                                                               --     282
            end
        end
    end

    -- Re-suffix every placed tile now that all span neighbours are in the map
    for _, p in ipairs(placed) do                                                                                       --     243
        local nx, ny, is_fort = p[1], p[2], p[3]                                                                        --     301
        local blk = dfhack.maps.getTileBlock(nx, ny, wz)                                                                --     544
        if blk then                                                                                                     --      86
            if is_fort then                                                                                             --      58
                blk.tiletype[nx % 16][ny % 16] = CONSTRUCTED_FORTIFICATION_TT
            else
                blk.tiletype[nx % 16][ny % 16] = wall_tt(wall_suffix(nx, ny, wz, {}))                                   --     810
            end
        end
    end
	
    for _, p in ipairs(placed) do                                                                                       --     366
        insert_cap_floor(p[1], p[2], wz + 1, existing, mat_type, mat_index)                                             --     719
    end
end                                                                                                                     --      30

-- Floor slabs with ragged side edges.
-- Support propagates horizontally from the tower wall through the connected floor chain
local function do_floor_span(wx, wy, wz, dx, dy, existing, mat_type, mat_index)                                         --   13533  0.873s (self 0.446s) [child 0.427s]
    local pdx, pdy = -dy, dx                                                                                            --     853

    local function try_floor(nx, ny)
        local blk = dfhack.maps.getTileBlock(nx, ny, wz)
        if not blk then return end
        local lx2, ly2 = nx % 16, ny % 16
        local at = df.tiletype.attrs[blk.tiletype[lx2][ly2]]
        if not at or at.material ~= df.tiletype_material.AIR then return end
        local k = key_xyz(nx, ny, wz)
        if existing[k] then return end
        local c = df.construction:new()
        c.pos.x = nx; c.pos.y = ny; c.pos.z = wz
        c.mat_type = mat_type; c.mat_index = mat_index
        c.item_type = df.item_type.BLOCKS
        c.original_tile = original_tile_for(blk.tiletype[lx2][ly2])
        c.flags.no_build_item = true
        if dfhack.constructions.insert(c) then
            existing[k] = true
            if CONSTRUCTED_FLOOR_TT then blk.tiletype[lx2][ly2] = CONSTRUCTED_FLOOR_TT end
        end
    end                                                                                                                 --      63

    for step = 1, MAX_SPAN do                                                                                           --     210
        local nx, ny = wx + dx * step, wy + dy * step                                                                   --     409
        local block  = dfhack.maps.getTileBlock(nx, ny, wz)                                                             --    1240
        if not block then break end                                                                                     --     229
        local lx, ly = nx % 16, ny % 16                                                                                 --     318
        local attrs  = df.tiletype.attrs[block.tiletype[lx][ly]]                                                        --    1157
        if not attrs or attrs.material ~= df.tiletype_material.AIR then break end                                       --     928
		
        local k = key_xyz(nx, ny, wz)                                                                                   --     466
        if not existing[k] then                                                                                         --     226
            local c = df.construction:new()                                                                             --     451
            c.pos.x = nx; c.pos.y = ny; c.pos.z = wz                                                                    --     692
            c.mat_type = mat_type; c.mat_index = mat_index                                                              --     259
            c.item_type = df.item_type.BLOCKS                                                                           --     387
            c.original_tile = original_tile_for(block.tiletype[lx][ly])                                                 --     684
            c.flags.no_build_item = true                                                                                --     226
            if dfhack.constructions.insert(c) then                                                                      --     698
                existing[k] = true                                                                                      --      69
                if CONSTRUCTED_FLOOR_TT then block.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT end                          --     618
            else
                break
            end
        end
		
        if existing[k] then                                                                                             --     236
            for _, side in ipairs({ 1, -1 }) do                                                                         --     872
                if hash_percent(nx + side * 200, ny + side * 100, wz) < SPAN_SIDE_PROB then                             --    1401
                    if hash_percent(nx + side * 200, ny + side * 300, wz) >= SPAN_SIDE_GAP_PROB then                    --     453
                        try_floor(nx + pdx * side, ny + pdy * side)                                                     --     343
                    end
                end
            end
        end
    end
end                                                                                                                     --      45

-- Catwalks: single-tile-wide floor chain

local function do_catwalk_span(wx, wy, wz, dx, dy, existing, mat_type, mat_index)                                       --   13456  0.596s (self 0.460s) [child 0.136s]
    for step = 1, MAX_SPAN do                                                                                           --    3093
        local nx, ny = wx + dx * step, wy + dy * step                                                                   --     810
        local block  = dfhack.maps.getTileBlock(nx, ny, wz)                                                             --    2323
        if not block then break end                                                                                     --     258
        local lx, ly = nx % 16, ny % 16                                                                                 --     613
        local attrs  = df.tiletype.attrs[block.tiletype[lx][ly]]                                                        --     887
        if not attrs or attrs.material ~= df.tiletype_material.AIR then break end                                       --    1409
        local k = key_xyz(nx, ny, wz)                                                                                   --     758
        if not existing[k] then                                                                                         --     518
            local c = df.construction:new()                                                                             --     666
            c.pos.x = nx; c.pos.y = ny; c.pos.z = wz                                                                    --     183
            c.mat_type = mat_type; c.mat_index = mat_index                                                              --     138
            c.item_type = df.item_type.BLOCKS                                                                           --     589
            c.original_tile = original_tile_for(block.tiletype[lx][ly])                                                 --     457
            c.flags.no_build_item = true                                                                                --      36
            if dfhack.constructions.insert(c) then                                                                      --     123
                existing[k] = true
                if CONSTRUCTED_FLOOR_TT then block.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT end                          --     516
            else
                break  
            end
        end
    end
end                                                                                                                     --      73

-- Four cardinal directions used by generate_spans.
local SPAN_DIRS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

-- Emit spans from every tier of a wall tower.

local function generate_spans(wx, wy, wz_base, actual_h, existing, mat_type, mat_index)                                 --  324992  2.656s (self 0.546s) [child 2.111s]
    local base_block     = dfhack.maps.getTileBlock(wx, wy, wz_base)                                                    --    1384
    local is_underground = base_block
                           and base_block.designation[wx % 16][wy % 16].subterranean                                    --    4046
    for tier = 0, actual_h do                                                                                           --    6608
        local frac    = actual_h > 0 and (tier / actual_h) or 0                                                         --    5574
        local wall_p  = math.floor(50 * (1 - frac) + 5  * frac + 0.5)                                                   --   18834
        local floor_p = math.floor(38 * (1 - math.abs(2 * frac - 1) ^ 1.4) + 0.5)                                       --   48938
        local ctw_p   = math.floor(5  * (1 - frac) + 35 * frac + 0.5)                                                   --   54037
        local wz      = wz_base + tier                                                                                  --    7213
        for dir_idx, dir in ipairs(SPAN_DIRS) do                                                                        --   40127
            local roll = hash_percent(wx * 4 + dir_idx + 77, wy + tier * 31, wz_base)                                   --   91747
            if roll < wall_p then                                                                                       --     749
                if not NO_WALL_SPANS and tier < actual_h and not is_underground then                                    --    2319
                    do_wall_span(wx, wy, wz, dir[1], dir[2], existing, mat_type, mat_index)                             --    2134
                end                                                                                                     --      27
            elseif roll < wall_p + floor_p then                                                                         --    2771
                if not NO_FLOOR_SPANS then                                                                              --     737
                    do_floor_span(wx, wy, wz, dir[1], dir[2], existing, mat_type, mat_index)                            --    5777
                end                                                                                                     --      35
            elseif roll < wall_p + floor_p + ctw_p then                                                                 --    8923
                if not NO_CATWALK_SPANS then                                                                            --    2810
                    do_catwalk_span(wx, wy, wz, dir[1], dir[2], existing, mat_type, mat_index)                          --   19709
                end
            end
        end
    end
end                                                                                                                     --     493

-- ─────────────────────────────────────────────────────────────────────────────

-- Scan one block, inserting construction records for fake-construction grass tiles.

local function scan_block(block, existing, wall_set, in_site, road_set)                                                 --  134439  5.967s (self 1.939s) [child 4.028s]
    local floors, walls, uppers = 0, 0, 0                                                                               --     484

    for _, ev in ipairs(block.block_events) do                                                                          --    1111
        if getmetatable(ev) == "block_square_event_grassst" then                                                        --     683
            ---@cast ev df.block_square_event_grassst
            local role = plant_role_cache[ev.plant_index]                                                               --      65
            if role then                                                                                                --      27
                for lx = 0, 15 do                                                                                       --     424
                    for ly = 0, 15 do                                                                                   --    6949
                        if ev.amount[lx][ly] > 0 then                                                                   --   25625
                            local wx = block.map_pos.x + lx                                                             --     828
                            local wy = block.map_pos.y + ly                                                             --    2020
                            local wz = block.map_pos.z                                                                  --     665
                            local k  = key_xyz(wx, wy, wz)                                                              --    2182
                            -- In NPC settlements, exclude tiles inside/covered by buildings.
                            -- Tiles adjacent to a door are allowed but forced to floors.
                            local in_site_excluded    = false                                                           --    4534
                            local in_site_force_floor = false                                                           --     510
                            if in_site and role == "wall" then                                                          --     379
                                local tt_attrs   = df.tiletype.attrs[block.tiletype[lx][ly]]
                                local shape      = tt_attrs and df.tiletype_shape.attrs[tt_attrs.shape]
                                local basic      = shape and shape.basic_shape
                                if existing[k]
                                    or basic == df.tiletype_shape_basic.Wall
                                    -- or basic == df.tiletype_shape_basic.Fortification    -- SWD: there is NO tiletype_shape_basic key named Fortification
                                    or shape == df.tiletype_shape.FORTIFICATION             -- SWD: fixed.  there IS a tiletype_shape.FORTIFICATION
                                    or block.occupancy[lx][ly].no_grow
                                    or not block.designation[lx][ly].outside
                                    or dfhack.buildings.findAtTile(wx, wy, wz) then
                                    ev.amount[lx][ly] = 0
                                    in_site_excluded = true
                                elseif has_adjacent_door(wx, wy, wz) then
                                    in_site_force_floor = true
                                end
                            end
                            if not in_site_excluded then                                                                --     282
                            if road_set and (road_set[k] or road_set[key_xyz(wx, wy, wz - 1)]) then                     --    6995
                                -- Road tile prevents ruin spawning
                                ev.amount[lx][ly] = 0
                            elseif block.occupancy[lx][ly].building == 0                                                --    2178
                                and not block.occupancy[lx][ly].no_grow then                                            --    2296
                                if existing[k] then                                                                     --    1602
								
                                    ev.amount[lx][ly] = 0
                                else
                                local bmt, bmi = get_biome_mat(wx, wy, wz)                                              --    2265
                                local c = df.construction:new()                                                         --   11686
                                c.pos.x     = wx                                                                        --     502
                                c.pos.y     = wy                                                                        --     154
                                c.pos.z     = wz                                                                        --     172
                                c.mat_type  = bmt                                                                       --     103
                                c.mat_index = bmi                                                                       --      95
                                c.item_type = df.item_type.BLOCKS                                                       --    4699
                                c.original_tile = original_tile_for(block.tiletype[lx][ly])                             --    7843
                                c.flags.no_build_item = true                                                            --      34
                                if dfhack.constructions.insert(c) then                                                  --     187
                                    existing[k] = true                                                                  --      27
                                    ev.amount[lx][ly] = 0  -- prevents re-conversion                                    --    5325
                                    local tt_attrs2   = df.tiletype.attrs[block.tiletype[lx][ly]]                       --    7259
                                    local shape_attr2 = tt_attrs2 and df.tiletype_shape.attrs[tt_attrs2.shape]          --    2612
                                    local basic2      = shape_attr2 and shape_attr2.basic_shape                         --    2228
                                    if basic2 == df.tiletype_shape_basic.Ramp then                                      --    2254
                                        if CONSTRUCTED_RAMP_TT then
                                            block.tiletype[lx][ly] = CONSTRUCTED_RAMP_TT
                                        end
                                        floors = floors + 1
                                    elseif role == "floor" or is_floor_only_biome(wx, wy, wz) or in_site_force_floor then--    2659
                                        if CONSTRUCTED_FLOOR_TT then                                                    --     230
                                            block.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT                               --     385
                                        end
                                        floors = floors + 1
                                    else
                                        -- Height must be known before is_stair so height-1
                                        local max_h    = get_biome_max_height(wx, wy, wz)                               --    1623
                                        local target_h = get_tower_height(wx, wy, wz, max_h)                            --    5700
                                        local is_stair = CONSTRUCTED_STAIR_UD_TT ~= nil                                 --    1660
                                                         and CONSTRUCTED_STAIR_UP_TT ~= nil
                                                         and target_h > 1
                                                         and hash_percent(wx, wy, wz) < STAIR_PROB                      --    5154
                                        local is_fort  = not is_stair
                                                         and CONSTRUCTED_FORTIFICATION_TT ~= nil
                                                         and bmt == SUPERSTRUCTURE_MAT_TYPE
                                                         and bmi == SUPERSTRUCTURE_MAT_INDEX
                                                         and hash_percent(wx, wy + 1, wz) < FORT_PROB                   --    1587
														 
                                        local override_tt = is_stair and CONSTRUCTED_STAIR_UD_TT
                                                           or is_fort and CONSTRUCTED_FORTIFICATION_TT
                                                           or nil
                                        if is_stair then
                                            block.tiletype[lx][ly] = CONSTRUCTED_STAIR_UP_TT
                                        elseif override_tt then
                                            block.tiletype[lx][ly] = override_tt
                                        else
                                            local suffix = wall_suffix(wx, wy, wz, wall_set)
                                            if wall_tt(suffix) then                                                     --     153
                                                block.tiletype[lx][ly] = wall_tt(suffix)                                --     172
                                            end
                                        end
                                        walls = walls + 1


                                        local cap_z    = wz + 1
                                        for tier = 1, target_h - 1 do                                                   --     636
                                            if insert_upper_wall(wx, wy, wz + tier, existing, wall_set, tier, bmt, bmi, override_tt) then--    2291
                                                uppers = uppers + 1
                                                cap_z  = wz + tier + 1                                                  --     100
                                            else
                                                break
                                            end
                                        end
										
                                        if not is_stair then                                                            --     204
                                            insert_cap_floor(wx, wy, cap_z, existing, bmt, bmi)                         --    1245
                                        elseif CONSTRUCTED_STAIR_DOWN_TT and cap_z - 1 > wz then
                                            local top_block = dfhack.maps.getTileBlock(wx, wy, cap_z - 1)
                                            if top_block then
                                                top_block.tiletype[wx % 16][wy % 16] = CONSTRUCTED_STAIR_DOWN_TT
                                            end
                                        end
                                        local spans_h = is_stair and (cap_z - 1 - wz) or (cap_z - wz)                   --    1610
                                        generate_spans(wx, wy, wz, spans_h, existing, bmt, bmi)                         --     881
                                    end
                                end
                                end  -- else (not existing)
                            end
                            end  -- not in_site_excluded
                        end
                    end
                end
            end
        end
    end

    return floors, walls, uppers                                                                                        --     780
end

local function get_site_id()                                                                                            --       1  0.002s
    if dfhack.world.getCurrentSite then
        local site = dfhack.world.getCurrentSite()
        if site then return site.id end
    end
    return -1
end

-- True only when inside an NPC settlement (town, dark fortress, etc.).
-- Player fortresses are excluded so ruins convert normally on embark.
local function is_npc_site()
    if not dfhack.world.getCurrentSite then return false end
    local site = dfhack.world.getCurrentSite()
    if not site then return false end
    if site.type == df.world_site_type.PlayerFortress then return false end
    return true
end

local function convert_ruins(force)                                                                                     --    3889  6.501s (self 0.097s) [anon child 0.003s] [child 6.404s]
    if not dfhack.isMapLoaded() then return end
    if not PLASTCRETE_MAT_TYPE and not find_materials() then return end
    if not plant_role_cache then build_plant_cache() end

    local site_id = get_site_id()
    if force or site_id ~= S.last_site_id then
        S.processed_blocks = {}
        S.last_site_id = site_id
    end

    local all_blocks = df.global.world.map.map_blocks
    --local block_map  = make_block_map(all_blocks)     -- SWD disabled
    local in_site    = is_npc_site()

    -- Pass 1: collect CONCRETE wall positions for wall-suffix computation.
    local runtime = -getTimestamp()
    local wall_set = collect_wall_positions(all_blocks)
    runtime = (runtime + getTimestamp()) / getTimestampDivisor()
    dlog("pass 1 collect_wall_positions runtime: %0.3f seconds", runtime)
    dlog("pass 1 #wall_set = %d", (function(t)local c=0;for _ in pairs(t)do c=c+1;end;return c;end)(wall_set))          --     417  0.003s--     417

    -- Pass 2: build road set 
    runtime = -getTimestamp()
    local existing  = build_existing_set()
    runtime = (runtime + getTimestamp()) / getTimestampDivisor()
    dlog("pass 2a build_existing_set runtime: %0.3f seconds", runtime)
    --dlog("pass 2a #existing = %d", (function(t)local c=0;for _ in pairs(t)do c=c+1;end;return c;end)(existing))
    runtime = -getTimestamp()
    local road_set  = build_road_set( --[[ block_map SWD disabled ]] )
    runtime = (runtime + getTimestamp()) / getTimestampDivisor()
    dlog("pass 2b build_road_set runtime: %0.3f seconds", runtime)
    --dlog("pass 2b #road_set = %d", (function(t)local c=0;for _ in pairs(t)do c=c+1;end;return c;end)(road_set))

    -- Pass 3: convert unprocessed ruins blocks.
    runtime = -getTimestamp()
    local tf, tw, tu = 0, 0, 0
    for _, block in ipairs(all_blocks) do                                                                               --     244
        local bk = ("%d,%d,%d"):format(block.map_pos.x, block.map_pos.y, block.map_pos.z)                               --    1392
        if not S.processed_blocks[bk] then                                                                              --     317
            S.processed_blocks[bk] = true                                                                               --     213
            local f, w, u = scan_block(block, existing, wall_set, in_site, road_set)                                    --     927
            tf = tf + f; tw = tw + w; tu = tu + u                                                                       --     793
        end
    end
    runtime = (runtime + getTimestamp()) / getTimestampDivisor()
    dlog("pass3 scan_block runtime: %0.3f seconds", runtime)

    if tf + tw > 0 then
        log("Converted ruins: floors=%d walls=%d uppers=%d", tf, tw, tu)
    end
end

local function scan_nearby()
    if not dfhack.isMapLoaded() then return end
    if is_player_map() then return end
    if not PLASTCRETE_MAT_TYPE then return end
    if not plant_role_cache then return end

    local adv = dfhack.world and dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if not adv or not adv.pos then return end

    local cx, cy, cz = adv.pos.x, adv.pos.y, adv.pos.z
    local r   = SCAN_RADIUS
    local bx0 = cx - r - ((cx - r) % 16)
    local by0 = cy - r - ((cy - r) % 16)

    -- Scan up and down
    local nearby_blocks = {}
    for bx = bx0, cx + r, 16 do
        for by = by0, cy + r, 16 do
            for dz = -10, 40 do
                local block = dfhack.maps.getTileBlock(bx, by, cz - dz)
                if block then nearby_blocks[#nearby_blocks + 1] = block end
            end
        end
    end

    --local block_map             = make_block_map(nearby_blocks)   -- SWD disabled
    local in_site               = is_npc_site()
    local wall_set              = collect_wall_positions(nearby_blocks)
    local existing  = build_existing_set()
    local road_set  = build_road_set( --[[ block_map SWD disabled ]] )

    --  scan all nearby blocks 
    local floors, walls, uppers = 0, 0, 0
    for _, block in ipairs(nearby_blocks) do
        local bk = ("%d,%d,%d"):format(block.map_pos.x, block.map_pos.y, block.map_pos.z)
        S.processed_blocks[bk] = true
        local f, w, u = scan_block(block, existing, wall_set, in_site, road_set)
        floors = floors + f; walls = walls + w; uppers = uppers + u
    end

    if floors + walls > 0 then
        dlog("scan_nearby: floors=%d walls=%d uppers=%d", floors, walls, uppers)
    end

    S.last_scan_x = cx
    S.last_scan_y = cy
end

local function scan_tick(gen)
    if not S.watcher_enabled then return end
    if gen ~= S.scan_gen then return end
    -- Detect fast-travel
    local delay = SCAN_INTERVAL_TICKS
    local adv = dfhack.world and dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos and S.last_scan_x then
        local dx = adv.pos.x - S.last_scan_x
        local dy = adv.pos.y - S.last_scan_y
        if dx*dx + dy*dy > (SCAN_RADIUS * SCAN_RADIUS / 4) then
            delay = 30
        end
    end
    scan_nearby()
    dfhack.timeout(delay, "ticks", function() scan_tick(gen) end)
end

local function start_watcher()
    if S.watcher_enabled then return end
    S.watcher_enabled = true
    S.scan_gen = S.scan_gen + 1
    scan_tick(S.scan_gen)
end

local function stop_watcher()
    S.watcher_enabled = false
    S.scan_gen = S.scan_gen + 1
end

local function schedule_initial()
    S.init_gen = S.init_gen + 1
    local gen  = S.init_gen
    dfhack.timeout(INITIAL_DELAY_TICKS, "ticks", function()
        if gen ~= S.init_gen then return end
        convert_ruins(true)
    end)
end

clocktime = (clocktime + getTimestamp()) / getTimestampDivisor()
dlog("startup clocktime: %0.6f seconds", clocktime)

local args = { ... }
local cmd  = args[1] or "enable"

if cmd == "enable" then
    convert_ruins(false)
    start_watcher()
    schedule_initial()
elseif cmd == "force" then
    local clocktime = -getTimestamp()
    convert_ruins(true)
    clocktime = (clocktime + getTimestamp()) / getTimestampDivisor()
    dlog("force clocktime: %0.3f seconds", clocktime)
elseif cmd == "disable" then
    S.init_gen = S.init_gen + 1
    stop_watcher()
    S.processed_blocks = {}
    S.last_site_id = nil
elseif cmd == "status" then
    log("watcher=%s mat_found=%s floor_tt=%s wall_tt=%s stair_ud_tt=%s fort_tt=%s",
        tostring(S.watcher_enabled),
        tostring(PLASTCRETE_MAT_TYPE ~= nil),
        tostring(CONSTRUCTED_FLOOR_TT),
        tostring(CONSTRUCTED_WALL_TT),
        tostring(CONSTRUCTED_STAIR_UD_TT),
        tostring(CONSTRUCTED_FORTIFICATION_TT))
elseif cmd == "debug" then
    S.debug = not S.debug
    log("Debug %s", (S.debug and "ON" or "OFF"))
elseif cmd == "debug-roads" then
    -- Diagnostic: report what road-related buildings/data are visible from Lua.
    local bother = df.global.world.buildings.other
    for _, key in ipairs(ROAD_KEYS) do
        local vec = bother[key]
        local n = vec and #vec or -1
        log("ZONE %s: %d buildings", key, n)
        if vec and n > 0 then
            for i = 0, math.min(2, n - 1) do
                local b = vec[i]
                log("  [%d] x=%d..%d y=%d..%d z=%d", i, b.x1, b.x2, b.y1, b.y2, b.z)
            end
        end
    end
    local any_road = bother.ANY_ROAD
    log("ANY_ROAD: %d buildings", any_road and #any_road or -1)
    -- Report road_set tile count
    local road_set = build_road_set()
    local n = 0; for _ in pairs(road_set) do n = n + 1 end
    log("road_set total tiles: %d", n)
    -- Report adventurer tile details
    local adv = dfhack.world and dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos then
        local wx, wy, wz = adv.pos.x, adv.pos.y, adv.pos.z
        log("Adventurer at %d,%d,%d — in road_set: %s",
            wx, wy, wz, tostring(road_set[key_xyz(wx, wy, wz)] == true))
        local block = dfhack.maps.getTileBlock(wx, wy, wz)
        if block then
            local lx, ly = wx % 16, wy % 16
            local occ    = block.occupancy[lx][ly]
            local tt     = block.tiletype[lx][ly]
            local attrs  = df.tiletype.attrs[tt]
            log("  tiletype=%s material=%s",
                tostring(df.tiletype[tt]),
                attrs and tostring(df.tiletype_material[attrs.material]) or "?")
            log("  occupancy.building=%s no_grow=%s",
                tostring(occ.building), tostring(occ.no_grow))
        end
        local bld = dfhack.buildings.findAtTile(wx, wy, wz)
        log("  findAtTile: %s",
            bld and tostring(df.building_type[bld:getType()]) or "nil")
        ---@diagnostic disable-next-line: missing-fields
        local zones = dfhack.buildings.findCivzonesAt({x=wx, y=wy, z=wz})
        if zones and #zones > 0 then
            for _, z in ipairs(zones) do
                log("  findCivzonesAt: civzone_type=%s",
                    tostring(df.civzone_type[z.type]))
            end
        else
            log("  findCivzonesAt: none")
        end
    end
else
    log("Usage: ruins [enable|force|disable|status|debug|debug-roads]")
end
myprofiler.stop(); if profile then myprofiler.generate(dfhack.current_script_name(), profile); end