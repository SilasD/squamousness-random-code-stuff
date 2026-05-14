---@diagnostic disable: undefined-field
-- myprofiler.lua  -- a wrapper around the Pepperfish Profiler, DFHack hack/lua/profiler.lua
--   that script has been pulled in and slightly modified.
--@module = true
-- use: include this using `local myprofiler = dfhack.script_environment("myprofiler")`
-- then either `myprofiler.profile( function, args... )
-- or `myprofiler.start()`, run code, `myprofiler.stop()`
--
-- followed by `myprofiler.generate(dfhack.current_script_name(), "suffix_to_append")`
--
-- \s*--\s*\d+(\s\s\d+\.\d{3}s(\s\(self\s\d+\.\d{3}s\))?(\s\[anon\schild\s\d+\.\d{3}s\])?(\s\[child\s\d+\.\d{3}s\])?)?$


-- note: the Pepperfish Profiler has been copied into this file so the low-level
-- gather-info can be changed from os.clock to QueryPerformanceCounter.
-- other minor changes, such as making it work with reqscript() instead of require().


local SECONDS = 0.0003    -- total execution time lower than this is ignored in the annotated lua file.
local HIT_COUNT = 25     -- total hits lower than this is ignored in the annotated lua file.


function start()
    profiler:start()
end

function stop()
    profiler:stop()
end

---@generic T
---@param f fun(...): T
---@param ... any
---@return any ...
function profile(f, ...)
    start()
    local rets = { dfhack.pcall(...) }
    stop()
    local ok = table.remove(rets, 1)
    if not ok then
        local err = table.remove(rets, 1)
        dfhack.printerr(err)
    end
    return table.unpack(rets)
end


-- these have to be global because profiler:lua_report() returns code that treats them as global.
--   that could probably be worked around by copying _ENV and massaging it, but this is easier.
funcnames,    ---@type string[]     -- as returned by debug info
functimes,    ---@type { tot:number, nchild:number, achild:number, count:integer }
                                    -- total time, named-child time, anonymous-child time, hits on this function's code(?)  units: seconds
children,     ---@type integer[]    -- index into funcnames. which funcnames were children of this function.
childcounts,  ---@type integer[]    -- lockstep with children. count of hits of this child of this function.
childtimes    ---@type number[]     -- lockstep with children. cumulative time spent in this child of this function. units seconds.
 = {}, {}, {}, {}, {}


---@param scriptname string
---@param suffix string?
function generate(scriptname, suffix)
    assert(type(scriptname) == "string")
    suffix = (type(suffix) == "string") and (suffix ~= "") and suffix or "test"
    suffix = "--" .. suffix

    local scriptpath = dfhack.findScript(scriptname)
    assert(type(scriptpath) == "string" and scriptpath ~= "")

    local scriptnameext = scriptpath:match( '[\\/:](' .. scriptname .. '%.lua)$' )
    assert(type(scriptnameext) == "string" and scriptnameext ~= "")

    local outname = scriptpath:match('^(.-)%.lua$') .. suffix
    assert(outname)

    local prof
    do  -- this is kind of shit.
        local prof_filename = outname .. ".profile.txt"
        local prof_file, err = io.open( prof_filename, "w+" )
        assert(prof_file, err)
        profiler:report( prof_file )
        prof_file:close()
        prof_file, err = io.open( prof_filename, "r" )
        assert(prof_file, err)
        prof = prof_file:read("a")
        prof_file:close()
        assert(type(prof) == "string")
        assert(#prof > 0)
        prof = prof:split('\n')
    end

    local lprof
    do
        local lprof_filename = outname .. ".lprofile.txt"
        local lprof_file, err = io.open( lprof_filename, 'w+' )
        assert(lprof_file, err)
        profiler:lua_report( lprof_file )
        lprof_file:close()
        lprof_file, err = io.open( lprof_filename, 'r')
        assert(lprof_file, err)
        lprof = lprof_file:read("a")
        lprof_file:close()
        assert(type(lprof) == "string")
        assert(#lprof > 0)
        -- prof = prof:split('\n')  -- no, we want to digest it as one string.
    end

    local this
    do
        local thisfilepath = scriptpath
        local thisfile, err = io.open( thisfilepath, 'r')
        assert(thisfile, err)
        this = thisfile:read('a')
        thisfile:close()
        assert(type(this) == "string")
        assert(#this > 0)
        this = this:split('\n')
    end
    --print('#this', #this)
    --print('#prof', #prof)
    --print('#lprof', #lprof:split('\n'))

    local funclines = {}
    do
        local function pad(s,n) return s .. string.rep(' ', n - #s); end
        --local funcnames, functimes, children, childcounts, childtimes     -- they need to be global I guess.
        local lprof_code, err = load(lprof, "lprof_code", nil, _ENV)
        assert(lprof_code, err)
        lprof_code()
        --print("lprof_code>", funcnames, functimes, children, childcounts, childtimes)
        --print("lprof_code#", #funcnames, #functimes, #children, #childcounts, #childtimes)
        --print('---');printall(funcnames)
        --print('---');printall_recurse(functimes)
        --for _,t in ipairs({funcnames, functimes, children, childcounts, childtimes})do print('---'); printall(t);end
        if #funcnames == 0 then print("myprofiler: warning! no profiled functions!\a"); end

        local script_pattern = '[/\\]' .. scriptnameext:escape_pattern() .. ':(%d+)$'
        for i,_ in ipairs(funcnames) do
            local funcline = funcnames[i]:match(script_pattern)
            if not funcline then goto continue; end
            funcline = assert(math.tointeger(funcline))
            ---@cast funcline -?
            if funcline <= 0 then goto continue; end
            assert(funcline <= #this, funcline)
            --print(i, funcline, type(funcline), math.type(funcline))
            table.insert(funclines, funcline)
            local tot, achild, nchild, count = tonumber(functimes[i].tot), tonumber(functimes[i].achild),
                    tonumber(functimes[i].nchild), tonumber(functimes[i].count)
            --print('$', tot, achild, nchild, count)
            if tot < SECONDS then goto continue; end
            local tot2 = tot - nchild
            local s
            if tot - tot2 > 0.0000001 then
                s = string.format("--%8d  %0.3fs (self %0.3fs)", count, tot, tot2)
            else
                s = string.format("--%8d  %0.3fs", count, tot)
            end
            if achild > 0.0000001 then
                s = string.format("%s [anon child %0.3fs]", s, achild)
            end
            if nchild > 0.0000001 then
                s = string.format("%s [child %0.3fs]", s, nchild)
            end
            --print(funcline, this[funcline], s)
            this[funcline] = pad(this[funcline], 120) .. s
            ::continue::
        end
    end

    do
        local newfunc_pattern = string.escape_pattern(" -------------------") .. '$'
        local script_pattern = '([^\\/:]+):%d+' .. newfunc_pattern
        local function pad(s,n) return s .. string.rep(' ', n - #s); end
        local this_sections_file
        for i,r in ipairs(prof) do
            if r:find(newfunc_pattern) then
                this_sections_file = r:match(script_pattern)
            end
            local count, line = r:match('^%s*(%d+) sampled in line (%d+)$')
            if count and line and this_sections_file == scriptnameext then
                count = math.tointeger(count); assert(count)
                line = math.tointeger(line); assert(line)
                if count < HIT_COUNT then goto continue; end
                this[line] = string.format("%s--%8d", pad(this[line], 120), count)
            elseif false then
                -- other line processing here
            else
                --print("ignoring", r)
                goto continue
            end
            ::continue::
        end
    end

    do
        this[1] = 'do dfhack.printerr("\aattempt to run a profiled script!"); return; end;  ' .. this[1]
    end

    do
        local this = table.concat(this, '\n')
        local annotated_filepath = outname .. ".lua"
        assert(annotated_filepath ~= scriptpath)
        local thefile, err = io.open( annotated_filepath, 'w+')
        assert(thefile, err)
        thefile:write(this)
        thefile:close()
    end
end


---------------------------------------------------------------------------------------------------------

--[[

== Introduction ==

  Note that this requires os.clock(), debug.sethook(),
  and debug.getinfo() or your equivalent replacements to
  be available if this is an embedded application.

  Example usage:

    profiler = newProfiler()
    profiler:start()

    < call some functions that take time >

    profiler:stop()

    local outfile = io.open( "profile.txt", "w+" )
    profiler:report( outfile )
    outfile:close()

== Optionally choosing profiling method ==

The rest of this comment can be ignored if you merely want a good profiler.

  newProfiler(method, sampledelay):

If method is omitted or "time", will profile based on real performance.
optionally, frequency can be provided to control the number of opcodes
per profiling tick. By default this is 100000, which (on my system) provides
one tick approximately every 2ms and reduces system performance by about 10%.
This can be reduced to increase accuracy at the cost of performance, or
increased for the opposite effect.

If method is "call", will profile based on function calls. Frequency is
ignored.


"time" may bias profiling somewhat towards large areas with "simple opcodes",
as the profiling function (which introduces a certain amount of unavoidable
overhead) will be called more often. This can be minimized by using a larger
sample delay - the default should leave any error largely overshadowed by
statistical noise. With a delay of 1000 I was able to achieve inaccuray of
approximately 25%. Increasing the delay to 100000 left inaccuracy below my
testing error.

"call" may bias profiling heavily towards areas with many function calls.
Testing found a degenerate case giving a figure inaccurate by approximately
20,000%.  (Yes, a multiple of 200.) This is, however, more directly comparable
to common profilers (such as gprof) and also gives accurate function call
counts, which cannot be retrieved from "time".

I strongly recommend "time" mode, and it is now the default.

== History ==

2008-09-16 - Time-based profiling and conversion to Lua 5.1
  by Ben Wilhelm ( zorba-pepperfish@pavlovian.net ).
  Added the ability to optionally choose profiling methods, along with a new
  profiling method.

Converted to Lua 5, a few improvements, and
additional documentation by Tom Spilman ( tom@sickheadgames.com )

Additional corrections and tidying by original author
Daniel Silverstone ( dsilvers@pepperfish.net )

== Status ==

Daniel Silverstone is no longer using this code, and judging by how long it's
been waiting for Lua 5.1 support, I don't think Tom Spilman is either. I'm
perfectly willing to take on maintenance, so if you have problems or
questions, go ahead and email me :)
-- Ben Wilhelm ( zorba-pepperfish@pavlovian.net ) '

== Copyright ==

Lua profiler - Copyright Pepperfish 2002,2003,2004

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to
do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.

--]]



--
-- All profiler related stuff is stored in the top level table '_profiler'
--
local _profiler = {}
local DEFAULT_FILTERED_FUNC = 1
local DEFAULT_MISSING_FUNC = 3

---@class stats
---@field func function
---@field anon boolean
---@field count integer
---@field time number
---@field profile_time number
---@field anon_child_time number
---@field name_child_time number
---@field children table
---@field children_time table
---@field currentline table
---@field func_info table  -- debug.getinfo(fnS)

--
-- newProfiler() creates a new profiler object for managing
-- the profiler and storing state.  Note that only one profiler
-- object can be executing at one time.
--
---@param variant string
---@param sampledelay integer
function newProfiler(variant, sampledelay)
  if _profiler.running then
    qerror("Profiler already running.")
  end

  variant = variant or "time"

  if variant ~= "time" and variant ~= "call" then
    qerror("Profiler method must be 'time' or 'call'.")
  end

  -- generate a new instance of the class
  local newprof = {}
  for k,v in pairs(_profiler) do
    newprof[k] = v
  end
  newprof.variant = variant
  newprof.sampledelay = sampledelay or 10000
  return newprof
end


--
-- This function stops the profiler.  It will do nothing
-- if a profiler is not running, and nothing if it isn't
-- the currently running profiler.
--
function _profiler.stop(self)
  if _profiler.running ~= self then
    return
  end
  -- Stop the profiler.
  debug.sethook()
  _profiler.running = nil

  local divisor = 1.0 * dfhack.QueryPerformanceFrequency()
  for func,record in pairs(self.rawstats) do
    record.time = record.time / divisor
    record.profile_time = record.profile_time / divisor
    record.anon_child_time = record.anon_child_time / divisor
    record.name_child_time = record.name_child_time / divisor
    for key,_ in pairs(record.children_time) do
      record.children_time[key] = record.children_time[key] / divisor
    end
  end
end

---@param rawstats stats
---@param prevented_functions table<function, boolean>
---@param func function
---@param depth integer
local function get_stats(rawstats, prevented_functions, func, depth)
    if prevented_functions[func] then
      return nil
    end
    local stats = rawstats[func]
    if not stats then
      depth = depth + 1
      ci = debug.getinfo(depth,"fnS")
      if ci.what == "C" and ci.name == "__index" then
        local value1
        _, value1 = debug.getlocal(depth, 1)
        value1 = tostring(value1)
        value1 = value1:match("^<([^:]*):") or value1
        ci.short_src = value1
      end
      stats = {
        func = ci.func,
        anon = ci.name == nil,
        count = 0,
        time = 0,
        profile_time = 0,
        anon_child_time = 0,
        name_child_time = 0,
        children = {},
        children_time = {},
        currentline = {},
        func_info = ci,
      }
      rawstats[func] = stats
    end
    return stats
end

--
-- Simple wrapper to handle the hook.  You should not
-- be calling this directly. Duplicated to reduce overhead.
--
-- TODO what is with all these separate calls to the get-time function?
local function _profiler_hook_wrapper_by_call(action)
  ---@type integer
  local entry = dfhack.QueryPerformanceCounter()  --! os.clock()
  local self = _profiler.running
  local depth, stack = self.depth, self.stack
  if action == "call" then
    local parent = stack[depth]
    if parent and parent.should_not_profile > 0 then
      parent.should_not_profile = parent.should_not_profile + 1
    ---@type integer
      parent.profile_time = parent.profile_time + dfhack.QueryPerformanceCounter() - entry  --! (os.clock() - entry)
      return
    end
    local ci = debug.getinfo(2,"f")
    local func = ci.func
    local rawstats = self.rawstats
    local stats = get_stats(rawstats, self.prevented_functions, func, 2)
    depth = depth + 1
    self.depth = depth
    local this = stack[depth]
    if not this then
      this = {
        should_not_profile = stats and 0 or 1,
        stats = stats,
        clock_start = entry,
        profile_time = 0,
      }
      stack[depth] = this
    else
      this.should_not_profile = stats and 0 or 1
      this.stats = stats
      this.clock_start = entry
    end
    ---@type integer
    this.profile_time = dfhack.QueryPerformanceCounter() - entry  --! (os.clock() - entry)
  else  -- "time"
    if depth == 0 then
      return
    end
    local this = stack[depth]
    if this.should_not_profile > 0 then
      this.should_not_profile = this.should_not_profile - 1
      if this.should_not_profile == 0 then
        self.depth = depth - 1
        local parent = stack[self.depth]
        if parent then
          local time = entry - this.start_time - this.profile_time
          parent.stats.anon_child_time = parent.stats.anon_child_time + time
          ---@type integer
          parent.profile_time = parent.profile_time + this.profile_time + dfhack.QueryPerformanceCounter - entry  --! (os.clock() - entry)
        end
      else
        ---@type integer
        this.profile_time = this.profile_time + dfhack.QueryPerformanceCounter() - entry  --! (os.clock() - entry)
      end
      return
    end
    local time = entry - this.clock_start - this.profile_time
    depth = depth - 1
    self.depth = depth
    local parent = stack[depth]

    ---@type stats, stats
    local this_stats,parent_stats = this.stats,parent and parent.stats or qerror("WTF?")  -- or nil
    local func = this_stats.func

    this_stats.count = this_stats.count + 1
    this_stats.time = this_stats.time + time
    this_stats.profile_time = this_stats.profile_time + this.profile_time
    if not parent then return end
    if  this_stats.anon then
      parent_stats.anon_child_time = parent_stats.anon_child_time + time
    else
      parent_stats.name_child_time = parent_stats.name_child_time + time
    end
    local ch = parent_stats.children[func]
    if not ch then
      parent_stats.children[func] = 1
      parent_stats.children_time[func] = time
    else
      parent_stats.children[func] = ch + 1
      parent_stats.children_time[func] = parent_stats.children_time[func] + time
    end
    ---@type integer
    parent.profile_time = parent.profile_time + this.profile_time + dfhack.QueryPerformanceCounter() - entry  --! (os.clock() - entry)
  end
end

local function _profiler_hook_wrapper_by_time()
  local self = _profiler.running
  ---@type integer
  local timetaken = dfhack.QueryPerformanceCounter() - self.lastclock  --! os.clock() - self.lastclock
  local rawstats = self.rawstats
  local prevented = self.prevented_functions
  local depth = 2
  local caller = debug.getinfo(depth,'fl')
  local child
  if not caller then
    return
  end
  ---@type function|integer
  local cf = caller.func
  if cf then
    child = get_stats(rawstats, prevented, cf, depth)
    if child then
      child.count = child.count + 1
      child.time = child.time + timetaken
      local line = caller.currentline
      child.currentline[line] = (child.currentline[line] or 0) + 1
    else
      cf = DEFAULT_FILTERED_FUNC
    end
  else
    cf = DEFAULT_MISSING_FUNC
  end
  depth = 3
  local caller = debug.getinfo(depth,'f')
  while caller do
    if caller.func then
      local this = get_stats(rawstats, prevented, caller.func, depth)
      if this then
        this.time = this.time + timetaken
        if not child or child.anon then
          this.anon_child_time = this.anon_child_time + timetaken
        else
          this.name_child_time = this.name_child_time + timetaken
        end
        local ch = this.children[cf]
        if ch then
          this.children[cf] = ch + 1
          this.children_time[cf] = this.children_time[cf] + timetaken
        else
          this.children[cf] = 1
          this.children_time[cf] = timetaken
        end
        cf = caller.func
      else
        cf = DEFAULT_FILTERED_FUNC
      end
      child = this
    else
      cf = DEFAULT_MISSING_FUNC
      child = nil
    end
    depth = depth + 1
    caller = debug.getinfo(depth, 'f')
  end
  ---@type integer
  self.lastclock = dfhack.QueryPerformanceCounter()  --! os.clock()
end


--
-- This function starts the profiler.  It will do nothing
-- if this (or any other) profiler is already running.
--
function _profiler.start(self)
  if _profiler.running then
    return
  end
  -- Start the profiler. This begins by setting up internal profiler state
  _profiler.running = self
  assert(_profiler.running)
  self.rawstats = {}
  self.stack = {}
  self.depth = 0
  if self.variant == "time" then
    ---@type integer
    self.lastclock = dfhack.QueryPerformanceCounter()  --! os.clock()
    debug.sethook( _profiler_hook_wrapper_by_time, "", self.sampledelay )
  elseif self.variant == "call" then
    debug.sethook( _profiler_hook_wrapper_by_call, "cr" )
  else
    error("Profiler method must be 'time' or 'call'.")
  end
end

--
-- This writes a profile report to the output file object.  If
-- sort_by_total_time is nil or false the output is sorted by
-- the function time minus the time in it's children.
--
function _profiler.report( self, outfile, sort_by_total_time )

  outfile:write
    [[Lua Profile output created by profiler.lua. Copyright Pepperfish 2002+

]]

  -- This is pretty awful.
  local terms = {}
  if self.variant == "time" then
    terms.capitalized = "Sample"
    terms.single = "sample"
    terms.pastverb = "sampled"
  elseif self.variant == "call" then
    terms.capitalized = "Call"
    terms.single = "call"
    terms.pastverb = "called"
  else
    error("Profiler method must be 'time' or 'call'.")
  end

  local total_time = 0
  local ordering = {}
  for func,record in pairs(self.rawstats) do
    table.insert(ordering, func)
  end

  if sort_by_total_time then
    table.sort( ordering,
      function(a,b) return self.rawstats[a].time > self.rawstats[b].time end
    )
  else
    table.sort( ordering,
      function(a,b)
        local arec = self.rawstats[a]
        local brec = self.rawstats[b]
        local atime = arec.time - (arec.anon_child_time + arec.name_child_time)
        local btime = brec.time - (brec.anon_child_time + brec.name_child_time)
        return atime > btime
      end
    )
  end

  for i=1,#ordering do
    local func = ordering[i]
    local record = self.rawstats[func]
    local thisfuncname = " " .. self:_pretty_name(func) .. " "
    if string.len( thisfuncname ) < 42 then
      thisfuncname =
        string.rep( "-", math.floor((42 - string.len(thisfuncname))/2) ) .. thisfuncname
      thisfuncname =
        thisfuncname .. string.rep( "-", 42 - string.len(thisfuncname) )
    end

    local child_count = 0
    for _,v in pairs(record.children) do
      child_count = child_count + v
    end
    total_time = total_time + ( record.time - ( record.anon_child_time +
      record.name_child_time ) )
    outfile:write( string.rep( "-", 19 ) .. thisfuncname ..
      string.rep( "-", 19 ) .. "\n" )
    outfile:write( terms.capitalized.." count:             " ..
      string.format( "%5d", record.count ) .. "\n" )
    outfile:write( terms.capitalized.." count in children: " ..
      string.format( "%5d", child_count ) .. "\n" )
    outfile:write( "Time spend total:         " ..
      string.format( "%4.3f", record.time ) .. "s\n" )
    outfile:write( "Time spent in children:   " ..
      string.format("%4.3f",record.anon_child_time+record.name_child_time) ..
      "s\n" )
    outfile:write( "Time spent in profiler:   " ..
      string.format("%4.3f",record.profile_time) ..
      "s\n" )
    local timeinself =
      record.time - (record.anon_child_time + record.name_child_time)
    outfile:write( "Time spent in self:       " ..
      string.format("%4.3f", timeinself) .. "s\n" )
    outfile:write( "Time spent per " .. terms.single .. ":    " ..
                  string.format("%4.6f", record.time/(record.count+(self.variant == "time" and child_count or 0))) ..
      "s/" .. terms.single .. "\n" )
    outfile:write( "Time spent in self per "..terms.single..": " ..
      string.format( "%4.6f", record.count > 0 and timeinself/record.count or 0.0 ) .. "s/" ..
      terms.single.."\n" )

    -- Report on each child in the form
    -- Child  <funcname> called n times and took a.bs
    local added_blank = 0
    for k,v in pairs(record.children) do
      if self.prevented_functions[k] == nil or
         self.prevented_functions[k] == 0
      then
        if added_blank == 0 then
          outfile:write( "\n" ) -- extra separation line
          added_blank = 1
        end
        local pretty_name
        if k == DEFAULT_FILTERED_FUNC then
          pretty_name = "(Filtered function)"
        elseif k == DEFAULT_MISSING_FUNC then
          pretty_name = "(Function pointer missing)"
        else
          pretty_name = self:_pretty_name(k)
        end
        outfile:write( "Child " .. pretty_name ..
          string.rep( " ", 41-string.len(pretty_name) ) .. " " ..
          terms.pastverb.." " .. string.format("%6d", v) )
        outfile:write( " times. Took " ..
          string.format("%4.3f", record.children_time[k] ) .. "s\n" )
      end
    end

    local lines = {}
    for line,v in pairs(record.currentline) do
      if line >= 0 then
        lines[#lines+1] = line
      end
    end
    table.sort(lines)
    for i=1,#lines do
      local line = lines[i]
      local v = record.currentline[line]
      -- @todo How about reading the source code from the file?
      outfile:write( ("%6d %s in line %d\n"):format(v, terms.pastverb, line))
    end

    outfile:write( "\n" ) -- extra separation line
    outfile:flush()
  end
  outfile:write( "\n\n" )
  outfile:write( "Total time spent in profiled functions: " ..
                 string.format("%5.3g",total_time) .. "s\n" )
  outfile:write( [[

END
]] )
  outfile:flush()
end


--
-- This writes the profile to the output file object as
-- loadable Lua source.
--
function _profiler.lua_report(self,outfile)
  -- Purpose: Write out the entire raw state in a cross-referenceable form.
  local ordering = {}
  local functonum = {}
  for func,record in pairs(self.rawstats) do
    table.insert(ordering, func)
    functonum[func] = #ordering
  end

  outfile:write(
    "-- Profile generated by profiler.lua Copyright Pepperfish 2002+\n\n" )
  outfile:write( "-- Function names\nfuncnames = {}\n" )
  for i=1,#ordering do
    local thisfunc = ordering[i]
    outfile:write( "funcnames[" .. i .. "] = " ..
      string.format("%q", self:_pretty_name(thisfunc)) .. "\n" )
  end
  outfile:write( "\n" )
  outfile:write( "-- Function times\nfunctimes = {}\n" )
  for i=1,#ordering do
    local thisfunc = ordering[i]
    local record = self.rawstats[thisfunc]
    outfile:write( "functimes[" .. i .. "] = { " )
    outfile:write( "tot=" .. string.format("%0.9f", record.time) .. ", " )
    outfile:write( "achild=" .. string.format("%0.9f", record.anon_child_time) .. ", " )
    outfile:write( "nchild=" .. string.format("%0.9f", record.name_child_time ).. ", " )
    outfile:write( "count=" .. record.count .. " }\n" )
  end
  outfile:write( "\n" )
  outfile:write( "-- Child links\nchildren = {}\n" )
  for i=1,#ordering do
    local thisfunc = ordering[i]
    local record = self.rawstats[thisfunc]
    outfile:write( "children[" .. i .. "] = { " )
    for k,v in pairs(record.children) do
      if functonum[k] then -- non-recorded functions will be ignored now
        outfile:write( functonum[k] .. ", " )
      end
    end
    outfile:write( "}\n" )
  end
  outfile:write( "\n" )
  outfile:write( "-- Child call counts\nchildcounts = {}\n" )
  for i=1,#ordering do
    local thisfunc = ordering[i]
    local record = self.rawstats[thisfunc]
    outfile:write( "childcounts[" .. i .. "] = { " )
    for k,v in pairs(record.children) do
      if functonum[k] then -- non-recorded functions will be ignored now
        outfile:write( v .. ", " )
      end
    end
    outfile:write( "}\n" )
  end
  outfile:write( "\n" )
  outfile:write( "-- Child call time\nchildtimes = {}\n" )
  for i=1,#ordering do
    local thisfunc = ordering[i]
    local record = self.rawstats[thisfunc];
    outfile:write( "childtimes[" .. i .. "] = { " )
    for k,v in pairs(record.children) do  -- TODO this appears to assume that the pairs() has the same ordering as the child call counts pairs(), is that always valid?
      if functonum[k] then -- non-recorded functions will be ignored now
        outfile:write( string.format("%0.9f", record.children_time[k]) .. ", " )
      end
    end
    outfile:write( "}\n" )
  end
  outfile:write( "\n\n-- That is all.\n\n" )
  outfile:flush()
end

-- Internal function to calculate a pretty name for the profile output
function _profiler._pretty_name(self,func)

  -- Only the data collected during the actual
  -- run seems to be correct.... why?
  local info = self.rawstats[ func ].func_info
  -- local info = debug.getinfo( func )

  local name = ""
  if info.what == "Lua" then
    name = "L:"
  end
  if info.what == "C" then
    name = "C:"
  end
  if info.what == "main" then
    name = " :"
  end

  if info.namewhat ~= nil then
    name = name .. info.namewhat .. ":"
  end
  if info.name == nil then
    name = name .. "<"..tostring(func) .. ">"
  else
    name = name .. info.name
  end

  if info.short_src then
    name = name .. "@" .. info.short_src
  else
    if info.what == "C" then
      name = name .. "@?"
    else
      name = name .. "@<string>"
    end
  end
  name = name .. ":"
  if info.what == "C" then
    name = name .. "?"
  else
    name = name .. info.linedefined
  end

  return name
end


--
-- This allows you to specify functions which you do
-- not want profiled.
--
-- BUG: 2 will probably act exactly like 1 in "time" mode.
-- If anyone cares, let me (zorba) know and it can be fixed.
--
---!param self table
---@param func function
---@param enable boolean?
function _profiler.prevent(self, func, enable)
  enable = enable or true  -- SWD
  if enable then
    self.prevented_functions[func] = true
  else
    self.prevented_functions[func] = nil
  end
end


---@type table<function, boolean>
_profiler.prevented_functions = {
  [_profiler.start] = true,
  [_profiler.stop] = true,
  [_profiler_hook_wrapper_by_time] = true,
  [_profiler_hook_wrapper_by_call] = true,
  [_profiler.prevent] = true,
  [_profiler.report] = true,
  [_profiler.lua_report] = true,
  [_profiler._pretty_name] = true

}

if profiler then profiler:stop(); end;
profiler = newProfiler("time", 250)

profiler:prevent(profiler, start)
profiler:prevent(profiler, stop)
profiler:prevent(profiler, profile)
