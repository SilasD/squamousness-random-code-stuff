-- ruins_smoothfloor.lua

--   ruins_smoothfloor enable
--   ruins_smoothfloor disable
--   ruins_smoothfloor force
--   ruins_smoothfloor status

local INITIAL_DELAY_TICKS  = 120
local SCAN_INTERVAL_TICKS  = 3

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

local SMOOTH_FLOOR_TT = (function()
    for i = 0, 65535 do
        local a = df.tiletype.attrs[i]
        if a and a.material == STONE_MAT and a.special == SPECIAL_SMOOTH then
            local sa = df.tiletype_shape.attrs[a.shape]
            if sa and sa.basic_shape == BASIC_FLOOR then return i end
        end
    end
end)()

local SMOOTH_LAVA_FLOOR_TT = (function()
    for i = 0, 65535 do
        local a = df.tiletype.attrs[i]
        if a and a.material == LAVA_STONE_MAT and a.special == SPECIAL_SMOOTH then
            local sa = df.tiletype_shape.attrs[a.shape]
            if sa and sa.basic_shape == BASIC_FLOOR then return i end
        end
    end
end)()

local smooth_stone_wall_by_suffix = {}
local smooth_lava_wall_by_suffix  = {}
local smooth_stone_wall_fallback  = nil  -- "" suffix = isolated pillar
local smooth_lava_wall_fallback   = nil

do
    for i = 0, 65535 do
        local name  = df.tiletype[i]
        local attrs = df.tiletype.attrs[i]
        if name and attrs and attrs.special == SPECIAL_SMOOTH and attrs.shape == SHAPE_WALL then
            local sname = tostring(name)
            local suf = sname:match("^StoneWallSmooth([LRUD]*)$")
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
end


-- Per-tiletype kind lookup built once at load

local smooth_stone_wall_tt_set = {}
local smooth_lava_wall_tt_set  = {}
for _, i in pairs(smooth_stone_wall_by_suffix) do smooth_stone_wall_tt_set[i] = true end
if smooth_lava_wall_by_suffix ~= smooth_stone_wall_by_suffix then
    for _, i in pairs(smooth_lava_wall_by_suffix) do smooth_lava_wall_tt_set[i] = true end
end

local tt_kind = (function()
    local t = {}
    for i = 0, 65535 do
        local a = df.tiletype.attrs[i]
        if a then
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
        end
    end
    return t
end)()

-- ============================================================================
-- STATE
-- ============================================================================

local S = rawget(_G, "__smoothfloor_state")
if not S then
    S = {
        watcher_enabled  = false,
        scan_gen         = 0,
        init_gen         = 0,
        processed_blocks = {},
        last_site_id     = nil,
        last_block_count = 0,
        biome_cache      = {},
    }
    _G.__smoothfloor_state = S
end
if S.scan_gen         == nil then S.scan_gen         = 0 end
if S.init_gen         == nil then S.init_gen         = 0 end
if S.last_block_count == nil then S.last_block_count = 0 end

local function log(msg) print("[smoothfloor] " .. msg) end

-- ============================================================================
-- INORGANIC CACHE
-- ============================================================================

local smooth_inorganic_cache = nil

local function build_inorganic_cache()
    smooth_inorganic_cache = {}
    local count = 0
    local all   = df.global.world.raws.inorganics.all
    for i = 0, #all - 1 do
        local mat = all[i].material
        for _, rc in pairs(mat.reaction_class) do
            local cfg = SMOOTH_CLASSES[rc.value]
            if cfg then
                smooth_inorganic_cache[i] = cfg
                count = count + 1
                break
            end
        end
    end
    log(("inorganic cache built: %d matching"):format(count))
end

-- ============================================================================
-- BIOME CACHE
-- ============================================================================

-- Cached by biome region
local function get_biome_for_tile(wx, wy, wz)
    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)
    if not rx then return nil end
    local key = rx .. "," .. ry
    local v   = S.biome_cache[key]
    if v ~= nil then return v ~= false and v or nil end
    local ri = dfhack.maps.getRegionBiome(rx, ry)
    if not ri then S.biome_cache[key] = false; return nil end
    local b = df.world_geo_biome.find(ri.geo_index)
    if b then S.biome_cache[key] = b; return b end
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
                if block.designation[lx][ly].hidden then
                    has_hidden = true
                else
                    local b = get_biome_for_tile(bx+lx, by+ly, bz)
                    if b then
                        local layer = b.layers[block.designation[lx][ly].geolayer_index]
                        local cfg = layer and smooth_inorganic_cache[layer.mat_index]
                        if not cfg then
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

    local site_id = get_site_id()
    if force or site_id ~= S.last_site_id then
        S.processed_blocks  = {}
        S.last_site_id      = site_id
        S.last_block_count  = 0
    end

    local tf, tw = 0, 0
    for _, block in ipairs(df.global.world.map.map_blocks) do
        local bk = ("%d,%d,%d"):format(block.map_pos.x, block.map_pos.y, block.map_pos.z)
        if not S.processed_blocks[bk] then
            local f, w, partial = scan_block(block, force)
            if not partial then S.processed_blocks[bk] = true end
            tf = tf + f; tw = tw + w
        end
    end

    if tf + tw > 0 then
        log(("Smoothed: floors=%d walls=%d"):format(tf, tw))
    end
end

-- ============================================================================
-- WATCHER
-- ============================================================================

local function stop_watcher()
    S.watcher_enabled = false
    S.scan_gen        = S.scan_gen + 1
end

-- Checks block count every 3 ticks; only runs convert_all when DF has loaded new chunks.
local function scan_tick(gen)
    if not S.watcher_enabled then return end
    if gen ~= S.scan_gen     then return end
    if not is_player_map() and dfhack.isMapLoaded() then
        local n = #df.global.world.map.map_blocks
        if n ~= S.last_block_count then
            S.last_block_count = n
            convert_all(false)
        end
    end
    dfhack.timeout(SCAN_INTERVAL_TICKS, 'ticks', function() scan_tick(gen) end)
end

local function start_watcher()
    if S.watcher_enabled then return end
    S.watcher_enabled = true
    S.scan_gen        = S.scan_gen + 1
    scan_tick(S.scan_gen)
end

local function schedule_initial()
    S.init_gen    = S.init_gen + 1
    local gen     = S.init_gen
    dfhack.timeout(INITIAL_DELAY_TICKS, 'ticks', function()
        if gen ~= S.init_gen then return end
        convert_all(false)
    end)
end

-- ============================================================================
-- COMMANDS
-- ============================================================================

local args = { ... }
local cmd  = args[1] or "enable"

if cmd == "enable" then
    if not smooth_inorganic_cache then build_inorganic_cache() end
    convert_all(false)
    start_watcher()
    schedule_initial()
elseif cmd == "force" then
    if not smooth_inorganic_cache then build_inorganic_cache() end
    convert_all(true)
elseif cmd == "disable" then
    stop_watcher()
    smooth_inorganic_cache = nil
    S.processed_blocks     = {}
    S.last_site_id         = nil
    S.last_block_count     = 0
    S.biome_cache          = {}
elseif cmd == "status" then
    local n = 0; for _ in pairs(smooth_stone_wall_by_suffix) do n = n + 1 end
    log(("watcher=%s cache=%s floor_tt=%s wall_variants=%d"):format(
        tostring(S.watcher_enabled),
        tostring(smooth_inorganic_cache ~= nil),
        tostring(SMOOTH_FLOOR_TT),
        n))
else
    log("Usage: ruins_smoothfloor [enable|disable|force|status]")
end
