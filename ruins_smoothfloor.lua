-- ruins_smoothfloor.lua

--   ruins_smoothfloor enable
--   ruins_smoothfloor disable
--   ruins_smoothfloor force
--   ruins_smoothfloor status

local SCAN_INTERVAL_TICKS  = 3
local BLOCKS_PER_TICK      = 20
local VISIBLE_BLOCK_RADIUS = 2   -- 2 blocks = 32 tiles; safely covers the DF adventure viewport

local SMOOTH_ID_PREFIXES = {
    { prefix = "HEAVY_STRUCTURE_",  cfg = { floor=true, wall=true  } },
    { prefix = "MEDIAN_STRUCTURE_", cfg = { floor=true, wall=true  } },
    { prefix = "LIGHT_STRUCTURE_",  cfg = { floor=true, wall=true  } },
    { prefix = "BASIC_MACHINERY_",  cfg = { floor=true, wall=false } },
}

-- ============================================================================
-- TILETYPE CONSTANTS
-- ============================================================================

local STONE_MAT        = df.tiletype_material.STONE
local LAVA_STONE_MAT   = df.tiletype_material.LAVA_STONE
local MINERAL_MAT      = df.tiletype_material.MINERAL
local SHAPE_WALL       = df.tiletype_shape.WALL
local SPECIAL_SMOOTH   = df.tiletype_special.SMOOTH
local BASIC_FLOOR      = df.tiletype_shape_basic.Floor

local SMOOTH_FLOOR_TT      = df.tiletype.StoneFloorSmooth
local SMOOTH_LAVA_FLOOR_TT = df.tiletype.LavaFloorSmooth
local SOIL_MAT             = df.tiletype_material.SOIL
local BASIC_OPEN           = df.tiletype_shape_basic.Open

-- Pre-cached function references for tight loops (~150µs per dfhack./df. dereference avoided)
local maps_getTileBiomeRgn   = dfhack.maps.getTileBiomeRgn
local maps_getRegionBiome    = dfhack.maps.getRegionBiome
local maps_getTileBlock      = dfhack.maps.getTileBlock
local maps_getTileType       = dfhack.maps.getTileType
local maps_getTileAssignment = dfhack.maps.getTileAssignment
local geo_biome_find         = df.world_geo_biome.find
local tiletype_attrs         = df.tiletype.attrs
local shape_attrs            = df.tiletype_shape.attrs

local smooth_stone_wall_by_suffix = {}
local smooth_lava_wall_by_suffix  = {}
local smooth_stone_wall_fallback  = df.tiletype.StonePillar
local smooth_lava_wall_fallback   = df.tiletype.LavaPillar
local smooth_stone_wall_tt_set    = {}
local smooth_lava_wall_tt_set     = {}

for _, pair in ipairs{ {"Stone", smooth_stone_wall_by_suffix}, {"Lava", smooth_lava_wall_by_suffix} } do
    local prefix, tbl = pair[1], pair[2]
    for _, L in ipairs{"", "L"} do for _, R in ipairs{"", "R"} do
    for _, U in ipairs{"", "U"} do for _, D in ipairs{"", "D"} do
        local suffix = L..R..U..D
        local num = df.tiletype[prefix.."WallSmooth"..suffix]
        if num then tbl[suffix] = num end
    end end end end
end

if next(smooth_lava_wall_by_suffix) == nil then
    smooth_lava_wall_by_suffix = smooth_stone_wall_by_suffix
    smooth_lava_wall_fallback  = smooth_stone_wall_fallback
end

for _, i in pairs(smooth_stone_wall_by_suffix) do smooth_stone_wall_tt_set[i] = true end
if smooth_lava_wall_by_suffix ~= smooth_stone_wall_by_suffix then
    for _, i in pairs(smooth_lava_wall_by_suffix) do smooth_lava_wall_tt_set[i] = true end
end

-- Per-tiletype kind lookup built once at load
local tt_kind = (function()
    local t = {}
    for i, _ in ipairs(df.tiletype) do
        local a     = df.tiletype.attrs[i]
        local mat   = a.material
        local sa    = df.tiletype_shape.attrs[a.shape]
        local basic = sa and sa.basic_shape
        if a.special ~= SPECIAL_SMOOTH then
            if mat == STONE_MAT then
                if basic == BASIC_FLOOR     then t[i] = 'sf'
                elseif a.shape == SHAPE_WALL then t[i] = 'sw' end
            elseif mat == LAVA_STONE_MAT then
                if basic == BASIC_FLOOR     then t[i] = 'lf'
                elseif a.shape == SHAPE_WALL then t[i] = 'lw' end
            elseif mat == MINERAL_MAT then
                if basic == BASIC_FLOOR     then t[i] = 'mf'
                elseif a.shape == SHAPE_WALL then t[i] = 'mw' end
            end
        elseif a.shape == SHAPE_WALL then
            if smooth_stone_wall_tt_set[i] then
                t[i] = 'sw_r'
            elseif smooth_lava_wall_tt_set[i] then
                t[i] = 'lw_r'
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
        watcher_enabled    = false,
        scan_gen           = 0,
        bfs_queue          = {},
        bfs_head           = 1,
        bfs_tail           = 0,
        bfs_seen           = {},
        bfs_done           = {},
        bfs_block_count    = 0,
        current_timeout_id = -1,
        fort_rescan_idx    = 0,
    }
    _G.__smoothfloor_state = S
end
if S.scan_gen           == nil then S.scan_gen           = 0  end
if S.bfs_queue          == nil then S.bfs_queue          = {} end
if S.bfs_head           == nil then S.bfs_head           = 1  end
if S.bfs_tail           == nil then S.bfs_tail           = 0  end
if S.bfs_seen           == nil then S.bfs_seen           = {} end
if S.bfs_done           == nil then S.bfs_done           = {} end
if S.bfs_block_count    == nil then S.bfs_block_count    = 0  end
if S.current_timeout_id == nil then S.current_timeout_id = -1 end
if S.fort_rescan_idx    == nil then S.fort_rescan_idx    = 0  end

local function log(msg, ...) print("[smoothfloor] " .. string.format(msg, ...)) end

-- ============================================================================
-- INORGANIC CACHE
-- ============================================================================

local smooth_inorganic_cache = nil

local function build_inorganic_cache()
    smooth_inorganic_cache = {}
    local count = 0
    for i, m in ipairs(df.global.world.raws.inorganics.all) do
        for _, entry in ipairs(SMOOTH_ID_PREFIXES) do
            if m.id:sub(1, #entry.prefix) == entry.prefix then
                smooth_inorganic_cache[i] = entry.cfg
                count = count + 1
                break
            end
        end
    end
    log("inorganic cache built: %d matching", count)
end

-- ============================================================================
-- BIOME LOOKUP
-- ============================================================================

local function get_biome_for_tile(wx, wy, wz)
    local rx, ry = maps_getTileBiomeRgn(wx, wy, wz)
    if not rx then return nil end
    local ri = maps_getRegionBiome(rx, ry)
    if not ri then return nil end
    return geo_biome_find(ri.geo_index)
end

-- ============================================================================
-- WALL SUFFIX HELPERS
-- ============================================================================

local function wall_at(nx, ny, nz)
    local tt = maps_getTileType(nx, ny, nz)
    local a  = tt and tiletype_attrs[tt]
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
    if not smooth_inorganic_cache then return 0, 0 end
    local floors, walls = 0, 0
    local bx = block.map_pos.x
    local by = block.map_pos.y
    local bz = block.map_pos.z

    -- Mineral event cfg: DF display priority — cluster_one(4) > cluster_small(3) > vein(2) > cluster(1).
    -- Equal-priority ties: last in block_events list wins (matches DF behaviour per tile-material.lua).
    local mine_cfg = {}
    local mine_pri = {}
    local function vein_priority(ev)
        if ev.flags.cluster_one   then return 4
        elseif ev.flags.cluster_small then return 3
        elseif ev.flags.vein          then return 2
        else                               return 1
        end
    end
    for _, ev in ipairs(block.block_events) do
        if getmetatable(ev) == "block_square_event_mineralst" then
            local c = smooth_inorganic_cache[ev.inorganic_mat]
            local p = vein_priority(ev)
            for lx2 = 0, 15 do
                for ly2 = 0, 15 do
                    if maps_getTileAssignment(ev.tile_bitmask, lx2, ly2) then
                        if not mine_pri[lx2] then mine_pri[lx2] = {} end
                        local cur = mine_pri[lx2][ly2]
                        if not cur or p >= cur then
                            mine_pri[lx2][ly2] = p
                            if c then
                                if not mine_cfg[lx2] then mine_cfg[lx2] = {} end
                                mine_cfg[lx2][ly2] = c
                            elseif mine_cfg[lx2] then
                                mine_cfg[lx2][ly2] = nil
                            end
                        end
                    end
                end
            end
        end
    end

    for lx = 0, 15 do
        for ly = 0, 15 do
            local tt   = block.tiletype[lx][ly]
            local kind = tt_kind[tt]
            if kind == 'sf' or kind == 'sw' or kind == 'lf' or kind == 'lw'
               or kind == 'mf' or kind == 'mw' then
                if not block.designation[lx][ly].hidden then
                    local cfg
                    if kind == 'mf' or kind == 'mw' then
                        cfg = mine_cfg[lx] and mine_cfg[lx][ly]
                    else
                        -- STONE/LAVA: look up each tile's own biome and geolayer directly.
                        -- Per-tile (not per-block) so tiles near biome boundaries are correct.
                        local b = get_biome_for_tile(bx + lx, by + ly, bz)
                        if b then
                            local layer = b.layers[block.designation[lx][ly].geolayer_index]
                            if layer then cfg = smooth_inorganic_cache[layer.mat_index] end
                        end
                        -- Surface floor geolayer is unreliable (reflects debris layer, not actual rock).
                        -- Probe downward: pass through soil walls and floor-like tiles until the first
                        -- stone/lava wall, whose geolayer identifies the actual geological material.
                        if not cfg and (kind == 'sf' or kind == 'lf') and block.designation[lx][ly].outside then
                            for depth = 1, 10 do
                                local bb = maps_getTileBlock(bx+lx, by+ly, bz-depth)
                                if not bb then break end
                                local sub_tt  = bb.tiletype[lx][ly]
                                local sub_a   = tiletype_attrs[sub_tt]
                                local sub_mat = sub_a.material
                                local sub_shp = sub_a.shape
                                if sub_shp == SHAPE_WALL then
                                    if sub_mat == STONE_MAT or sub_mat == LAVA_STONE_MAT then
                                        local bbiome = get_biome_for_tile(bx+lx, by+ly, bz-depth)
                                        if bbiome then
                                            local bl = bbiome.layers[bb.designation[lx][ly].geolayer_index]
                                            if bl then cfg = smooth_inorganic_cache[bl.mat_index] end
                                        end
                                        break
                                    elseif sub_mat == SOIL_MAT then
                                        -- soil wall: pass through, keep probing
                                    elseif sub_mat == MINERAL_MAT then
                                        -- mineral wall: geolayer_index is reliable here (not a surface tile)
                                        local bbiome = get_biome_for_tile(bx+lx, by+ly, bz-depth)
                                        if bbiome then
                                            local bl = bbiome.layers[bb.designation[lx][ly].geolayer_index]
                                            if bl then cfg = smooth_inorganic_cache[bl.mat_index] end
                                        end
                                        break
                                    else
                                        break  -- construction, etc.
                                    end
                                else
                                    local sub_sa    = shape_attrs[sub_shp]
                                    local sub_basic = sub_sa and sub_sa.basic_shape
                                    if sub_basic ~= BASIC_FLOOR then
                                        break  -- open space, ramp, stair, etc.
                                    end
                                    -- floor-like tile: keep probing down
                                end
                            end
                        end
                        if not cfg then cfg = mine_cfg[lx] and mine_cfg[lx][ly] end
                    end
                    local floor_ok = cfg and cfg.floor
                    local wall_ok  = cfg and cfg.wall
                    if (kind == 'sf' or kind == 'lf' or kind == 'mf') and floor_ok then
                        local ftt = (kind == 'lf') and SMOOTH_LAVA_FLOOR_TT or SMOOTH_FLOOR_TT
                        if ftt then block.tiletype[lx][ly] = ftt end
                        floors = floors + 1
                    elseif (kind == 'sw' or kind == 'lw' or kind == 'mw') and wall_ok then
                        local tbl = (kind == 'lw') and smooth_lava_wall_by_suffix or smooth_stone_wall_by_suffix
                        local fb  = (kind == 'lw') and smooth_lava_wall_fallback  or smooth_stone_wall_fallback
                        local wtt = pick_smooth_wall_tt(tbl, fb, bx+lx, by+ly, bz)
                        if wtt then block.tiletype[lx][ly] = wtt end
                        walls = walls + 1
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

    return floors, walls
end

local function is_player_map()
    if dfhack.world.isFortressMode and dfhack.world.isFortressMode() then return true end
    local site = dfhack.world.getCurrentSite and dfhack.world.getCurrentSite()
    return site ~= nil and site.type == df.world_site_type.PlayerFortress
end

local function player_block_pos()
    local adv = dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if not adv or not adv.pos then return nil end
    local px, py, pz = adv.pos.x, adv.pos.y, adv.pos.z
    return px - (px % 16), py - (py % 16), pz
end

local function smooth_visible_area()
    if not dfhack.isMapLoaded() then return end
    local pbx, pby, pbz = player_block_pos()
    if not pbx then return end
    local tf, tw = 0, 0
    for dbx = -VISIBLE_BLOCK_RADIUS, VISIBLE_BLOCK_RADIUS do
        for dby = -VISIBLE_BLOCK_RADIUS, VISIBLE_BLOCK_RADIUS do
            for dbz = -1, 1 do
                local block = maps_getTileBlock(
                    pbx + dbx * 16, pby + dby * 16, pbz + dbz)
                if block then
                    local f, w = scan_block(block, false)
                    tf = tf + f; tw = tw + w
                end
            end
        end
    end
    if tf + tw > 0 then
        log("smooth_visible_area: floors=%d walls=%d", tf, tw)
    end
end

-- One-time scan: smooths all currently exposed eligible underground stone.
-- Called once at enable for fortress mode.
local function scan_all_subterranean()
    if not dfhack.isMapLoaded() then return end
    local blocks = df.global.world.map.map_blocks
    local tf, tw = 0, 0
    for i = 0, #blocks - 1 do
        local block = blocks[i]
        if block.designation[0][0].subterranean then
            local f, w = scan_block(block, false)
            tf = tf + f; tw = tw + w
        end
    end
    if tf + tw > 0 then
        log("smoothed underground: floors=%d walls=%d", tf, tw)
    end
end

-- ============================================================================
-- VIEW HELPER
-- ============================================================================

-- Returns true when the adventure view is the active screen.
local function is_dungeon_view()
    if not df.viewscreen_dungeonmodest then return false end
    local vs = dfhack.gui.getCurViewscreen and dfhack.gui.getCurViewscreen()
    return vs ~= nil and vs._type == df.viewscreen_dungeonmodest
end

-- ============================================================================
-- BFS FLOOD-FILL
-- ============================================================================

local function block_key(bx, by, bz)
    return (bx / 16) * 4000000 + (by / 16) * 1000 + bz
end

local function bfs_reset()
    S.bfs_queue = {}
    S.bfs_head  = 1
    S.bfs_tail  = 0
    S.bfs_seen  = {}
    S.bfs_done  = {}
end

local function bfs_enqueue(bx, by, bz)
    local k = block_key(bx, by, bz)
    if S.bfs_seen[k] or S.bfs_done[k] then return end
    S.bfs_seen[k]           = true
    S.bfs_tail              = S.bfs_tail + 1
    S.bfs_queue[S.bfs_tail] = {bx, by, bz}
end

-- Processes up to BLOCKS_PER_TICK entries from the front of the BFS queue.
local function bfs_step()
    if S.bfs_head > S.bfs_tail then return end
    local map   = df.global.world.map
    local limit = math.min(S.bfs_head + BLOCKS_PER_TICK - 1, S.bfs_tail)
    local tf, tw = 0, 0

    for i = S.bfs_head, limit do
        local entry      = S.bfs_queue[i]
        S.bfs_queue[i]   = nil                        -- release reference
        local bx, by, bz = entry[1], entry[2], entry[3]
        local k          = block_key(bx, by, bz)
        S.bfs_seen[k]    = nil

        local block = maps_getTileBlock(bx, by, bz)
        if block then
            S.bfs_done[k] = true
            local pbx, pby, pbz = player_block_pos()
            local in_view = is_dungeon_view() and pbx ~= nil
                and math.abs(bx - pbx) / 16 <= VISIBLE_BLOCK_RADIUS
                and math.abs(by - pby) / 16 <= VISIBLE_BLOCK_RADIUS
                and math.abs(bz - pbz) <= 1
            if not in_view then
                local f, w = scan_block(block, false)
                tf = tf + f; tw = tw + w
            end

            local has_non_open = false
            local has_non_wall = false
            for lx = 0, 15 do
                for ly = 0, 15 do
                    local a = tiletype_attrs[block.tiletype[lx][ly]]
                    if a then
                        local sa2 = shape_attrs[a.shape]
                        if not (sa2 and sa2.basic_shape == BASIC_OPEN) then has_non_open = true end
                        if a.shape ~= SHAPE_WALL then has_non_wall = true end
                    end
                    if has_non_open and has_non_wall then goto bfs_analyze_done end
                end
            end
            ::bfs_analyze_done::

            if bx >= 16              then bfs_enqueue(bx - 16, by,     bz) end
            if bx + 16 < map.x_count then bfs_enqueue(bx + 16, by,     bz) end
            if by >= 16              then bfs_enqueue(bx,     by - 16,  bz) end
            if by + 16 < map.y_count then bfs_enqueue(bx,     by + 16,  bz) end
            if has_non_open and bz + 1 < map.z_count then bfs_enqueue(bx, by, bz + 1) end
            if has_non_wall and bz > 0               then bfs_enqueue(bx, by, bz - 1) end
        end
    end

    S.bfs_head = limit + 1
    if tf + tw > 0 then
        log("smoothed: floors=%d walls=%d", tf, tw)
    end
end

-- ============================================================================
-- VIEWSCREEN HOOK  (fast-travel / menu-exit detection)
-- ============================================================================

-- Called on every SC_VIEWSCREEN_CHANGED
local function on_enter_dungeon_view()
    if not S.watcher_enabled    then return end
    if not dfhack.isMapLoaded() then return end
    if is_player_map()          then return end
    if not is_dungeon_view()    then return end

    local cur_count = #df.global.world.map.map_blocks
    if cur_count ~= S.bfs_block_count then
        S.bfs_block_count = cur_count
        bfs_reset()
    end

    -- Synchronously smooth everything the player will see before the first frame renders.
    smooth_visible_area()

    local adv = dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos then
        local px, py, pz = adv.pos.x, adv.pos.y, adv.pos.z
        bfs_enqueue(px - (px % 16), py - (py % 16), pz)
    end
    -- Six steps (~120 blocks) pre-smooth the ring just outside the visible radius.
    for _ = 1, 6 do bfs_step() end
end

local function register_viewscreen_hook()
    if not SC_VIEWSCREEN_CHANGED then return end
    dfhack.onStateChange["smoothfloor_vschange"] = function(sc)
        if sc == SC_VIEWSCREEN_CHANGED then pcall(on_enter_dungeon_view) end
    end
end

local function unregister_viewscreen_hook()
    dfhack.onStateChange["smoothfloor_vschange"] = nil
end

-- ============================================================================
-- WATCHER
-- ============================================================================

local function stop_watcher()
    dfhack.timeout_active(S.current_timeout_id, nil)
    S.current_timeout_id = -1
    S.watcher_enabled    = false
    S.scan_gen           = S.scan_gen + 1
end

-- Fires every SCAN_INTERVAL_TICKS ticks.
-- Fortress mode: scans newly-revealed blocks as the map grows.
-- Adventure mode: seeds BFS from the adventurer's current block and drains it.
local function scan_tick(gen)
    S.current_timeout_id = -1
    if not S.watcher_enabled  then return end
    if gen ~= S.scan_gen      then return end
    if not dfhack.isMapLoaded() then
        S.current_timeout_id = dfhack.timeout(SCAN_INTERVAL_TICKS, 'ticks', function() scan_tick(gen) end)
        return
    end

    if is_player_map() then
        local blocks    = df.global.world.map.map_blocks
        local cur_count = #blocks
        if cur_count > S.bfs_block_count then
            local tf, tw = 0, 0
            for i = S.bfs_block_count, cur_count - 1 do
                local block = blocks[i]
                if not block.designation[0][0].subterranean then
                    local f, w = scan_block(block, false)
                    tf = tf + f; tw = tw + w
                end
            end
            if tf + tw > 0 then
                log("smoothed: floors=%d walls=%d", tf, tw)
            end
            S.bfs_block_count = cur_count
        end

        -- Rolling re-scan of subterranean blocks to catch tiles dwarves have newly revealed.
        local all_blocks = df.global.world.map.map_blocks
        local total      = #all_blocks
        if total > 0 then
            local sub_tf, sub_tw = 0, 0
            for _ = 1, BLOCKS_PER_TICK do
                local block = all_blocks[S.fort_rescan_idx]
                if block and block.designation[0][0].subterranean then
                    local f, w = scan_block(block, false)
                    sub_tf = sub_tf + f; sub_tw = sub_tw + w
                end
                S.fort_rescan_idx = (S.fort_rescan_idx + 1) % total
            end
            if sub_tf + sub_tw > 0 then
                log("underground rescan: floors=%d walls=%d", sub_tf, sub_tw)
            end
        end

        S.current_timeout_id = dfhack.timeout(SCAN_INTERVAL_TICKS, 'ticks', function() scan_tick(gen) end)
        return
    end

    -- Adventure mode: BFS flood-fill from adventurer.
    local cur_count = #df.global.world.map.map_blocks
    if cur_count < S.bfs_block_count then
        -- Chunks were unloaded (fast travel handled via viewscreen hook, but catch it here too).
        bfs_reset()
    end
    S.bfs_block_count = cur_count

    if is_dungeon_view() then smooth_visible_area() end

    local adv = dfhack.world.getAdventurer and dfhack.world.getAdventurer()
    if adv and adv.pos then
        local px, py, pz = adv.pos.x, adv.pos.y, adv.pos.z
        local bx = px - (px % 16)
        local by = py - (py % 16)
        local k  = block_key(bx, by, pz)
        S.bfs_done[k] = nil
        S.bfs_seen[k] = nil
        bfs_enqueue(bx, by, pz)
    end

    bfs_step()
    S.current_timeout_id = dfhack.timeout(SCAN_INTERVAL_TICKS, 'ticks', function() scan_tick(gen) end)
end

local function start_watcher()
    if S.watcher_enabled then return end
    dfhack.timeout_active(S.current_timeout_id, nil)
    S.watcher_enabled    = true
    S.scan_gen           = S.scan_gen + 1
    scan_tick(S.scan_gen)
end

-- ============================================================================
-- COMMANDS
-- ============================================================================

local args = { ... }
local cmd  = args[1] or "enable"

if cmd == "enable" then
    if not smooth_inorganic_cache then build_inorganic_cache() end
    register_viewscreen_hook()
    if dfhack.isMapLoaded() and is_player_map() then
        scan_all_subterranean()
        local blocks = df.global.world.map.map_blocks
        local n      = #blocks
        local tf, tw = 0, 0
        for i = 0, n - 1 do
            local block = blocks[i]
            if not block.designation[0][0].subterranean then
                local f, w = scan_block(block, false)
                tf = tf + f; tw = tw + w
            end
        end
        if tf + tw > 0 then
            log("smoothed: floors=%d walls=%d", tf, tw)
        end
        S.bfs_block_count = n
    end
    start_watcher()
elseif cmd == "force" then
    if not smooth_inorganic_cache then build_inorganic_cache() end
    if dfhack.isMapLoaded() then
        local blocks = df.global.world.map.map_blocks
        local tf, tw = 0, 0
        for i = 0, #blocks - 1 do
            local f, w = scan_block(blocks[i], true)
            tf = tf + f; tw = tw + w
        end
        if tf + tw > 0 then
            log("smoothed: floors=%d walls=%d", tf, tw)
        end
        bfs_reset()
        S.bfs_block_count = #blocks
    end
elseif cmd == "disable" then
    unregister_viewscreen_hook()
    stop_watcher()
    smooth_inorganic_cache = nil
    bfs_reset()
    S.bfs_block_count = 0
elseif cmd == "status" then
    local n = 0; for _ in pairs(smooth_stone_wall_by_suffix) do n = n + 1 end
    log("watcher=%s timeout_active=%s cache=%s floor_tt=%s wall_variants=%d queue=%d",
        tostring(S.watcher_enabled),
        tostring(dfhack.timeout_active(S.current_timeout_id)),
        tostring(smooth_inorganic_cache ~= nil),
        tostring(SMOOTH_FLOOR_TT),
        n,
        math.max(0, S.bfs_tail - S.bfs_head + 1))
elseif cmd == "debug" then
    if not smooth_inorganic_cache then build_inorganic_cache() end
    local stats = {}
    local nil_biome = 0
    local mx = df.global.world.map.x_count
    local my = df.global.world.map.y_count
    local mz = df.global.world.map.z_count
    for bxi = 0, math.floor(mx / 16) - 1 do
        for byi = 0, math.floor(my / 16) - 1 do
            for bz = 0, mz - 1 do
                local block = maps_getTileBlock(bxi * 16, byi * 16, bz)
                if block then
                    for lx = 0, 15 do
                        for ly = 0, 15 do
                            local tt   = block.tiletype[lx][ly]
                            local kind = tt_kind[tt]
                            if kind == 'sf' or kind == 'sw' or kind == 'lf' or kind == 'lw' then
                                if not block.designation[lx][ly].hidden then
                                    local wx, wy = bxi * 16 + lx, byi * 16 + ly
                                    local b = get_biome_for_tile(wx, wy, bz)
                                    local geo_i = block.designation[lx][ly].geolayer_index
                                    local layer = b and b.layers[geo_i]
                                    local mat_i = layer and layer.mat_index
                                    if mat_i then
                                        if not stats[mat_i] then
                                            local inorg = df.global.world.raws.inorganics.all[mat_i]
                                            stats[mat_i] = {id = inorg and inorg.id or "?", walls = 0, floors = 0}
                                        end
                                        local s = stats[mat_i]
                                        if kind == 'sf' or kind == 'lf' then s.floors = s.floors + 1
                                        else s.walls = s.walls + 1 end
                                    else
                                        nil_biome = nil_biome + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    log("=== ruins_smoothfloor debug (whole map) ===")
    for mat_i, s in pairs(stats) do
        local cached = smooth_inorganic_cache[mat_i] ~= nil
        log("  mat=%d id=%-30s cached=%s walls=%d floors=%d",
            mat_i, s.id, tostring(cached), s.walls, s.floors)
    end
    log("  nil_biome tiles (expect 0 after fix): %d", nil_biome)
else
    log("Usage: ruins_smoothfloor [enable|disable|force|status|debug]")
end
