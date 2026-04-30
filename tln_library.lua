--@module = true

-- ──────────────────────────────────────────────────────────────────────────────
-- ── PROFILING AND TIMING ──────────────────────────────────────────────────────
-- ──────────────────────────────────────────────────────────────────────────────
---@class dfhack
---@field getQueryPerformanceCounter function
---@field getQueryPerformanceFrequency function

-- ──────────────────────────────────────────────────────────────────────────────
---@type { [string]: integer }, { [string]: integer }, { [string]: integer }
local on_timers, off_timers, paused_timers = {}, {}, {}
-- ──────────────────────────────────────────────────────────────────────────────

-- ──────────────────────────────────────────────────────────────────────────────
---@return integer
getTimestamp          = dfhack . getQueryPerformanceCounter     or os.clock
-- ──────────────────────────────────────────────────────────────────────────────
---@return number
getTimestampDivisor   = dfhack . getQueryPerformanceFrequency   or function()return 1.0;end
-- ──────────────────────────────────────────────────────────────────────────────
---@param key string
function timer_on(key)
    on_timers[key], off_timers[key] = (off_timers[key] or 0) - getTimestamp(), nil
end
-- ──────────────────────────────────────────────────────────────────────────────
---@param key string
function timer_off(key)
    on_timers[key], off_timers[key] = nil, (on_timers[key]) and (on_timers[key] + getTimestamp()) or 0
end
-- ──────────────────────────────────────────────────────────────────────────────
---@param fn function
---@param ... any
function timer_time(key, fn, ...)  -- multi-return untested
    timer_on(key)
    local rets = { fn(...) }
    timer_off(key)
    return table.unpack(rets)
end
-- ──────────────────────────────────────────────────────────────────────────────
function timer_reset(key)
    on_timers[key], off_timers[key], paused_timers[key] = nil, nil, nil
end
-- ──────────────────────────────────────────────────────────────────────────────
function timer_reset_on(key)
    timer_reset(key)
    timer_on(key)
end
-- ──────────────────────────────────────────────────────────────────────────────
function timers_pause()
    assert(#paused_timers == 0, "timer logic error: timers were already paused")
    for k,v in pairs(on_timers) do
        v = v + getTimestamp()
        paused_timers[k] = v
        on_timers[k] = nil
    end
end
-- ──────────────────────────────────────────────────────────────────────────────
function timers_unpause()
    assert(#on_timers == 0, "timer logic error: timers were already unpaused or a new timer was started")
    for k,v in pairs(paused_timers) do
        v = v - getTimestamp()
        on_timers[k] = v
        paused_timers[k] = nil
    end
end
-- ──────────────────────────────────────────────────────────────────────────────
timers_resume = timers_unpause
-- ──────────────────────────────────────────────────────────────────────────────
---@param key string
---@return number
function timer_elapsed(key)
    if on_timers[key] then return (on_timers[key]) / getTimestampDivisor(); end
    local count = (off_timers[key] or 0)
    --off_timers[key] = nil
    return count / getTimestampDivisor()
end
-- ──────────────────────────────────────────────────────────────────────────────
---@param key string
---@return number
function timer_off_elapsed(key)
    timer_off(key)
    return timer_elapsed(key)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- ── LOGGING AND STATISTICS ────────────────────────────────────────────────────
-- ──────────────────────────────────────────────────────────────────────────────
-- SWD: string.format() moved into this function.  That's much better
--      than requiring every caller that needs formatting to do it itself.
function log(msg, ...) print("[smoothfloor] " .. string.format(msg, ...)) end
-- ──────────────────────────────────────────────────────────────────────────────
function dlog(msg, ...) if S.debug then log("DIAG: " .. msg, ...) end end
-- ──────────────────────────────────────────────────────────────────────────────
--- increment a statistic.
local _stats = {}    ---@type { [string]: integer }
---@param key string
---@param delta? integer
function stat(key, delta)
    _stats[key] = (_stats[key] or 0) + (delta or 1)
end
-- ──────────────────────────────────────────────────────────────────────────────
--- get a statistic's current count.
---@param key string
---@return integer count
function stats(key)
    _stats[key] = _stats[key] or 0
    return _stats[key]
end
-- ──────────────────────────────────────────────────────────────────────────────
-- ──────────────────────────────────────────────────────────────────────────────
-- ──────────────────────────────────────────────────────────────────────────────

-- it's too soon to do this kind of micro-optimization.
--local DF_item_type_BLOCKS = df.item_type.BLOCKS

--local DF_tiletype_ConstructedFloor          = df.tiletype.ConstructedFloor
--local DF_tiletype_ConstructedWallLRUD       = df.tiletype.ConstructedWallLRUD
--local DF_tiletype_ConstructedRamp           = df.tiletype.ConstructedRamp
--local DF_tiletype_ConstructedFortification  = df.tiletype.ConstructedFortification
--local DF_tiletype_shape_FLOOR               = df.tiletype_shape.FLOOR
--local DF_tiletype_shape_WALL                = df.tiletype_shape.WALL
--local DF_tiletype_shape_RAMP                = df.tiletype_shape.RAMP
--local DF_tiletype_shape_FORTIFICATION       = df.tiletype_shape.FORTIFICATION

--local DF_tiletype_shape_basic_Floor = df.tiletype_shape_basic.Floor
--local DF_tiletype_shape_basic_Wall = df.tiletype_shape_basic.Wall
--local DF_tiletype_shape_basic_Ramp = df.tiletype_shape_basic.Ramp

--------------------------------------------------------------------------------
-- these maps exist to bypass probing df.tiletype_shape_basic[DF_tiletype_attrs[].shape] in tight loops.
-- probing one Lua table is faster than probing two DFHack enums.
---@type table<df.tiletype_shape, true>
local tiletype_shape_is_floor = {}
---@type table<df.tiletype_shape, true>
local tiletype_shape_is_wall = {}
---@type table<df.tiletype_shape, true>
local tiletype_shape_is_ramp = {}
---@type table<df.tiletype_shape, true>
local tiletype_shape_is_floor_or_ramp = {}

for i,_ in ipairs(df.tiletype_shape) do     -- build the above tables.
    if df.tiletype_shape.attrs[i].basic_shape == df.tiletype_shape_basic.Floor then
        tiletype_shape_is_floor[i] = true
        tiletype_shape_is_floor[df.tiletype_shape[i]] = true
    end
    if df.tiletype_shape.attrs[i].basic_shape == df.tiletype_shape_basic.Wall then
        tiletype_shape_is_wall[i] = true
        tiletype_shape_is_wall[df.tiletype_shape[i]] = true
    end
    if df.tiletype_shape.attrs[i].basic_shape == df.tiletype_shape_basic.Ramp then
        tiletype_shape_is_ramp[i] = true
        tiletype_shape_is_ramp[df.tiletype_shape[i]] = true
    end
    if df.tiletype_shape.attrs[i].basic_shape == df.tiletype_shape_basic.Floor
        or df.tiletype_shape.attrs[i].basic_shape == df.tiletype_shape_basic.Ramp then
        tiletype_shape_is_floor_or_ramp[i] = true
        tiletype_shape_is_floor_or_ramp[df.tiletype_shape[i]] = true
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- it seems this is actually slower than just assigning all the attributes.  surprising!
local add_construction_to_tile__ = {
    pos = { x = -1, y = -2, z = -3 },
    item_type = df.item_type.BLOCKS,
    item_subtype = -1,
    flags = { no_build_item = true },
    mat_type = -1,
    mat_index = -1,
    original_tile = -1,
}

local clone = df.construction:new()
clone:assign(add_construction_to_tile__)

--  TODO consider passing in key_xyz?, because it is generally already known.
--  TODO consider allowing attrs to be nil, or don't pass it in at all; this function can compute and cache it.
---@param block df.map_block
---@param lx integer
---@param ly integer
---@param ott df.tiletype?                          -- the tiletype of the OLD tile.  if not known, pass in nil
---@param attrs tiletype_attr_entry_type_fields     -- tiletype.attrs of the NEW tile.  TODO if not known, pass in nil.
---@param mat_type integer
---@param mat_index integer
---@return 0|1
function OLDadd_construction_to_tile(block, lx, ly, ott, attrs, mat_type, mat_index)
    stat("called add_construction_to_tile")
    local changed = 0
    if ott == nil then ott = block.tiletype[lx][ly]; end
    if false then   -- sanity checking.
        if not ott == block.tiletype[lx][ly] then
            dlog("add_construction_to_tile: warning: ott %d ~= block.tiletype[lx][ly] %d",
                ott, block.tiletype[lx][ly])
            stat("add_construction_to_tile: original tiletype mismatch")
        end
    end
    timer_on('construction timer delta')
    timer_off('construction timer delta')
    timer_on('construction:new')        -- 1.4 us
    local construction = df.construction:new()
    timer_off('construction:new')
    do
        local c = df.construction:new()
        timer_on('set construction keys')       -- 9 us
        c.pos.x, c.pos.y, c.pos.z = block.map_pos.x + lx, block.map_pos.y + ly, block.map_pos.z
        c.item_type = df.item_type.BLOCKS
        c.item_subtype = -1
        c.flags.no_build_item = true
        c.mat_type, c.mat_index = mat_type, mat_index
        c.original_tile = ott
        timer_off('set construction keys')
        c:delete()
    end
    timer_on('assign construction')     -- 11 us
    add_construction_to_tile__.pos = xyz2pos( block.map_pos.x + lx, block.map_pos.y + ly, block.map_pos.z )
    add_construction_to_tile__.mat_type = mat_type
    add_construction_to_tile__.mat_index = mat_index
    add_construction_to_tile__.original_tile = ott and ott or dfhack.maps.getTileType(add_construction_to_tile__.pos)
    construction:assign(add_construction_to_tile__)     -- actually slower than raw set-equal.
    timer_off('assign construction')
    timer_on('insert construction')     -- 8 us
    local success = dfhack.constructions.insert(construction)
    timer_off('insert construction')
    if success then
        stat("add_construction_to_tile: total")
        local shape = attrs.shape
        if shape == df.tiletype_shape.FLOOR then
            block.tiletype[lx][ly] = df.tiletype.ConstructedFloor
            stat("add_construction_to_tile: floors")
        elseif shape == df.tiletype_shape.WALL then
            block.tiletype[lx][ly] = df.tiletype.ConstructedWallLRUD
            stat("add_construction_to_tile: walls")
        elseif shape == df.tiletype_shape.RAMP then
            block.tiletype[lx][ly] = df.tiletype.ConstructedRamp
            stat("add_construction_to_tile: ramps")
        else
            -- TODO figure out the proper ConstructedType
            --  from the ott's suffix.  cases: Pillar,
            --  Fortification, Stair[UD]+, FloorTrack[NSEW]+,
            --  RampTrack[NSEW]+ .  cache it keyed on ott.
            -- TODO possibly: if ott was a XxxWallSuffix,
            --  find the relevant ConstructedWallSuffix.
            stat("add_construction_to_tile: other")
        end
        --add_to_construction_cache(construction)
        changed = 1
    else
        dlog("add_construction_to_tile: insert construction FAILED! cleaning up")
        stat("add_construction_to_tile: insert construction FAILED")
        construction:delete()
        changed = 0
    end
    return changed
end

--  TODO consider passing in key_xyz?, because it is generally already known.
--  TODO consider allowing attrs to be nil, or don't pass it in at all; this function can compute and cache it.
---@param x integer
---@param y integer
---@param z integer
---@param shape df.tiletype_shape
---@param mat_type integer
---@param mat_index integer
---@param override_newtt df.tiletype?
---@param override_oldtt df.tiletype?
---@return df.construction
function add_construction_to_tile(x, y, z, shape, mat_type, mat_index, override_newtt, override_oldtt)
    stat("called add_construction_to_tile")
    override_oldtt = override_oldtt or dfhack.maps.getTileType(x, y, z)
    do
        timer_on('timer delta')             -- 1.630 us      1.684 us
        timer_off('timer delta')

        timer_on('timer delta2')
        timer_off('timer delta2')

        timer_on('timer delta3')
        timer_off('timer delta3')

        timer_on('timer delta4')
        timer_off('timer delta4')

        timer_on('construction:new')        -- 3.924 us     3.689 us    3.863 us
        local c = df.construction:new()
        timer_off('construction:new')
        c:delete()

        timer_on('clone:new')               -- 3.078 us     2.997 us    3.077 us
        local c = clone:new()
        timer_off('clone:new')
        c:delete()
    end
    do
        timer_on('new and set')             -- 25.820 us    24.721 us   25.600 us
        local c = df.construction:new()
        c.pos.x, c.pos.y, c.pos.z = x, y, z
        c.item_type = df.item_type.BLOCKS
        c.item_subtype = -1
        c.flags.no_build_item = true
        c.mat_type, c.mat_index = mat_type, mat_index
        c.original_tile = override_oldtt or dfhack.maps.getTileBlock(x, y, z)
        timer_off('new and set')

        timer_on('new and assign fixed3')    -- TODO        28.730 us   29.961 us
        cc = df.construction:new()
        add_construction_to_tile__.pos.x, add_construction_to_tile__.pos.y, add_construction_to_tile__.pos.z = x, y, z
        add_construction_to_tile__.mat_type = mat_type
        add_construction_to_tile__.mat_index = mat_index
        add_construction_to_tile__.original_tile = override_oldtt or dfhack.maps.getTileBlock(x, y, z)
        cc:assign(add_construction_to_tile__)
        timer_off('new and assign fixed3')
        for k, v in pairs(c) do if k == "pos" then for kk,vv in ipairs{'x','y','z'} do assert(c[k][vv] == cc[k][vv]) end elseif k == "flags" then assert(c.flags.no_build_item == cc.flags.no_build_item) assert(c.flags.top_of_wall == cc.flags.top_of_wall) assert(c.flags.reinforced == cc.flags.reinforced) else assert(c[k] == cc[k], k) end end
        cc:delete()

        timer_on('new and assign fixed2')   -- 30.044 us    28.755 us   29.815 us
        cc = df.construction:new()
        local zz = add_construction_to_tile__; local pos = zz.pos
        pos.x, pos.y, pos.z = x, y, z
        zz.mat_type = mat_type
        zz.mat_index = mat_index
        zz.original_tile = override_oldtt or dfhack.maps.getTileBlock(x, y, z)
        cc:assign(add_construction_to_tile__)
        timer_off('new and assign fixed2')
        for k, v in pairs(c) do if k == "pos" then for kk,vv in ipairs{'x','y','z'} do assert(c[k][vv] == cc[k][vv]) end elseif k == "flags" then assert(c.flags.no_build_item == cc.flags.no_build_item) assert(c.flags.top_of_wall == cc.flags.top_of_wall) assert(c.flags.reinforced == cc.flags.reinforced) else assert(c[k] == cc[k], k) end end
        cc:delete()

        timer_on('clone and set')           -- 17.633 us    17.245 us   17.475 us
        local cc = clone:new()
        cc.pos.x, cc.pos.y, cc.pos.z = x, y, z
        cc.mat_type, cc.mat_index = mat_type, mat_index
        cc.original_tile = override_oldtt or dfhack.maps.getTileBlock(x, y, z)
        timer_off('clone and set')
        for k, v in pairs(c) do if k == "pos" then for kk,vv in ipairs{'x','y','z'} do assert(c[k][vv] == cc[k][vv]) end elseif k == "flags" then assert(c.flags.no_build_item == cc.flags.no_build_item) assert(c.flags.top_of_wall == cc.flags.top_of_wall) assert(c.flags.reinforced == cc.flags.reinforced) else assert(c[k] == cc[k], k) end end
        cc:delete()

        timer_on('clone and assign temp')   -- 24.290 us    23.399 us   23.742 us
        cc = clone:new()
        cc:assign{
            pos = { x = x, y = y, z = z },
            mat_type = mat_type,
            mat_index = mat_index,
            original_tile = override_oldtt or dfhack.maps.getTileBlock(x, y, z),
        }
        timer_off('clone and assign temp')
        for k, v in pairs(c) do if k == "pos" then for kk,vv in ipairs{'x','y','z'} do assert(c[k][vv] == cc[k][vv]) end elseif k == "flags" then assert(c.flags.no_build_item == cc.flags.no_build_item) assert(c.flags.top_of_wall == cc.flags.top_of_wall) assert(c.flags.reinforced == cc.flags.reinforced) else assert(c[k] == cc[k], k) end end
        cc:delete()

        timer_on('clone and assign fixed')  -- 29.834 us    28.540 us   29.666 us
        cc = clone:new()
        add_construction_to_tile__.pos.x, add_construction_to_tile__.pos.y, add_construction_to_tile__.pos.z = x, y, z
        add_construction_to_tile__.mat_type = mat_type
        add_construction_to_tile__.mat_index = mat_index
        add_construction_to_tile__.original_tile = override_oldtt or dfhack.maps.getTileBlock(x, y, z)
        cc:assign(add_construction_to_tile__)
        timer_off('clone and assign fixed')
        for k, v in pairs(c) do if k == "pos" then for kk,vv in ipairs{'x','y','z'} do assert(c[k][vv] == cc[k][vv]) end elseif k == "flags" then assert(c.flags.no_build_item == cc.flags.no_build_item) assert(c.flags.top_of_wall == cc.flags.top_of_wall) assert(c.flags.reinforced == cc.flags.reinforced) else assert(c[k] == cc[k], k) end end
        cc:delete()

        timer_on('clone and assign fixed2') -- 30.199 us    28.032 us   29.058 us
        cc = clone:new()
        local zz = add_construction_to_tile__; local pos = zz.pos
        pos.x, pos.y, pos.z = x, y, z
        zz.mat_type = mat_type
        zz.mat_index = mat_index
        zz.original_tile = override_oldtt or dfhack.maps.getTileBlock(x, y, z)
        cc:assign(add_construction_to_tile__)
        timer_off('clone and assign fixed2')
        for k, v in pairs(c) do if k == "pos" then for kk,vv in ipairs{'x','y','z'} do assert(c[k][vv] == cc[k][vv]) end elseif k == "flags" then assert(c.flags.no_build_item == cc.flags.no_build_item) assert(c.flags.top_of_wall == cc.flags.top_of_wall) assert(c.flags.reinforced == cc.flags.reinforced) else assert(c[k] == cc[k], k) end end
        cc:delete()

        c:delete()
    end
    timer_on('new and assign fixed')        -- 28.244 us    29.339 us
    local construction = df.construction:new()
    local pos = add_construction_to_tile__.pos
    pos.x, pos.y, pos.z = x, y, z
    add_construction_to_tile__.mat_type = mat_type
    add_construction_to_tile__.mat_index = mat_index
    add_construction_to_tile__.original_tile = override_oldtt or dfhack.maps.getTileBlock(x, y, z)
    construction:assign(add_construction_to_tile__)     -- actually slower than raw set-equals.
    timer_off('new and assign fixed')

    timer_on('insert construction')     -- TODO     8.607 us
    local success = dfhack.constructions.insert(construction)
    timer_off('insert construction')
    if success then
        local newtt = df.tiletype.ConstructedPillar     ---@type df.tiletype
        --stat("add_construction_to_tile: total")
        if override_newtt then
            newtt = override_newtt
        elseif shape == df.tiletype_shape.FLOOR then    -- TODO make a map, eith precomputed or on-the-fly.
            newtt = df.tiletype.ConstructedFloor
            --stat("add_construction_to_tile: floors")
        elseif shape == df.tiletype_shape.WALL then
            newtt = df.tiletype.ConstructedWallLRUD     -- TODO figure out from neighbors.
            --stat("add_construction_to_tile: walls")
        elseif shape == df.tiletype_shape.RAMP then
            newtt = df.tiletype.ConstructedRamp
            --stat("add_construction_to_tile: ramps")
        elseif shape == df.tiletype_shape.FORTIFICATION then
            newtt = df.tiletype.ConstructedFortification
        elseif shape == df.tiletype_shape.STAIR_UPDOWN then
            newtt = df.tiletype.ConstructedStairUD
        elseif shape == df.tiletype_shape.STAIR_UP then
            newtt = df.tiletype.ConstructedStairU
        elseif shape == df.tiletype_shape.STAIR_DOWN then
            newtt = df.tiletype.ConstructedStairD
        else
            -- TODO figure out the proper ConstructedType
            --  from the ott's suffix.  cases: Pillar,
            --  Fortification, Stair[UD]+, FloorTrack[NSEW]+,
            --  RampTrack[NSEW]+ .  cache it keyed on ott.
            -- TODO possibly: if ott was a XxxWallSuffix,
            --  find the relevant ConstructedWallSuffix.
            --stat("add_construction_to_tile: other")
        end
        dfhack.maps.getTileBlock(x, y, z).tiletype[x & 15][y & 15] = newtt
        --add_to_construction_cache(construction)
    else
        dlog("add_construction_to_tile: insert construction FAILED at (%d, %d, %d)! construction orphaned.", x, y, z)
        stat("add_construction_to_tile: insert construction FAILED")
        construction:delete()
    end
    return construction
end

