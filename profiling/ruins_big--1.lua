do dfhack.printerr("attempt to run a profiled script!"); return; end;  local profile = "1"; myprofiler = reqscript("myprofiler"); myprofiler.stop(); if profile then _G.__ruins_big_state = nil; myprofiler.start(); end -- ruins_big.lua
-- Pre-pass megastructure generator. Must fire before ruins.lua so that placed
-- walls are visible as ConstructedWall neighbours during LRUD suffix computation.
--
-- AUTOLOAD ORDER: list before ruins.lua. Timers: 60/100 ticks (ruins: 120/150).
--
-- ADDING A PATTERN:
--   1. Declare local ENABLED_<NAME> = true/false before the pattern block.
--   2. Write   local function run_<name>(wall_set, pos_list, existing, road_set)
--      No-op when disabled. Check road_set before placement. Add every placed
--      tile to existing. No state shared between patterns.
--   3. Call run_<name>(wall_set, pos_list, existing, road_set) in generate_megastructures,
--      after the in_site guard.

local PLASTCRETE_TOKEN     = "INORGANIC:PLASTCRETE_ID_NULL"
local SUPERSTRUCTURE_TOKEN = "INORGANIC:SUPERSTRUCTURE_ID_NULL"
local INITIAL_DELAY_TICKS  = 60
local SCAN_INTERVAL_TICKS  = 100
local SCAN_RADIUS          = 96

local WALL_PLANT_IDS = { CONCRETE=true, CONCRETE2=true, CONCRETE3=true }

local SUPERSTRUCTURE_BIOMES = {
    [df.biome_type.FOREST_TAIGA]                    = true,
    [df.biome_type.FOREST_TEMPERATE_CONIFER]        = true,
    [df.biome_type.FOREST_TEMPERATE_BROADLEAF]      = true,
    [df.biome_type.FOREST_TROPICAL_CONIFER]         = true,
    [df.biome_type.FOREST_TROPICAL_DRY_BROADLEAF]   = true,
    [df.biome_type.FOREST_TROPICAL_MOIST_BROADLEAF] = true,
}

local PLASTCRETE_MAT_TYPE
local PLASTCRETE_MAT_INDEX
local SUPERSTRUCTURE_MAT_TYPE
local SUPERSTRUCTURE_MAT_INDEX

-- ── Tiletype constants ────────────────────────────────────────────────────────

local CONSTRUCTED_FLOOR_TT         = df.tiletype.ConstructedFloor
local CONSTRUCTED_PILLAR_TT        = df.tiletype.ConstructedPillar
local CONSTRUCTED_FORTIFICATION_TT = df.tiletype.ConstructedFortification
local SOIL_FLOOR_TT                = df.tiletype.SoilFloor1

local MAT_CONSTRUCTION = df.tiletype_material.CONSTRUCTION
local MAT_AIR          = df.tiletype_material.AIR
local SHAPE_BASIC_WALL = df.tiletype_shape_basic.Wall
local SHAPE_PILLAR     = df.tiletype_shape.PILLAR

-- Maps LRUD suffix string → tiletype int (81 combinations).
local constructed_wall_by_suffix = {}
do
    for _, L in ipairs{'', 'L', 'L2'} do
        for _, R in ipairs{'', 'R', 'R2'} do
            for _, U in ipairs{'', 'U', 'U2'} do
                for _, D in ipairs{'', 'D', 'D2'} do
                    local suffix = L .. R .. U .. D
                    local num = df.tiletype["ConstructedWall" .. suffix]
                    if num then constructed_wall_by_suffix[suffix] = num end
                end
            end
        end
    end
    -- Isolated wall (0 or 1 neighbour) maps to pillar
    for _, suffix in ipairs{'', 'L', 'R', 'U', 'D'} do
        constructed_wall_by_suffix[suffix] = CONSTRUCTED_PILLAR_TT
    end
end

local CONSTRUCTED_WALL_TT = df.tiletype.ConstructedWallLRUD

-- ── State ─────────────────────────────────────────────────────────────────────

local S = rawget(_G, "__ruins_big_state")
if not S then
    S = {
        watcher_enabled    = false,
        scan_gen           = 0,
        init_gen           = 0,
        processed_clusters = {},
        biome_mat_cache    = {},
        last_scan_x        = nil,
        last_scan_y        = nil,
        existing           = nil,
        debug              = false,
    }
    _G.__ruins_big_state = S
end

local function log(msg) print("[ruins_big] " .. msg) end
local function dlog(fn) if S.debug then log("DIAG: " .. fn()) end end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function find_materials()
    local info = dfhack.matinfo.find(PLASTCRETE_TOKEN)
    if not info then
        log(PLASTCRETE_TOKEN .. " not found — ruins_big disabled")
        return false
    end
    PLASTCRETE_MAT_TYPE  = info.type
    PLASTCRETE_MAT_INDEX = info.index
    local sinfo = dfhack.matinfo.find(SUPERSTRUCTURE_TOKEN)
    if sinfo then
        SUPERSTRUCTURE_MAT_TYPE  = sinfo.type
        SUPERSTRUCTURE_MAT_INDEX = sinfo.index
    else
        SUPERSTRUCTURE_MAT_TYPE  = PLASTCRETE_MAT_TYPE
        SUPERSTRUCTURE_MAT_INDEX = PLASTCRETE_MAT_INDEX
    end
    return true
end

local function key_xyz(x, y, z)                                                                                         --    3581  0.016s
    return (z * 16384 + y) * 16384 + x                                                                                  --    3581
end

local function hash_percent(x, y, z)
    local mod = 2147483647
    local h   = 1234567
    h = (h * 1103515245 + x + 12345) % mod
    h = (h * 1103515245 + y + 12345) % mod
    h = (h * 1103515245 + z + 12345) % mod
    return h % 100
end

local function original_tile_for(tt)
    local a = df.tiletype.attrs[tt]
    if a then
        local m = a.material
        if m == df.tiletype_material.GRASS_DARK or m == df.tiletype_material.GRASS_LIGHT then
            return SOIL_FLOOR_TT or tt
        end
    end
    return tt
end

local function wall_tt(suffix)
    return constructed_wall_by_suffix[suffix] or CONSTRUCTED_WALL_TT
end

local function get_biome_mat(wx, wy, wz)
    local block = dfhack.maps.getTileBlock(wx, wy, wz)
    if block and block.designation[wx % 16][wy % 16].subterranean then
        return SUPERSTRUCTURE_MAT_TYPE, SUPERSTRUCTURE_MAT_INDEX
    end
    local rx, ry = dfhack.maps.getTileBiomeRgn(wx, wy, wz)
    local ck = rx .. "," .. ry
    if S.biome_mat_cache[ck] then
        local m = S.biome_mat_cache[ck]; return m[1], m[2]
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

-- Includes unconverted CONCRETE neighbours (wall_set) alongside map tiletypes.
local function wall_suffix_at(wx, wy, wz, wall_set)
    local function has_wall(nx, ny)
        if wall_set and wall_set[key_xyz(nx, ny, wz)] then return true end
        local tt = dfhack.maps.getTileType(nx, ny, wz)
        if not tt then return false end
        local attrs = df.tiletype.attrs[tt]
        if not attrs or attrs.material ~= MAT_CONSTRUCTION then return false end
        local sh = attrs.shape
        return sh == SHAPE_PILLAR
               or df.tiletype_shape.attrs[sh].basic_shape == SHAPE_BASIC_WALL
    end
    local s = ""
    if has_wall(wx - 1, wy    ) then s = s .. "L" end
    if has_wall(wx + 1, wy    ) then s = s .. "R" end
    if has_wall(wx,     wy - 1) then s = s .. "U" end
    if has_wall(wx,     wy + 1) then s = s .. "D" end
    return s
end

-- Plant index → is-wall; rebuilt on first use each session.
local plant_wall_cache = nil
local function get_plant_wall_cache()                                                                                   --       8  0.000s
    if plant_wall_cache then return plant_wall_cache end
    plant_wall_cache = {}
    local all = df.global.world.raws.plants.all
    for i = 0, #all - 1 do
        if WALL_PLANT_IDS[tostring(all[i].id or "")] then
            plant_wall_cache[i] = true
        end
    end
    return plant_wall_cache
end

-- Returns wall_set (key → true) and pos_list ({x,y,z} entries) simultaneously,
-- eliminating the key-parse round-trip that run_tower_cluster previously needed.
local function collect_wall_positions(block_list)                                                                       --   20611  0.342s (self 0.325s) [child 0.017s]
    local cache    = get_plant_wall_cache()
    local wall_set = {}
    local pos_list = {}
    for _, block in ipairs(block_list) do                                                                               --     253
        for _, ev in ipairs(block.block_events) do                                                                      --    1530
            if getmetatable(ev) == "block_square_event_grassst" and cache[ev.plant_index] then                          --     864
                local bx, by, bz = block.map_pos.x, block.map_pos.y, block.map_pos.z                                    --      62
                for lx = 0, 15 do                                                                                       --     226
                    for ly = 0, 15 do                                                                                   --    3229
                        if ev.amount[lx][ly] > 0 then                                                                   --    9954
                            local wx = bx + lx                                                                          --     207
                            local wy = by + ly                                                                          --     138
                            local k  = key_xyz(wx, wy, bz)                                                              --    1015
                            if not wall_set[k] then                                                                     --    1440
                                wall_set[k] = true                                                                      --     308
                                pos_list[#pos_list + 1] = { x = wx, y = wy, z = bz }                                    --    1385
                            end
                        end
                    end
                end
            end
        end
    end
    return wall_set, pos_list
end

-- Cached construction set; updated in-place as new constructions are placed.
local function get_existing_set()
    if S.existing then return S.existing end
    local existing      = {}
    local constructions = df.global.world.event.constructions
    for i = 0, #constructions - 1 do
        local c = constructions[i]
        existing[key_xyz(c.pos.x, c.pos.y, c.pos.z)] = true
    end
    S.existing = existing
    return existing
end

local function is_npc_site()
    if not dfhack.world.getCurrentSite then return false end
    local site = dfhack.world.getCurrentSite()
    if not site then return false end
    if site.type == df.world_site_type.PlayerFortress then return false end
    return true
end

-- Seed-only road exclusion from civzone road buildings; no BFS.
-- ruins.lua's full BFS covers the CONCRETE tile pass.
local function build_road_set_light()
    local road_set = {}
    local bother   = df.global.world.buildings.other
    local keys = {
        "ZONE_ROAD_CENTER", "ZONE_ROAD_EXIT_NORTH", "ZONE_ROAD_EXIT_SOUTH",
        "ZONE_ROAD_EXIT_EAST", "ZONE_ROAD_EXIT_WEST",
    }
    for _, key in ipairs(keys) do
        local vec = bother[key]
        if vec then
            for _, b in ipairs(vec) do
                if b and b.x1 then
                    for rx = b.x1, b.x2 do
                        for ry = b.y1, b.y2 do
                            road_set[key_xyz(rx, ry, b.z)] = true
                        end
                    end
                end
            end
        end
    end
    return road_set
end

-- ── PATTERN: TOWER_CLUSTER ────────────────────────────────────────────────────
-- Clusters nearby CONCRETE tower bases and connects them with curtain walls.
-- Ground-level only; ruins.lua's span system bridges the towers at upper tiers.
local ENABLED_TOWER_CLUSTER = true

local TC_CLUSTER_RADIUS  = 28  -- max Chebyshev (x,y) distance to group two CONCRETE tiles
local TC_CLUSTER_Z_RANGE =  3  -- max z difference within a cluster
local TC_MIN_SIZE        =  8  -- minimum cluster members to qualify
local TC_MAX_SIZE        = 300 -- maximum cluster members to qualify
local TC_CONNECT_RADIUS  = 22  -- max Chebyshev (x,y) to draw a segment between two towers
local TC_GAP_PROB        = 15  -- % chance a column is a gap (applies to full wall width)
local TC_FORT_PROB       = 10  -- % chance a wall tile is a fortification
local TC_SPAWN_PROB      = 50  -- % of qualifying clusters that receive a megastructure

local function cluster_positions(pos_list)                                                                              -- 3294495  33.765s (self 31.764s) [child 2.001s]
    local n      = #pos_list
    local parent = {}
    for i = 1, n do parent[i] = i end                                                                                   --     100

    local function find(i)                                                                                              --  231452  2.001s
        while parent[i] ~= i do                                                                                         --   95677
            parent[i] = parent[parent[i]]                                                                               --   85561
            i = parent[i]                                                                                               --   33721
        end
        return i                                                                                                        --   16493
    end

    for i = 1, n do                                                                                                     --      52
        local p = pos_list[i]                                                                                           --      50
        for j = i + 1, n do                                                                                             --  250443
            local q = pos_list[j]                                                                                       --  249465
            if math.abs(p.z - q.z) <= TC_CLUSTER_Z_RANGE                                                                -- 1976372
               and math.abs(p.x - q.x) <= TC_CLUSTER_RADIUS                                                             --  496820
               and math.abs(p.y - q.y) <= TC_CLUSTER_RADIUS then                                                        --  179289
                local pi, pj = find(i), find(j)                                                                         --  120571
                if pi ~= pj then parent[pi] = pj end                                                                    --   20665
            end
        end
    end

    local groups = {}
    for i = 1, n do                                                                                                     --      75
        local root = find(i)                                                                                            --     101
        if not groups[root] then groups[root] = {} end                                                                  --     158
        local g = groups[root]                                                                                          --      84
        g[#g + 1] = pos_list[i]                                                                                         --     250
    end
    return groups
end

-- Checks, creates, and inserts a construction at an AIR tile. Returns block,lx,ly on success.
local function try_place(wx, wy, wz, existing, mt, mi)
    local k = key_xyz(wx, wy, wz)
    if existing[k] then return nil end
    local block = dfhack.maps.getTileBlock(wx, wy, wz)
    if not block then return nil end
    local lx, ly = wx % 16, wy % 16
    local attrs = df.tiletype.attrs[block.tiletype[lx][ly]]
    if not attrs or attrs.material ~= MAT_AIR then return nil end
    local c = df.construction:new()
    c.pos.x = wx; c.pos.y = wy; c.pos.z = wz
    c.mat_type = mt; c.mat_index = mi
    c.item_type = df.item_type.BLOCKS
    c.original_tile = original_tile_for(block.tiletype[lx][ly])
    c.flags.no_build_item = true
    if dfhack.constructions.insert(c) then
        existing[k] = true
        return block, lx, ly
    end
    return nil
end

-- Floor cap at wz+1; gives walls a walkable top surface.
local function place_cap(wx, wy, wz, existing, mt, mi)
    local blk, lx, ly = try_place(wx, wy, wz + 1, existing, mt, mi)
    if blk then blk.tiletype[lx][ly] = CONSTRUCTED_FLOOR_TT end
end

-- Lowest air tile above solid ground, searching ±4 z from z_ref.
local function terrain_z(wx, wy, z_ref)
    for _, dz in ipairs({ 0, -1, 1, -2, 2, -3, 3, -4, 4 }) do
        local wz  = z_ref + dz
        local blk = dfhack.maps.getTileBlock(wx, wy, wz)
        if blk then
            local lx, ly = wx % 16, wy % 16
            local at = df.tiletype.attrs[blk.tiletype[lx][ly]]
            if at and at.material == MAT_AIR then
                local bdn = dfhack.maps.getTileBlock(wx, wy, wz - 1)
                if bdn then
                    local ad = df.tiletype.attrs[bdn.tiletype[lx][ly]]
                    if ad and ad.material ~= MAT_AIR then
                        return wz
                    end
                end
            end
        end
    end
    return nil
end

-- Draws a Bresenham segment from (x0,y0) to (x1,y1), 2-5 tiles thick.
-- Returns 6 flat parallel arrays (x, y, z, is_fort, mat_type, mat_index) and count n.
-- Using flat arrays instead of a table-of-tables avoids per-tile GC pressure.
local function draw_segment(x0, y0, z0, x1, y1, cx, cy, wall_set, existing, road_set, mat_type, mat_index)
    local px_a, py_a, pz_a   = {}, {}, {}
    local pf_a, pmt_a, pmi_a = {}, {}, {}
    local pn = 0

    if x0 == x1 and y0 == y1 then return px_a, py_a, pz_a, pf_a, pmt_a, pmi_a, pn end

    local ldx = x1 - x0
    local ldy = y1 - y0
    local len = math.sqrt(ldx * ldx + ldy * ldy)
    local px  = -ldy / len   -- perpendicular unit vector (left of travel)
    local py  =  ldx / len

    local thick = 2 + hash_percent(x0 + x1 + 3, y0 + y1 + 7, z0) % 4

    -- Cross product: positive → centroid is on the (px,py) side → inward.
    local cross      = ldx * (cy - y0) - ldy * (cx - x0)
    local inward_pos = cross >= 0

    local bias_roll = hash_percent(x0 * 3 + x1, y0 + y1 * 3 + 5, z0) % 3
    local off_min, off_max
    if bias_roll == 0 then        -- inward
        off_min = inward_pos and 0 or -(thick - 1)
        off_max = inward_pos and  (thick - 1) or 0
    elseif bias_roll == 1 then    -- outward
        off_min = inward_pos and -(thick - 1) or 0
        off_max = inward_pos and 0 or  (thick - 1)
    else                          -- centered
        off_min = -math.floor((thick - 1) / 2)
        off_max =  math.ceil((thick - 1) / 2)
    end

    local dx  =  math.abs(x1 - x0)
    local dy  = -math.abs(y1 - y0)
    local sx  = x0 < x1 and 1 or (x0 > x1 and -1 or 0)
    local sy  = y0 < y1 and 1 or (y0 > y1 and -1 or 0)
    local err = dx + dy
    local x, y = x0, y0

    while true do
        local is_endpoint = (x == x0 and y == y0) or (x == x1 and y == y1)

        if not is_endpoint and hash_percent(x + 991, y + 77, z0) >= TC_GAP_PROB then
            for off = off_min, off_max do
                local nx = math.floor(x + px * off + 0.5)
                local ny = math.floor(y + py * off + 0.5)
                if not wall_set[key_xyz(nx, ny, z0)] then
                    local wz = terrain_z(nx, ny, z0)
                    if wz and not road_set[key_xyz(nx, ny, wz)] then
                        local is_fort = CONSTRUCTED_FORTIFICATION_TT ~= nil
                                        and hash_percent(nx + 313, ny + 500, wz) < TC_FORT_PROB
                        local blk, lx, ly = try_place(nx, ny, wz, existing, mat_type, mat_index)
                        if blk then
                            blk.tiletype[lx][ly] = CONSTRUCTED_WALL_TT
                            pn = pn + 1
                            px_a[pn] = nx;      py_a[pn] = ny;        pz_a[pn] = wz
                            pf_a[pn] = is_fort; pmt_a[pn] = mat_type; pmi_a[pn] = mat_index
                        end
                    end
                end
            end
        end

        if x == x1 and y == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x = x + sx end
        if e2 <= dx then err = err + dx; y = y + sy end
    end

    return px_a, py_a, pz_a, pf_a, pmt_a, pmi_a, pn
end

local function process_cluster(cluster, wall_set, existing, road_set)
    local cx, cy, cz = 0, 0, 0
    for _, p in ipairs(cluster) do cx = cx + p.x; cy = cy + p.y; cz = cz + p.z end
    cx = cx / #cluster; cy = cy / #cluster; cz = math.floor(cz / #cluster + 0.5)

    local ck = key_xyz(math.floor(cx + 0.5), math.floor(cy + 0.5), cz)
    if S.processed_clusters[ck] then return 0 end
    S.processed_clusters[ck] = true  -- marked before spawn roll; never re-evaluated

    if hash_percent(math.floor(cx + 0.5), math.floor(cy + 0.5), cz) >= TC_SPAWN_PROB then
        return 0
    end

    table.sort(cluster, function(a, b)
        return math.atan2(a.y - cy, a.x - cx) < math.atan2(b.y - cy, b.x - cx)
    end)

    -- Accumulate all segment placements in flat parallel arrays.
    local ax_a, ay_a, az_a   = {}, {}, {}
    local af_a, amt_a, ami_a = {}, {}, {}
    local an = 0

    for i = 1, #cluster do
        local a = cluster[i]
        local b = cluster[i % #cluster + 1]
        if math.abs(a.x - b.x) <= TC_CONNECT_RADIUS
           and math.abs(a.y - b.y) <= TC_CONNECT_RADIUS then
            local bmt, bmi = get_biome_mat(a.x, a.y, a.z)
            local sx, sy, sz, sf, smt, smi, sn =
                draw_segment(a.x, a.y, a.z, b.x, b.y, cx, cy,
                             wall_set, existing, road_set, bmt, bmi)
            for j = 1, sn do
                an = an + 1
                ax_a[an] = sx[j]; ay_a[an] = sy[j]; az_a[an] = sz[j]
                af_a[an] = sf[j]; amt_a[an] = smt[j]; ami_a[an] = smi[j]
            end
        end
    end

    -- Re-suffix after all segments are placed so LRUD reads correct neighbours.
    for i = 1, an do
        local wx, wy, wz = ax_a[i], ay_a[i], az_a[i]
        local blk = dfhack.maps.getTileBlock(wx, wy, wz)
        if blk then
            if af_a[i] then
                blk.tiletype[wx % 16][wy % 16] = CONSTRUCTED_FORTIFICATION_TT
            else
                blk.tiletype[wx % 16][wy % 16] = wall_tt(wall_suffix_at(wx, wy, wz, wall_set))
            end
        end
    end

    for i = 1, an do
        place_cap(ax_a[i], ay_a[i], az_a[i], existing, amt_a[i], ami_a[i])
    end

    return an
end

local function run_tower_cluster(wall_set, pos_list, existing, road_set)                                                --       1  33.765s (self 0.000s) [child 33.765s]
    if not ENABLED_TOWER_CLUSTER then return end
    if #pos_list == 0 then return end

    local groups             = cluster_positions(pos_list)
    local total, n_clusters  = 0, 0

    for _, group in pairs(groups) do
        if #group >= TC_MIN_SIZE and #group <= TC_MAX_SIZE then
            total      = total + process_cluster(group, wall_set, existing, road_set)
            n_clusters = n_clusters + 1
        end
    end

    if total > 0 then
        dlog(function() return ("tower_cluster: %d clusters → %d walls"):format(n_clusters, total) end)
    end
end

-- ── Main entry ────────────────────────────────────────────────────────────────

local function generate_megastructures(wall_set, pos_list, existing, in_site, road_set)                                 --       0  33.765s (self 0.000s) [child 33.765s]
    if in_site then return end
    run_tower_cluster(wall_set, pos_list, existing, road_set)
    -- future patterns: run_<name>(wall_set, pos_list, existing, road_set)
end

-- ── Scan system ───────────────────────────────────────────────────────────────

local function convert_big(force)                                                                                       --       1  34.107s (self 0.000s) [child 34.106s]
    if not dfhack.isMapLoaded() then return end
    if not PLASTCRETE_MAT_TYPE and not find_materials() then return end
    if is_npc_site() then return end

    if force then
        S.processed_clusters = {}
        S.existing = nil
    end

    local all_blocks         = df.global.world.map.map_blocks
    local wall_set, pos_list = collect_wall_positions(all_blocks)
    local existing           = get_existing_set()
    local road_set           = build_road_set_light()

    generate_megastructures(wall_set, pos_list, existing, false, road_set)
end

local function scan_nearby_big()
    if not dfhack.isMapLoaded() then return end
    if is_npc_site() then return end
    if not PLASTCRETE_MAT_TYPE then return end

    local adv = dfhack.world and dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if not adv or not adv.pos then return end

    local cx, cy, cz = adv.pos.x, adv.pos.y, adv.pos.z
    local r = SCAN_RADIUS

    -- Iterate already-loaded blocks instead of probing a grid with getTileBlock.
    local nearby = {}
    for _, block in ipairs(df.global.world.map.map_blocks) do
        local p = block.map_pos
        if math.abs(p.x - cx) <= r + 16 and math.abs(p.y - cy) <= r + 16
           and p.z >= cz - 10 and p.z <= cz then
            nearby[#nearby + 1] = block
        end
    end

    local wall_set, pos_list = collect_wall_positions(nearby)
    local existing           = get_existing_set()
    local road_set           = build_road_set_light()

    generate_megastructures(wall_set, pos_list, existing, false, road_set)

    S.last_scan_x = cx
    S.last_scan_y = cy
end

local function scan_tick(gen)
    if not S.watcher_enabled then return end
    if gen ~= S.scan_gen then return end
    local delay = SCAN_INTERVAL_TICKS
    local adv = dfhack.world and dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos and S.last_scan_x then
        local dx = adv.pos.x - S.last_scan_x
        local dy = adv.pos.y - S.last_scan_y
        if dx * dx + dy * dy > (SCAN_RADIUS * SCAN_RADIUS / 4) then delay = 20 end
    end
    scan_nearby_big()
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
        convert_big(true)
    end)
end

-- ── Command dispatch ──────────────────────────────────────────────────────────

local args = { ... }
local cmd  = args[1] or "enable"

if cmd == "enable" then
    convert_big(false)
    start_watcher()
    schedule_initial()
elseif cmd == "force" then
    convert_big(true)
elseif cmd == "disable" then
    S.init_gen = S.init_gen + 1
    stop_watcher()
    S.processed_clusters = {}
    S.existing = nil
elseif cmd == "status" then
    log(("watcher=%s mat_found=%s tower_cluster=%s"):format(
        tostring(S.watcher_enabled),
        tostring(PLASTCRETE_MAT_TYPE ~= nil),
        tostring(ENABLED_TOWER_CLUSTER)))
elseif cmd == "debug" then
    S.debug = not S.debug
    log("Debug " .. (S.debug and "ON" or "OFF"))
else
    log("Usage: ruins_big [enable|force|disable|status|debug]")
end
myprofiler.stop(); if profile then myprofiler.generate(dfhack.current_script_name(), profile); end