--[[
  PoppyCoop world sync (v0.4)
  ---------------------------
  1. Activations: the quest system drives doors/puzzles/streaming through a shared set of
     interface functions (DoorOpen, ElectricalInterface, GrabButton, ...). We hook those on every
     class that has them; when one fires locally we broadcast it WITH ITS ARGUMENTS, and peers
     call the same function on the same level-placed actor.
  2. Pickups: "On Interact" on a level actor that then disappears = picked up -> removed for everyone.
  3. Inventory: the player's inventory functions (add/remove item) are replicated with their
     arguments, so everyone shares one team inventory.
  4. Hands: gaining a GrabPack hand gives it to everyone.
  5. Levels: streaming slots are kept in sync (union of what every player's game wants).
  6. Ledger: applied events are remembered; re-applied when a level reloads; sent to late joiners.

  IMPORTANT (UE4SS 3.0.1): every error raised from UE4SS's C++ side leaks Lua C-stack, even inside
  pcall, and after a few hundred the mod dies with "C stack overflow". So this file checks validity
  and argument counts BEFORE calling into the engine instead of relying on pcall.
]]
local P = _G.PoppyCoop
local Coop, Net, Game, Config, log, valid, try = P.Coop, P.Net, P.Game, P.Config, P.log, P.valid, P.try

local SYNC_ACT = Config.sync_activations ~= false
local SYNC_DESTROY = Config.sync_destroy ~= false
local SYNC_LEVELS = Config.sync_levels ~= false
local SYNC_HANDS = Config.sync_hands ~= false
local SYNC_INV = Config.sync_inventory ~= false
local TRACE = Config.trace == true or Config.trace == "true"     -- debug log of every hooked call (slow): off by default
do  -- or switched on by a file (the launcher rewrites config.txt on every start)
    local f = io.open(P.MOD_DIR .. "\\trace_on.txt", "r")
    if f then f:close(); TRACE = true end
end

------------------------------------------------------------------ tracing
local trace_f
local trace_count = {}
local function trace(fmt, ...)
    if not TRACE then return end
    -- rate limit per message shape so a chatty function can't flood the file
    if fmt:find("^CALL") then
        local k = tostring((...))
        local c = (trace_count[k] or 0) + 1
        trace_count[k] = c
        if c > 200 then return end
        if c == 200 then fmt = fmt .. "  [further calls of this function not traced]" end
    end
    if not trace_f then
        local tag = (os.getenv and os.getenv("POPPYCOOP_NAME")) and ("_" .. tostring(Config.name):gsub("[^%w_%-]", "_")) or ""
        trace_f = io.open(P.MOD_DIR .. "\\trace_" .. tostring(Config.mode) .. tag .. ".log", "a")
        if not trace_f then TRACE = false; return end
        trace_f:write(("\n==== session %s ====\n"):format(os.date("%Y-%m-%d %H:%M:%S")))
    end
    local ok, s = pcall(string.format, fmt, ...)
    trace_f:write(("[%8.2f] %s\n"):format(P.game_time(), ok and s or tostring(fmt)))
    trace_f:flush()
end

local function fullpath(obj)
    if not valid(obj) then return nil end
    local s = try(function() return obj:GetFullName() end)
    if not s then return nil end
    return s:match("^%S+ (.+)$") or s
end

-- Child actors (e.g. Chapter 2's "ChildActor_GEN_VARIABLE_DoorChildBP_C_CAT_7972") get a random number
-- that differs between games. Name them through their parent instead: "<parent path>#<component name>".
local function actor_path(obj)
    local p = fullpath(obj)
    if p and p:find("ChildActor_GEN_VARIABLE_", 1, true) then
        local ok, cp = pcall(function()
            local parent, comp = obj:GetParentActor(), obj:GetParentComponent()
            if parent and parent:IsValid() and comp and comp:IsValid() then
                local pp, cn = fullpath(parent), comp:GetFName():ToString()
                if pp and cn and not cn:find("%s") then return pp .. "#" .. cn end
            end
        end)
        if ok and cp then return cp end
    end
    return p
end
local find_actor   -- defined in the ledger section; used by resolve_object for child-actor paths
local function is_level_placed(path)
    -- runtime-spawned actors get large numeric suffixes (e.g. _2147482403)
    local base = path and (path:match("^([^#]+)#") or path)
    return base and base:find(":PersistentLevel.", 1, true) and not base:match("_21474%d%d%d%d%d$")
end

local function pawn()
    local p = Game.pawn
    if valid(p) then return p end
    return nil
end

local watch_actor   -- forward declarations
local claim_levels   -- forward declaration (levels section): claim_levels({names}, wanted)

-- read a TArray<FName/FString> property as a list of strings (anything else is ignored)
local function name_array(obj, prop)
    local out = {}
    local arr = try(function() return obj[prop] end)
    if not arr then return out end
    local okt, t = pcall(function() return arr:type() end)
    if not okt or t ~= "TArray" then return out end
    local okn, num = pcall(function() return arr:GetArrayNum() end)
    if not okn or type(num) ~= "number" or num <= 0 then return out end
    pcall(function()
        arr:ForEach(function(_, elem)
            local v = elem:get()
            if type(v) == "string" then out[#out + 1] = v
            elseif type(v) == "userdata" or (type(v) == "table" and type(v.type) == "function") then
                local okt, t = pcall(function() return v:type() end)
                if okt and (t == "FName" or t == "FString") then out[#out + 1] = v:ToString() end
            end
        end)
    end)
    return out
end

------------------------------------------------------- argument codec
--[[ Arguments travel as space-separated tokens "<tag>:<value>", value percent-encoded.
     tags: b bool, n number, s string, N name, T text, o object path, p "the acting player's pawn",
     0 null object. Anything else (structs, arrays...) makes the call un-replicable. ]]
local NUMERIC = { IntProperty = 1, Int64Property = 1, Int8Property = 1, Int16Property = 1, UInt16Property = 1,
    UInt32Property = 1, UInt64Property = 1, FloatProperty = 1, DoubleProperty = 1, ByteProperty = 1, EnumProperty = 1 }
local OBJECTY = { ObjectProperty = 1, ClassProperty = 1, WeakObjectProperty = 1, InterfaceProperty = 1 }

local function esc(s) return (tostring(s):gsub("[%%%s|]", function(c) return ("%%%02X"):format(c:byte()) end)) end
local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local OBJECT_TYPES = { UObject = 1, AActor = 1, UClass = 1, UStruct = 1, UFunction = 1, UWorld = 1, UEnum = 1,
    UActorComponent = 1, USceneComponent = 1 }

-- escape everything except [A-Za-z0-9_] (used for struct fields so ',' '=' ':' stay unambiguous)
local function esc_all(s) return (tostring(s):gsub("[^%w_]", function(c) return ("%%%02X"):format(c:byte()) end)) end

local NUMERIC_T = { IntProperty = 1, Int64Property = 1, Int8Property = 1, Int16Property = 1, UInt16Property = 1,
    UInt32Property = 1, UInt64Property = 1, FloatProperty = 1, DoubleProperty = 1, ByteProperty = 1, EnumProperty = 1 }

-- Encode one value (a param's get() result, or a struct field) as "<tag>:<value>". Returns token or nil, why.
local encode_value
local function encode_struct(v)
    -- read the struct's field list from its definition, then each simple field by name
    local fields = {}
    local ok = pcall(function()
        v:GetProperty():GetStruct():ForEachProperty(function(p)
            fields[#fields + 1] = { p:GetFName():ToString(), p:GetClass():GetFName():ToString() }
        end)
    end)
    if not ok or #fields == 0 then return nil, "struct fields unreadable" end
    local parts = {}
    for _, f in ipairs(fields) do
        local name, t = f[1], f[2]
        if t == "BoolProperty" or NUMERIC_T[t] or t == "StrProperty" or t == "NameProperty" or t == "TextProperty"
            or t == "ObjectProperty" or t == "ClassProperty" then
            local okv, fv = pcall(function() return v[name] end)
            if okv then
                local tok = encode_value(fv, true)
                if tok then parts[#parts + 1] = esc_all(name) .. "=" .. esc_all(tok) end
            end
        end   -- arrays / nested structs / maps: left at their defaults on the other side
    end
    return "t:" .. table.concat(parts, ",")
end

encode_value = function(v, in_struct)
    local my = pawn()
    local tv = type(v)
    if tv == "boolean" then return "b:" .. (v and "1" or "0")
    elseif tv == "number" then return "n:" .. tostring(v)
    elseif tv == "string" then return "s:" .. esc(v)
    elseif tv == "nil" then return "0:"
    elseif tv == "userdata" or (tv == "table" and type(v.type) == "function") then
        local okt, ut = pcall(function() return v:type() end)
        if not okt or type(ut) ~= "string" then return nil, "no type" end
        if ut == "FString" or ut == "FName" or ut == "FText" then
            local oks, str = pcall(function() return v:ToString() end)
            if not oks then return nil, ut .. " read" end
            return (ut == "FString" and "s:" or ut == "FName" and "N:" or "T:") .. esc(str)
        elseif ut == "TArray" then
            -- lists can't be sent; replay with an empty list (UE4SS leaves the param empty, no error).
            -- Used for Chapter 2's door "On Interact(<list>)".
            if P.CHAPTER ~= 2 then return nil, "unsupported param type TArray" end
            return "a:"
        elseif ut == "UScriptStruct" then
            if in_struct then return nil, "nested struct" end
            return encode_struct(v)
        elseif OBJECT_TYPES[ut] or ut:match("^U%u") or ut:match("^A%u") then
            if not valid(v) then return "0:" end
            local path = actor_path(v)
            if not path then return nil, "object path" end
            if my and path == fullpath(my) then return "p:" end
            return "o:" .. esc(path)
        end
        return nil, "unsupported param type " .. tostring(ut)
    end
    return nil, "unsupported lua type " .. tv
end

local function encode_args(params, nparams)
    if nparams == 0 then return "" end
    local out = {}
    for i = 1, nparams do
        local prm = params[i]
        local ok, v = pcall(function() return prm:get() end)
        if not ok then return nil, "param " .. i .. " unreadable" end
        local tok, why = encode_value(v)
        if not tok then return nil, why end
        out[#out + 1] = tok
    end
    return table.concat(out, " ")
end

-- find an object by path; assets (not level actors) are loaded if needed
local function resolve_object(path)
    if path:find("#", 1, true) then return find_actor(path) end
    local o = try(StaticFindObject, path)
    if valid(o) then return o end
    -- not loaded: ask the game thread to load it (never call LoadAsset from a hook - engine error)
    if not path:find(":PersistentLevel", 1, true) and P.load_async then P.load_async((path:match("^(.-):") or path)) end
    return nil
end

-- decode one "<tag>:<value>" token (value already unescaped)
local decode_value
decode_value = function(tag, val)
    if tag == "b" then return true, (val == "1")
    elseif tag == "n" then return true, tonumber(val)
    elseif tag == "s" then return true, val
    elseif tag == "N" then if not FName then return false, "no FName" end return true, FName(val)
    elseif tag == "T" then if not FText then return false, "no FText" end return true, FText(val)
    elseif tag == "p" then local p = pawn(); if not p then return false, "no local pawn" end return true, p
    elseif tag == "0" then return true, nil
    elseif tag == "a" then return true, { __array = true }
    elseif tag == "o" then
        local o = resolve_object(val)
        if not o then return false, "object not loaded: " .. val end
        return true, o
    elseif tag == "t" then
        local t = {}
        for pair in val:gmatch("[^,]+") do
            local k, tok = pair:match("^([^=]+)=(.*)$")
            if k then
                local ftag, fval = unesc(tok):match("^(.):(.*)$")
                if ftag then
                    local ok, fv = decode_value(ftag, unesc(fval))
                    if ok and fv ~= nil then t[unesc(k)] = fv end   -- unresolvable fields keep defaults
                end
            end
        end
        return true, t
    end
    return false, "unknown tag " .. tag
end

-- decode into a Lua arg list; returns args, n  or nil (+reason)
local function decode_args(s)
    local args, n = {}, 0
    for tok in (s or ""):gmatch("%S+") do
        local tag, val = tok:match("^(.):(.*)$")
        if not tag then return nil, "bad token " .. tok end
        n = n + 1
        local ok, v = decode_value(tag, tag == "t" and val or unesc(val))
        if not ok then return nil, v end
        args[n] = v
    end
    return args, n
end

------------------------------------------------------- echo suppression
local replaying = 0          -- >0 while we apply a remote event
local recent = {}            -- key -> game_time, events we sent or applied (dedupe window)
local DEDUPE = 8.0
-- Interactions (doors etc.) fire several times while the button is held; one press = one event.
-- A deliberate second press a moment later (close the door again) must still go through.
local DEDUPE_INTERACT = 1.2
local function seen_recently(key)
    local t = recent[key]
    local window = key:find("|On Interact|", 1, true) and DEDUPE_INTERACT or DEDUPE
    return t and P.game_time() - t < window
end
local function mark(key) recent[key] = P.game_time() end

------------------------------------------------------------------ ledger
local Ledger = {}            -- ordered list of { kind, path, fn, args, remote }
local LedgerKeys = {}
local Pending = {}           -- key -> event whose actor isn't loaded locally yet

local function ekey(kind, path, fn, args) return kind .. "|" .. path .. "|" .. (fn or "") .. "|" .. (args or "") end

local function ledger_add(kind, path, fn, args, remote, allow_dupes)
    local key = ekey(kind, path, fn, args)
    if LedgerKeys[key] and not allow_dupes then return end
    LedgerKeys[key] = true
    Ledger[#Ledger + 1] = { kind = kind, path = path, fn = fn, args = args, remote = remote }
end

local ChildCache = {}
find_actor = function(path)
    local parent_path, comp_name = path:match("^([^#]+)#(.+)$")
    if not parent_path then
        local o = try(StaticFindObject, path)
        if valid(o) then return o end
        return nil
    end
    -- the parent is looked up fresh every time; a cached child is only used while it belongs to the
    -- very same parent object (levels stream out and back in: a stale child must never be touched)
    local parent = try(StaticFindObject, parent_path)
    if not valid(parent) then return nil end
    local paddr = try(function() return parent:GetAddress() end)
    local c = ChildCache[path]
    if c and c.paddr == paddr then return c.a end
    local found
    pcall(function()
        local cls = StaticFindObject("/Script/Engine.ChildActorComponent")
        local comps = parent:K2_GetComponentsByClass(cls)
        for i = 1, #comps do
            local comp = comps[i]:get()
            if comp:IsValid() and comp:GetFName():ToString() == comp_name then
                local a = comp.ChildActor
                if a and a:IsValid() then found = a end
                break
            end
        end
    end)
    ChildCache[path] = found and { a = found, paddr = paddr } or nil
    return found
end

-- UE4SS 3.0.1 cannot pass a struct with string/object fields as a parameter (its table->struct code
-- reads the wrong stack slot), and its BP hooks run AFTER the function body, so the params can't be
-- fixed up in a hook either. Instead: call with an empty struct, then find where the object stored it
-- (an array property whose element struct has exactly these fields) and fill the blank entry in place -
-- writing single fields of a live struct works fine.
local StructArrays = {}      -- class full name -> { array property names }
local function struct_arrays(obj, keys)
    local cls = obj:GetClass()
    local ck = fullpath(cls) or "?"
    local cache = StructArrays[ck]
    if not cache then
        cache = {}
        local guard = 0
        while cls and valid(cls) and guard < 4 do
            guard = guard + 1
            pcall(function()
                cls:ForEachProperty(function(p)
                    local okc, cn = pcall(function() return p:GetClass():GetFName():ToString() end)
                    if okc and cn == "ArrayProperty" then
                        local okn, names = pcall(function()
                            local inner = p:GetInner()
                            if inner:GetClass():GetFName():ToString() ~= "StructProperty" then return nil end
                            local n = {}
                            inner:GetStruct():ForEachProperty(function(f) n[f:GetFName():ToString()] = true end)
                            return n
                        end)
                        if okn and names then
                            cache[#cache + 1] = { name = p:GetFName():ToString(), fields = names }
                        end
                    end
                end)
            end)
            local oks, sup = pcall(function() return cls:GetSuperStruct() end)
            cls = oks and sup or nil
        end
        StructArrays[ck] = cache
        local list = {}
        for _, c in ipairs(cache) do list[#list + 1] = c.name end
        trace("struct arrays on %s: %s", ck, table.concat(list, ", "))
    end
    local out = {}
    for _, c in ipairs(cache) do
        local all = true
        for k in pairs(keys) do if not c.fields[k] then all = false break end end
        if all then out[#out + 1] = c.name end
    end
    return out
end

local function is_blank(sv, keys)
    for k, want in pairs(keys) do
        local ok, cur = pcall(function() return sv[k] end)
        if not ok then return false end
        if type(want) == "string" then
            local s = cur
            if type(cur) ~= "string" then
                local okt, str = pcall(function() return cur:ToString() end)
                s = okt and str or nil
            end
            if s ~= nil and s ~= "" then return false end
        end
    end
    return true
end

local function patch_struct_entry(obj, fields)
    local names = struct_arrays(obj, fields)
    local patched = 0
    for _, an in ipairs(names) do
        pcall(function()
            local arr = obj[an]
            local num = arr:GetArrayNum()
            for i = num, 1, -1 do            -- newest entries are at the end
                local sv = arr[i]
                if sv and is_blank(sv, fields) then
                    for k, v in pairs(fields) do
                        local okf, e = pcall(function() sv[k] = v end)
                        if not okf then trace("  fill %s[%d].%s failed: %s", an, i, tostring(k), tostring(e)) end
                    end
                    patched = patched + 1
                    break
                end
            end
        end)
    end
    trace("  filled %d stored entr%s (%s)", patched, patched == 1 and "y" or "ies", table.concat(names, ","))
    return patched
end

-- call a UFunction by name on obj with encoded args. Returns "ok", "later" (target not loaded) or "skip".
local function call_with(obj, fnname, argstr)
    local args, n = decode_args(argstr)
    if not args then
        trace("  cannot decode args (%s)", tostring(n))
        return tostring(n):find("not loaded", 1, true) and "later" or "skip"
    end
    -- the count always matches: hooks receive NumParms minus the return value, which is exactly what
    -- UE4SS expects when calling (UFunction __call), so we replay with the captured count.
    -- struct args go in empty; patch_struct_entry fills the stored copy afterwards (see above)
    local fill = nil
    for i = 1, n do
        local a = args[i]
        if type(a) == "table" and not a.__array and not (getmetatable(a) and type(a.type) == "function") then
            fill = fill or { fn = fnname }
            fill[i] = a
            args[i] = {}
        end
    end
    replaying = replaying + 1
    local ok, err = pcall(function() obj[fnname](obj, table.unpack(args, 1, n)) end)
    replaying = replaying - 1
    if ok and fill then
        for i = 1, n do if fill[i] then pcall(patch_struct_entry, obj, fill[i]) end end
    end
    if not ok then trace("  call %s failed: %s", fnname, tostring(err)) end
    return "ok"
end

-- Chapter 2 doors (DoorBP + its DoorChildBP leaves): another player opened it -> swing it open here.
-- "Force Door Open" on every leaf is idempotent (also fine on an already open door / after a reload),
-- and it opens key-locked doors without using up this player's own key.
local function call_any(obj, fn)
    replaying = replaying + 1
    local ok = pcall(function() obj[fn](obj) end)
    if not ok then ok = pcall(function() obj[fn](obj, true) end) end
    replaying = replaying - 1
    return ok
end
local function door_leaves(door)
    local out = {}
    pcall(function()
        local comps = door:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ChildActorComponent"))
        for i = 1, #comps do
            local c = comps[i]:get()
            local a = c:IsValid() and c.ChildActor
            if a and a:IsValid() then out[#out + 1] = a end
        end
    end)
    return out
end
local function open_door(a)
    local cname = fullpath(try(function() return a:GetClass() end)) or ""
    local n = 0
    if cname:find("DoorChildBP", 1, true) then
        if call_any(a, "Force Door Open") then n = n + 1 end
        local parent = try(function() return a:GetParentActor() end)
        if valid(parent) then a = parent end
    end
    for _, leaf in ipairs(door_leaves(a)) do
        if call_any(leaf, "Force Door Open") then n = n + 1 end
    end
    if n == 0 and call_any(a, "DoorOpen") then n = 1 end
    return n
end

-- returns true if done (applied or permanently skipped), false if the target isn't available yet
-- Rooms are public: a remote event may only call the functions this mod itself sends (filled in below,
-- once the function sets exist). Anything else from the network is dropped.
local remote_allowed
-- Checkpoints with 3+ players: only ever move forward. A remote "Save New Checkpoint" behind the
-- furthest one this game has seen (its own or anyone's) is ignored, so a player who is behind can't
-- reset everyone else's "Load Game" position.
local CP_MAX = -1
local CP_FIX = nil       -- set when a replayed trigger saved an older checkpoint: re-save the furthest
local function cp_fix_tick()
    if not CP_FIX then return end
    local n = CP_FIX
    CP_FIX = nil
    local gm = try(FindFirstOf, "Chapter2_Gamemode_C")
    if not valid(gm) then return end
    replaying = replaying + 1
    local ok = pcall(function() gm["Save New Checkpoint"](gm, n) end)
    replaying = replaying - 1
    trace("checkpoint restored to %d (%s)", n, tostring(ok))
end
local function cp_number(args) return tonumber(tostring(args or ""):match("^n:(%-?%d+)")) end
local function apply(e)
    if e.kind == "act" and e.fn == "Save New Checkpoint" then
        local n = cp_number(e.args)
        if n and n < CP_MAX then trace("checkpoint %d ignored (furthest is %d)", n, CP_MAX); return true end
        if n then CP_MAX = n end
    end
    if remote_allowed and e.remote_check and not remote_allowed(e) then
        trace("DROP not allowed: %s %s %s", tostring(e.kind), tostring(e.path), tostring(e.fn))
        return true
    end
    if e.kind == "act" and e.fn == "CoopOpenDoor" then
        local a = find_actor(e.path)
        if not a then return false end
        trace("APPLY door %s -> %d leaves opened", e.path, open_door(a))
        return true
    elseif e.kind == "act" then
        local a = find_actor(e.path)
        if not a then return false end
        local r = call_with(a, e.fn, e.args)
        trace("APPLY act %s %s(%s) -> %s", e.path, e.fn, e.args or "", r)
        return r ~= "later"
    elseif e.kind == "destroy" then
        local a = find_actor(e.path)
        if not a then return false end
        replaying = replaying + 1
        pcall(function() a:K2_DestroyActor() end)
        replaying = replaying - 1
        trace("APPLY destroy %s", e.path)
        return true
    elseif e.kind == "cfn" then
        local p = pawn()
        if not p then return false end
        local c = try(StaticFindObject, fullpath(p) .. "." .. e.path)
        if not valid(c) then return false end
        local r = call_with(c, e.fn, e.args)
        trace("APPLY component %s %s(%s) -> %s", e.path, e.fn, e.args or "", r)
        if r == "ok" then log("inventory: %s %s", e.fn, (e.args or ""):match("([%w_]+)$") or "") end
        return r ~= "later"
    elseif e.kind == "pfn" then
        local p = pawn()
        if not p then return false end
        local r = call_with(p, e.fn, e.args)
        trace("APPLY player %s(%s) -> %s", e.fn, e.args or "", r)
        if r == "ok" then log("inventory: %s %s", e.fn, (e.args or ""):gsub("%%20", " ")) end
        return r ~= "later"
    end
    return true
end

local function receive(e, from)
    e.remote_check = true
    if remote_allowed and not remote_allowed(e) then
        trace("DROP from %s (not allowed): %s %s %s", tostring(from), tostring(e.kind), tostring(e.path), tostring(e.fn))
        return
    end
    local key = ekey(e.kind, e.path, e.fn, e.args)
    ledger_add(e.kind, e.path, e.fn, e.args, true, e.kind == "pfn" or e.kind == "cfn")
    if e.kind ~= "pfn" and e.kind ~= "cfn" then
        if seen_recently(key) then trace("skip duplicate %s from %d", key, from); return end
        mark(key)
    end
    if not apply(e) then
        Pending[key .. ((e.kind == "pfn" or e.kind == "cfn") and ("#" .. #Ledger) or "")] = e
        trace("PENDING %s (target not loaded)", key)
    end
end

local function retry_pending()
    for key, e in pairs(Pending) do
        if apply(e) then Pending[key] = nil end
    end
end

-- A streamed level just (re)loaded: its actors are back in their initial state, so re-apply what
-- other players already did there (opened doors, picked-up items...).
local function replay_level(pkg)
    if not pkg then return end
    local needle = "." .. pkg .. ":PersistentLevel."
    local n = 0
    for _, e in ipairs(Ledger) do
        if e.remote and e.kind ~= "pfn" and e.kind ~= "cfn" and e.path:find(needle, 1, true) then
            if apply(e) then n = n + 1 end
        end
    end
    if n > 0 then log("level %s loaded: re-applied %d remote events", pkg, n) end
    retry_pending()
end

-- wire format:  act <path> <fn>|<args>     destroy <path>     pfn <fn>|<args>
Coop.on("act", function(from, rest)
    local path, fnargs = rest:match("^(%S+) (.+)$")
    if not path then return end
    local fn, args = fnargs:match("^([^|]+)|?(.*)$")
    receive({ kind = "act", path = path, fn = fn, args = args }, from)
end)
Coop.on("destroy", function(from, path) receive({ kind = "destroy", path = path }, from) end)
Coop.on("died", function(from, how)
    local pl = Net.players[from]
    log("%s died (%s)", pl and pl.name or ("player " .. from), tostring(how))
end)
Coop.on("cfn", function(from, rest)
    local sub, fn, args = rest:match("^(%S+) ([^|]+)|?(.*)$")
    if sub then receive({ kind = "cfn", path = sub, fn = fn, args = args }, from) end
end)
Coop.on("pfn", function(from, rest)
    local fn, args = rest:match("^([^|]+)|?(.*)$")
    if fn then receive({ kind = "pfn", path = "pawn", fn = fn, args = args }, from) end
end)

local function send(e)
    if e.kind == "act" then Coop.send_event("act", e.path .. " " .. e.fn .. "|" .. (e.args or ""))
    elseif e.kind == "destroy" then Coop.send_event("destroy", e.path)
    elseif e.kind == "pfn" then Coop.send_event("pfn", e.fn .. "|" .. (e.args or ""))
    elseif e.kind == "cfn" then Coop.send_event("cfn", e.path .. " " .. e.fn .. "|" .. (e.args or "")) end
end

-- host sends everything that already happened to a late joiner
table.insert(P.Handlers.join, function(id, name)
    if not Coop.is_host() or #Ledger == 0 then return end
    log("sending %d ledger events to %s", #Ledger, name)
    for _, e in ipairs(Ledger) do
        if e.kind == "act" then Coop.send_to(id, "act", e.path .. " " .. e.fn .. "|" .. (e.args or ""))
        elseif e.kind == "destroy" then Coop.send_to(id, "destroy", e.path)
        elseif e.kind == "pfn" then Coop.send_to(id, "pfn", e.fn .. "|" .. (e.args or ""))
        elseif e.kind == "cfn" then Coop.send_to(id, "cfn", e.path .. " " .. e.fn .. "|" .. (e.args or "")) end
    end
    local p = pawn()
    if p then
        if try(function() return p["hasRightHand?"] end) then Coop.send_to(id, "hand", "R") end
        if try(function() return p["hasLeftHand?"] end) then Coop.send_to(id, "hand", "L") end
    end
end)

----------------------------------------------------------- local hooks
local ACT_FNS = { "DoorOpen", "DoorClose", "UpdateLightPads", "UpdateVolume", "DestroyDoor", "Left", "Right", "Stop",
    "Deactivate", "LockDoor", "ButtonUp", "ButtonDown", "ButtonLeft", "ButtonRight", "GrabButton",
    "ToyMachineOne", "ToyMachineTwo", "ToyMachineThree", "ElectricalInterface",
    "Trigger Checkpoint", "Save New Checkpoint",     -- checkpoints: reaching one saves it for everyone
    "Remove3DItemFromPlayerInventory" }              -- Chapter 2: a door/slot used up an inventory item
local ACT_SET = {}
for _, f in ipairs(ACT_FNS) do ACT_SET[f] = true end
-- Chapter 2 doors: any of these on a DoorBP/DoorChildBP means "this door is being opened". Shared as a
-- single CoopOpenDoor event (replaying DoorOpen/Remove3DItem alone does not swing the door, and replaying
-- Remove3DItem took the other player's key away).
local DOOR_FNS = { "DoorInteraction", "DoorOpen", "Force Door Open", "Force Interact", "Force ParentInteraction",
    "On Door Interact Door", "On Door Interact Left", "Remove3DItemFromPlayerInventory", "On Interact",
    -- Chapter 1 doors
    "Event Open Door", "UnlockAndOpenDoor", "Force Open Door", "Open Left Door Event", "Open Right Door Event" }
local DOOR_SET = {}
for _, f in ipairs(DOOR_FNS) do DOOR_SET[f] = true end
local function is_door_class(cname)
    return cname:find("/DoorBP%.") or cname:find("/DoorChildBP%.")                     -- Chapter 2
        or cname:find("/DoubleDoors%.") or cname:find("/SingleDoors_BP%.")             -- Chapter 1
end
-- Chapter 2 puzzle pieces: when a player does this locally, the other games run the object's own
-- "force" function (the puzzle step completes there without needing the item/hands).
local REMAP = {
    BP_FurnaceDoor_C = { ["On Interact"] = "ForceOpen" },
    BP_FurnaceDoor_Left_C = { ["On Interact"] = "ForceOpen" },
    BP_GearMachineControlledDoor_C = { ["On Interact"] = "ForcePlace" },
    BP_MoldInsertSlot_C = { ["On Interact"] = "ForcePlace" },
    BP_ToyMachineGear_C = { ["On Interact"] = "ForcePlaceItem" },
    Paint_CartridgeSlot_C = { ["Send Cartridge"] = "Force Insert Cartridge" },
    GarageLever_C = { ["Pull Down"] = "ForcePullDown" },
    BP_MoveableCart_C = { SmashBoards = "SmashBoards", SnapToPlace = "SnapToPlace" },
    -- Chapter 1
    SecurityPadInteractionBP_C = { OpenDoors = "Force Correct Code" },
    LeftHandAccessPad_C = { ["Activate Blueprints"] = "Force Complete" },
}
local function short_class(cname) return cname and cname:match("([^%.]+)$") end
local REMAP_TARGETS = {}
for _, m in pairs(REMAP) do for _, fn in pairs(m) do REMAP_TARGETS[fn] = true end end
local DESTROY_OK = { "pickup", "3ditem", "item", "collect", "vhs", "key", "tape", "trophy", "battery", "hand", "web", "vent" }
-- player inventory mutators: replicated to every other player's own pawn
local INV_FNS = { "Add Stored Item In Inventory", "Remove Item From Inventory", "Remove Stored Item From Inventory" }
local DEATH_SET = { DeathCam = 1, DeathScreenUI = 1, DeathCamVents = 1, Limondeath = 1, DeathLimon = 1 }
local INV_SET = {}
for _, f in ipairs(INV_FNS) do INV_SET[f] = true end
-- Chapter 2 inventory: the player's PlayerInventoryComponent collects 3D items (replicated as "cfn")
local COMP_INV_SET = { Collect3DInventoryItem = true }
-- Chapter 2 pickups: the item in the world is collected -> remove it for everyone
local PICKUP_SET = { Collect3DItem = true, ForceCollect3DItem = true }
local TRACE_FNS = { "Load Levels", "Trigger Checkpoint", "Save New Checkpoint", "On Interact", "Load Checkpoint",
    "Pick Up Object", "Activate Right Hand", "Activate Left Hand", "DeathCam", "DeathScreenUI", "DeathCamVents",
    "Limondeath", "GrabPackInteraction", "DoorInteraction", "On Checkpoint Loaded", "Update Level" }
-- anything with these words in its name is traced too (to discover inventory/hotbar plumbing)
local TRACE_WORDS = { "inventory", "hotbar", "item", "pickup", "pick up", "store", "equip" }
local SKIP_FN = { ExecuteUbergraph = 1, UserConstructionScript = 1, ReceiveTick = 1, ReceiveBeginPlay = 1,
    ["Pick Up Update"] = 1, ["Store Standing On Objs"] = 1 }      -- per-frame in Chapter 2: not worth hooking

-- Which "On Interact" calls are world mechanisms (replayed on peers) vs personal pickups (not replayed;
-- their disappearance is synced instead). Matched against the actor's name. Overridable in config.txt.
local REPLAY_PATTERNS = {}
for p in tostring(Config.interact_replay or "Door,Grate,Vent,Lever,Button,Switch,Breaker,Claw,Machine,Gate,Elevator,Lift,Power,Fuse"):gmatch("[^,%s]+") do
    REPLAY_PATTERNS[#REPLAY_PATTERNS + 1] = p:lower()
end
local NO_REPLAY = { "tape", "vhs", "storage", "pickup", "battery", "hand", "item", "collect" }
local function replay_interact(path)
    local name = (path:match("%.([^.]+)$") or path):lower()
    for _, p in ipairs(NO_REPLAY) do if name:find(p, 1, true) then return false end end
    for _, p in ipairs(REPLAY_PATTERNS) do if name:find(p, 1, true) then return true end end
    return false
end

remote_allowed = function(e)
    local base = e.path and (e.path:match("^([^#]+)#") or e.path)
    if e.kind == "act" then
        if not is_level_placed(e.path) then return false end
        if ACT_SET[e.fn] or REMAP_TARGETS[e.fn] then return true end
        if e.fn == "On Interact" then return replay_interact(e.path) end
        return false
    elseif e.kind == "cfn" then
        return COMP_INV_SET[e.fn] == true and e.path == "PlayerInventoryComponent"
    elseif e.kind == "pfn" then
        return INV_SET[e.fn] == true
    elseif e.kind == "destroy" then
        if not is_level_placed(e.path) or base:find("PlayerBP", 1, true) then return false end
        local name = (base:match("%.([^.]+)$") or ""):lower()
        local a = find_actor(e.path)
        local cls = a and (fullpath(try(function() return a:GetClass() end)) or "") or ""
        local l = (name .. " " .. cls):lower()
        for _, w in ipairs(DESTROY_OK) do if l:find(w, 1, true) then return true end end
        return false
    end
    return false
end

local hooked_classes = {}
local HookedFns = {}   -- "class:fn" for inventory/pickup-ish names (diagnostics)
local hook_count, hook_fail = 0, 0
local ctx_ok, ctx_fail = 0, 0

local function share(e)
    local key = ekey(e.kind, e.path, e.fn, e.args)
    ledger_add(e.kind, e.path, e.fn, e.args, false, e.kind == "pfn" or e.kind == "cfn")
    if e.kind ~= "pfn" and e.kind ~= "cfn" then
        if seen_recently(key) then
            if key:find("|On Interact|", 1, true) then mark(key) end   -- still the same held press
            return
        end
        mark(key)
    end
    send(e)
end

-- A hooked Blueprint function that fires many times a second (per-frame logic) is never one we need to
-- share, and running Lua for it every frame costs FPS. Count calls; past 25 a second it is ignored.
local Hot, HotCount, HotSec = {}, {}, -1
local DISCOVER = Config.discover == true or Config.discover == "true"
local function on_local_call(cname, fnname, ctx, ...)
    local hk = cname .. ":" .. fnname
    if P.crumb then P.crumb("hook " .. hk:match("([^/]+)$")) end
    local pf = P.Perf
    if pf then pf.hooks = pf.hooks + 1; pf.by[hk] = (pf.by[hk] or 0) + 1 end
    if Hot[hk] then return end
    local sec = math.floor(os.clock())
    if sec ~= HotSec then HotSec = sec; HotCount = {} end
    local c = (HotCount[hk] or 0) + 1
    HotCount[hk] = c
    if c > 25 and not DEATH_SET[fnname] then
        Hot[hk] = true
        log("ignoring %s (called every frame)", hk)
        return
    end
    local obj
    local ok = pcall(function() obj = ctx:get() end)
    if not ok or not valid(obj) then ctx_fail = ctx_fail + 1; return end
    ctx_ok = ctx_ok + 1
    local path = actor_path(obj)
    local nparams = select("#", ...)
    local args, why = encode_args({ ... }, nparams)
    trace("CALL %s(%s) on %s%s", fnname, args or ("?" .. tostring(why)), tostring(path), replaying > 0 and " (replay)" or "")
    -- The local game is deciding what to stream: read exactly which maps from the caller's own lists,
    -- so maps we only hold for the other player are claimed as ours only when the game really asks.
    if path then
        if fnname == "Load Levels" and path:find("LevelStreamingVolume", 1, true) then
            claim_levels(name_array(obj, "LevelsToLoad"), true)
            claim_levels(name_array(obj, "LevelsToUnload"), false)
        elseif fnname == "Load Checkpoint" and path:find("PlayerCheckpoint", 1, true) then
            claim_levels(name_array(obj, "Levels"), true)
        elseif ACT_SET[fnname] and path:find("StreamInLevel", 1, true) then
            claim_levels(name_array(obj, "Levels To Stream In"), true)
        end
    end
    if fnname == "Save New Checkpoint" and args then
        local n = cp_number(args)
        if n and n > CP_MAX then CP_MAX = n
        elseif n and n < CP_MAX and replaying > 0 then CP_FIX = CP_MAX end   -- an older trigger was replayed here
    end
    if replaying > 0 or not Coop.active() or not path then return end

    if DEATH_SET[fnname] and cname:find("PlayerBP", 1, true) then
        if not Game.dead then
            Game.dead = true
            Coop.send_event("died", fnname)
            log("you died (%s) - your friends see you fall", fnname)
        end
        return
    end
    if INV_SET[fnname] and cname:find("PlayerBP", 1, true) then
        if not SYNC_INV then return end
        if not args then log("inventory %s not shareable: %s", fnname, tostring(why)); return end
        share({ kind = "pfn", path = "pawn", fn = fnname, args = args })
        log("shared inventory change: %s", fnname)
        return
    end
    if COMP_INV_SET[fnname] then
        -- runs on a component of OUR player: "...PlayerBP_C_2147482413.PlayerInventoryComponent"
        -- the component's owner, looked up fresh: this can fire while a level loads (inventory restored
        -- from the save), when the cached pawn may already be freed
        local pp = fullpath(try(function() return obj:GetOwner() end))
        local sub = pp and path:sub(1, #pp + 1) == pp .. "." and path:sub(#pp + 2) or path:match("PlayerBP[%w_]*%.(.+)$")
        if not SYNC_INV or not sub then return end
        if not args then log("inventory %s not shareable: %s", fnname, tostring(why)); return end
        share({ kind = "cfn", path = sub, fn = fnname, args = args })
        log("shared inventory change: %s", fnname)
        return
    end
    local rm = REMAP[short_class(cname)]
    if rm and rm[fnname] then
        if SYNC_ACT and is_level_placed(path) then
            share({ kind = "act", path = path, fn = rm[fnname], args = "" })
        end
        return
    end
    -- Chapter 2 doors are synced by the leaves' real rotation (pose sync in coop_extra); replaying
    -- their functions would snap them open the wrong way and would use up the other player's key.
    if DOOR_SET[fnname] and is_door_class(cname) then return end
    if PICKUP_SET[fnname] and is_level_placed(path) then
        watch_actor(path)
        if SYNC_DESTROY then share({ kind = "destroy", path = path }) end
        return
    end
    if fnname == "On Interact" and is_level_placed(path) then
        watch_actor(path)
        if SYNC_ACT and replay_interact(path) and args then
            share({ kind = "act", path = path, fn = fnname, args = args })
        end
        return
    end
    -- Chapter 2 streams areas in/out with ToggleStreamingLevelVisibility triggers. Each game must run its
    -- own (replaying a "hide" could empty the area the other player is standing in); the level sync
    -- module keeps whatever any player needs loaded.
    if path:find("ToggleStreamingLevelVisibility", 1, true) then return end
    if SYNC_ACT and ACT_SET[fnname] and is_level_placed(path) then
        if not args then trace("  not replicable: %s", tostring(why)); return end
        share({ kind = "act", path = path, fn = fnname, args = args })
    end
end

local seen_class_addr = {}
local function hook_class(cls, trace_everything)
    local addr = try(function() return cls:GetAddress() end)
    if addr and seen_class_addr[addr] then return end
    if addr then seen_class_addr[addr] = true end
    local cname = fullpath(cls)
    if not cname then return end
    local key = cname .. "@" .. tostring(addr or "")
    if hooked_classes[key] then return end
    hooked_classes[key] = true
    if not cname:find("^/Game/") then return end           -- only blueprint classes
    local fns = {}
    pcall(function() cls:ForEachFunction(function(fn) fns[fn:GetFName():ToString()] = fn end) end)
    local done = {}
    local function try_hook(fname)
        if not fns[fname] or done[fname] then return end
        done[fname] = true
        local flags = try(function() return fns[fname]:GetFunctionFlags() end) or 0
        if (flags & 0x00100000) ~= 0 or (flags & 0x00000400) ~= 0 then return end   -- delegate / native: not hookable safely
        local ok, err = pcall(RegisterHook, cname .. ":" .. fname, function(ctx, ...) on_local_call(cname, fname, ctx, ...) end)
        if ok then
            local l = fname:lower()
            for _, w in ipairs(TRACE_WORDS) do if l:find(w, 1, true) then HookedFns[cname .. ":" .. fname] = true end end
        end
        if ok then hook_count = hook_count + 1 else hook_fail = hook_fail + 1; trace("hook failed %s:%s %s", cname, fname, tostring(err)) end
    end
    for _, f in ipairs(ACT_FNS) do try_hook(f) end
    if is_door_class(cname) then for _, f in ipairs(DOOR_FNS) do try_hook(f) end end
    local rm = REMAP[short_class(cname)]
    if rm then for f in pairs(rm) do try_hook(f) end end
    for _, f in ipairs(INV_FNS) do try_hook(f) end
    for f in pairs(COMP_INV_SET) do try_hook(f) end
    for f in pairs(PICKUP_SET) do try_hook(f) end
    for _, f in ipairs(TRACE_FNS) do try_hook(f) end
    for fname in pairs(fns) do
        local query = fname:find("^Get") or fname:find("^Is") or fname:find("^Can") or fname:find("Has ", 1, true) or fname:find("%?$")
        if not query and not SKIP_FN[fname] and not fname:find("__", 1, true) and not fname:find("^ExecuteUbergraph") and not fname:find("^InpActEvt") then
            local l = fname:lower()
            local hit = DISCOVER and trace_everything
            if DISCOVER then for _, w in ipairs(TRACE_WORDS) do if l:find(w, 1, true) then hit = true end end end
            if hit then try_hook(fname) end
        end
    end
end

-- component classes that look like pickup/inventory plumbing (e.g. HotbarPickupComponent)
local comp_props_checked = {}
local function hook_pickup_components(actor, cls, cname)
    if comp_props_checked[cname] then return end
    comp_props_checked[cname] = true
    local props = {}
    pcall(function() cls:ForEachProperty(function(p)
        local n = p:GetFName():ToString()
        local t = p:GetClass():GetFName():ToString()
        local l = n:lower()
        if t == "ObjectProperty" and (l:find("pickup", 1, true) or l:find("hotbar", 1, true) or l:find("inventory", 1, true)) then
            props[#props + 1] = n
        end
    end) end)
    for _, n in ipairs(props) do
        local comp = try(function() return actor[n] end)
        if valid(comp) then
            local ccls = try(function() return comp:GetClass() end)
            if valid(ccls) then hook_class(ccls, true) end
        end
    end
end

local function scan_classes()
    local actors = FindAllOf("Actor") or {}
    local before = hook_count
    for _, a in ipairs(actors) do
        if valid(a) then
            local cls = try(function() return a:GetClass() end)
            if valid(cls) then
                hook_class(cls)
                local cname = fullpath(cls)
                if cname and cname:find("^/Game/") then hook_pickup_components(a, cls, cname) end
            end
        end
    end
    -- the player's own components (inventory might live in one)
    local p = pawn()
    if p then
        pcall(function()
            local comps = p:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
            for i = 1, #comps do
                local c = comps[i]:get()
                if valid(c) then hook_class(c:GetClass(), false) end
            end
        end)
    end
    if hook_count ~= before then
        local n = 0 for _ in pairs(hooked_classes) do n = n + 1 end
        log("hooked %d functions (%d failed) across %d classes", hook_count, hook_fail, n)
    end
end

-- Pickup detection WITHOUT native hooks (a native hook on Actor:K2_DestroyActor crashes UE4SS 3.0.1).
-- When "On Interact" fires on a level-placed actor we watch it; if it disappears while its level is
-- still loaded it was picked up.
local Watch = {}   -- path -> expiry time
local function level_of(path) return path:match("^([^:]+):PersistentLevel") end
watch_actor = function(path) Watch[path] = P.game_time() + 8 end
local function check_watch()
    local now = P.game_time()
    for path, expiry in pairs(Watch) do
        if not find_actor(path) then
            Watch[path] = nil
            local lvl = level_of(path)
            local lvl_loaded = lvl and valid(try(StaticFindObject, lvl .. ":PersistentLevel"))
            trace("GONE %s (level loaded=%s)", path, tostring(lvl_loaded))
            if lvl_loaded and SYNC_DESTROY and Coop.active() then share({ kind = "destroy", path = path }) end
        elseif now > expiry then
            Watch[path] = nil
        end
    end
end

--------------------------------------------------------------- hands
local hands_last = { R = nil, L = nil }
Coop.on("hand", function(from, which)
    local p = pawn()
    if not SYNC_HANDS or not p then return end
    local prop = which == "R" and "hasRightHand?" or "hasLeftHand?"
    if try(function() return p[prop] end) then return end
    local fn = which == "R" and "Activate Right Hand" or "Activate Left Hand"
    replaying = replaying + 1
    local ok, err = pcall(function() p[fn](p) end)
    replaying = replaying - 1
    log("got %s hand from player %d (%s)", which, from, ok and "ok" or tostring(err))
end)
local function check_hands()
    local p = pawn()
    if not p then return end
    for _, w in ipairs({ "R", "L" }) do
        local has = try(function() return p[w == "R" and "hasRightHand?" or "hasLeftHand?"] end) and true or false
        if hands_last[w] == false and has and Coop.active() then Coop.send_event("hand", w); log("we got %s hand, sharing", w) end
        hands_last[w] = has
    end
end

--------------------------------------------------------------- Chapter 2: right-hand types (green hand ...)
-- Chapter 2 keeps the right hand in "CurrentRight Extendo Hand" (0 = red, 1 = green). Nothing about it is
-- saved: on every (re)load the value starts at 1 and the game fixes it ~2 s later with "Set RightHand" for
-- checkpoints before the green hand. So the value is only trusted once the load has SETTLED.
-- Room rule: once anyone has the green hand, everyone gets it (also after their own reloads, once per load).
local RH_PROP = "CurrentRight Extendo Hand"
local RH_SETTLE = 6.0                 -- seconds after a load before the value counts
local RH = { room = 0, load_at = -100, game_set = false, applied = false, last_share = -100 }
local function rh_now() return P.game_time and P.game_time() or os.clock() end
local function rh_settled()
    local dt = rh_now() - RH.load_at
    return (RH.game_set and dt > 1.0) or dt > RH_SETTLE
end
local function rh_cur()
    local p = pawn()
    local v = p and try(function() return p[RH_PROP] end)
    return type(v) == "number" and v or nil
end
local function rhand_apply(n)
    local p = pawn()
    if not p then return false end
    replaying = replaying + 1
    local ok1 = pcall(function() p[RH_PROP] = n end)
    local ok2, err = pcall(function() p["Set RightHand"](p, n, true) end)
    if rh_cur() ~= n then pcall(function() p[RH_PROP] = n end) end
    replaying = replaying - 1
    log("right hand -> %d (prop %s, Set RightHand %s) now %s", n, tostring(ok1), ok2 and "ok" or tostring(err), tostring(rh_cur()))
    return rh_cur() == n
end
local function rh_new_load() RH.load_at, RH.game_set, RH.applied = rh_now(), false, false end
table.insert(P.Handlers.unload, rh_new_load)
table.insert(P.Handlers.restart, rh_new_load)
-- the game's own Set RightHand after a load = value is final (simple params only: safe to hook)
local rh_hooked = false
table.insert(P.Handlers.restart, function()
    if rh_hooked or P.CHAPTER ~= 2 then return end
    rh_hooked = true
    pcall(RegisterHook, "/Game/Player/PlayerBP.PlayerBP_C:Set RightHand", function()
        if replaying == 0 then RH.game_set = true end
    end)
end)
Coop.on("rhand", function(from, rest)
    local n = tonumber(rest)
    if not SYNC_HANDS or P.CHAPTER ~= 2 or not n or n <= RH.room then return end
    RH.room, RH.applied = n, false
    log("player %d has right hand type %d", from, n)
end)
local function check_rhand()
    if P.CHAPTER ~= 2 or not SYNC_HANDS or not rh_settled() then return end
    local cur = rh_cur()
    if not cur then return end
    if cur > RH.room then
        RH.room = cur
        if Coop.active() then Coop.send_event("rhand", tostring(cur)); log("we have right hand type %d, sharing", cur) end
    elseif RH.room > cur and not RH.applied then
        RH.applied = true                       -- once per load: switching back by hand stays possible
        rhand_apply(RH.room)
    end
end
table.insert(P.Handlers.join, function(id)
    if P.CHAPTER == 2 and RH.room > 0 then Coop.send_to(id, "rhand", tostring(RH.room)) end
end)

--------------------------------------------------------------- levels
--[[ The game streams areas through native LevelStreamDirector, which pre-creates a fixed set of
     LevelStreamingDynamic_N slots. A slot only reveals which map it holds once loaded, but slot paths
     are identical on every machine, so they are the shared identity (keyed by outer+name: two
     different slots can both be called LevelStreamingDynamic_1).

     Each side reports the slots ITS OWN GAME wants loaded (changes we didn't make), and everyone keeps
     the union loaded. Slots loaded only for someone else are released once nobody needs them, except
     the map the local player is standing on. ]]
local Slots = {}          -- slot id -> { obj, pkg, last_load, want, vis, was_loaded }
local Ours = {}
local remote_levels = {}  -- [player id] = { [slot] = pkg }
local my_levels_str = nil
local LevelReplayAt = {}

claim_levels = function(names, wanted)
    for _, nm in ipairs(names) do
        local short = nm:match("([%w_]+)$")
        for n, s in pairs(Slots) do
            if short and s.pkg == short and s.want ~= wanted then
                s.want = wanted
                if wanted then Ours[n] = nil end
                trace("CLAIM %s (%s) wanted=%s by local game", n, short, tostring(wanted))
            end
        end
    end
end

local function slot_id(ls)
    local outer, name = (fullpath(ls) or ""):match("([%w_]+):([%w_]+)$")
    if outer then return outer .. ":" .. name end
end
local function slot_pkg(ls)
    local l = try(function() return ls:GetLoadedLevel() end)
    if valid(l) then return (fullpath(l) or ""):match("/([%w_]+)%.[%w_]+:PersistentLevel") end
end

local function floor_pkg()
    local p = pawn()
    if not p then return nil end
    -- read the BasedMovement struct property (calling GetMovementBase() raised engine errors)
    local bm = try(function() return p.BasedMovement end)
    local base = bm and try(function() return bm.MovementBase end)
    if not valid(base) then return nil end
    local owner = try(function() return base:GetOwner() end)
    local path = fullpath(valid(owner) and owner or base) or ""
    return path:match("/([%w_]+)%.[%w_]+:PersistentLevel")
end

local function scan_slots()
    local seen = {}
    local now = P.game_time()
    for _, ls in ipairs(FindAllOf("LevelStreaming") or {}) do
        local n = valid(ls) and slot_id(ls)
        if n and not seen[n] then
            seen[n] = true
            local load = try(function() return ls:ShouldBeLoaded() end) and true or false
            local loaded = try(function() return ls:IsLevelLoaded() end) and true or false
            local s = Slots[n]
            if not s then
                s = { want = load }
                Slots[n] = s
            elseif load ~= s.last_load then
                s.want = load                -- changed, and not by us: the game decided
                if not load then Ours[n] = nil end
                trace("SLOT %s (%s) game set load=%s", n, tostring(s.pkg), tostring(load))
            end
            s.obj, s.last_load = ls, load
            s.vis = try(function() return ls:IsLevelVisible() end) and true or false
            s.vis_want = try(function() return ls.bShouldBeVisible end) ~= false   -- the game may hide a loaded area
            local pkg = slot_pkg(ls)
            if pkg then s.pkg = pkg end
            if loaded and not s.was_loaded and s.pkg then LevelReplayAt[s.pkg] = now + 1.0 end
            s.was_loaded = loaded
        end
    end
    for n in pairs(Slots) do if not seen[n] then Slots[n] = nil; Ours[n] = nil end end
    for pkg, at in pairs(LevelReplayAt) do
        if now >= at then LevelReplayAt[pkg] = nil; replay_level(pkg) end
    end
end

local function report_levels(force)
    local mine = {}
    -- only areas our game wants SHOWN (a loaded-but-hidden area isn't needed; one we only show for a
    -- friend must not be reported back, or both games would keep it forever)
    for n, s in pairs(Slots) do
        if s.want and s.vis_want and not s.vis_forced then mine[#mine + 1] = n .. "=" .. (s.pkg or "?") end
    end
    table.sort(mine)
    local str = #mine > 0 and table.concat(mine, ",") or "-"
    if (force or str ~= my_levels_str) and Coop.active() then
        my_levels_str = str
        Coop.send_event("lv", str)
        trace("LEVELS mine: %s", str)
    end
end

Coop.on("lv", function(from, list)
    local set = {}
    for slot, pkg in list:gmatch("([%w_]+:[%w_]+)=([%w_%?]+)") do set[slot] = pkg end
    remote_levels[from] = set
    trace("LEVELS from %d: %s", from, list)
end)
table.insert(P.Handlers.leave, function(id) remote_levels[id] = nil end)
table.insert(P.Handlers.join, function() my_levels_str = nil end)

local function resolve_slot(slot, pkg)
    local s = Slots[slot]
    if s and (pkg == "?" or not s.pkg or s.pkg == pkg) then return slot end
    for n, t in pairs(Slots) do if t.pkg == pkg then return n end end
    if s then trace("slot %s holds %s here but %s remotely; skipping", slot, tostring(s.pkg), pkg) end
    return nil
end

local function set_slot(n, on)
    local s = Slots[n]
    if not valid(s.obj) then return end
    pcall(function() s.obj:SetShouldBeLoaded(on) end)
    pcall(function() s.obj:SetShouldBeVisible(on) end)
    s.last_load = on
end

local function sync_levels()
    scan_slots()
    report_levels(false)
    if not SYNC_LEVELS then return end
    local need = {}
    for _, set in pairs(remote_levels) do
        for slot, pkg in pairs(set) do
            local n = resolve_slot(slot, pkg)
            if n then need[n] = pkg end
        end
    end
    local standing = nil
    for n, s in pairs(Slots) do
        if need[n] and not s.last_load then
            set_slot(n, true); Ours[n] = true
            log("loading %s (%s) for the other player", n, need[n])
        elseif need[n] and Ours[n] and s.last_load and not s.vis and valid(s.obj) then
            pcall(function() s.obj:SetShouldBeVisible(true) end)
        elseif need[n] and not Ours[n] and s.last_load and not s.vis_want and valid(s.obj) then
            -- our game hid this area (walked past a visibility trigger) but a friend is in it: an
            -- invisible area has no floor, so teleporting there (F6) dropped players out of the map
            pcall(function() s.obj:SetShouldBeVisible(true) end)
            s.vis_forced = true
            log("showing %s (%s) again for the other player", n, need[n])
        elseif not need[n] and not Ours[n] and s.vis_forced and s.last_load and valid(s.obj) then
            local now = P.game_time()
            s.unshown_since = s.unshown_since or now
            if now - s.unshown_since >= 10 then
                if standing == nil then standing = floor_pkg() or false end
                if standing ~= false and s.pkg == standing then
                    s.vis_forced, s.unshown_since = nil, nil          -- we walked in: it's ours now
                elseif standing ~= false then
                    pcall(function() s.obj:SetShouldBeVisible(false) end)
                    s.vis_forced, s.unshown_since = nil, nil
                    log("hiding %s (%s) again: nobody needs it", n, tostring(s.pkg))
                end
            end
        elseif not need[n] and Ours[n] and not s.want and s.last_load then
            local now = P.game_time()
            s.unneeded_since = s.unneeded_since or now
            if now - s.unneeded_since >= 10 then
                if standing == nil then standing = floor_pkg() or false end
                if standing == false then
                    -- can't tell where we're standing: never unload (that dropped maps under players)
                elseif s.pkg and s.pkg == standing then
                    s.want = true; Ours[n] = nil
                    log("keeping %s (%s): you're standing in it", n, s.pkg)
                else
                    set_slot(n, false); Ours[n] = nil
                    log("releasing %s (%s): nobody needs it", n, tostring(s.pkg))
                end
            end
        end
        if need[n] or not Ours[n] then s.unneeded_since = nil end
        if need[n] then s.unshown_since = nil end
    end
end

-- Teleport (F6) preparation: load and show every area the friend's game has shown, so the teleport
-- lands on a floor. Returns ready, number of areas still loading. Called each tick until ready.
P.level_prep = function(id)
    scan_slots()
    local set = remote_levels[id]
    if not set then return true, 0 end
    local pending, waiting = 0, {}
    for slot, pkg in pairs(set) do
        local n = resolve_slot(slot, pkg)
        local s = n and Slots[n]
        if s and valid(s.obj) then
            if not s.last_load then
                set_slot(n, true); Ours[n] = true
                log("loading %s (%s) for the teleport", n, pkg)
            elseif not s.vis_want and not Ours[n] then
                pcall(function() s.obj:SetShouldBeVisible(true) end)
                s.vis_forced = true
            end
            -- only wait for the main areas: sub-areas inside a streamed area (RevokedToys_CHP2:LevelStreaming...)
            -- may never appear here (parent not shown, or the other game's copy differs)
            local top = n:match("^([%w_]+):") == Game.map
            if not s.vis and top then pending = pending + 1; waiting[#waiting + 1] = n .. "(" .. tostring(s.pkg or pkg) .. ")" end
        end
    end
    return pending == 0, pending, table.concat(waiting, " ")
end

------------------------------------------------------------ diagnostics
local function diagnostics(full)
    local f = io.open(P.MOD_DIR .. "\\diag_" .. tostring(Config.mode) .. ".txt", "w")
    if not f then return end
    local function w(s) f:write(s, "\n") end
    w("PoppyCoop diagnostics " .. os.date())
    w("map=" .. tostring(Game.map) .. "  floor=" .. tostring(floor_pkg()))
    w("== slots ==")
    local ids = {}
    for n in pairs(Slots) do ids[#ids + 1] = n end
    table.sort(ids)
    for _, n in ipairs(ids) do
        local sl = Slots[n]
        w(("  %-40s pkg=%-16s want=%-5s load=%-5s vis=%-5s ours=%s"):format(n, tostring(sl.pkg), tostring(sl.want), tostring(sl.last_load), tostring(sl.vis), tostring(Ours[n])))
    end
    w("== hooks ==")
    w(("hooked=%d failed=%d ctx_ok=%d ctx_fail=%d ledger=%d"):format(hook_count, hook_fail, ctx_ok, ctx_fail, #Ledger))
    w("== hooked inventory / pickup functions ==")
    local names = {}
    for k in pairs(HookedFns) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do w("  " .. k) end
    if full then
        w("== player inventory arrays ==")
        local p = pawn()
        for _, prop in ipairs({ "Inventory Items", "Stored Inventory" }) do
            local items = {}
            if p then
                pcall(function()
                    p[prop]:ForEach(function(i, elem)
                        local v = elem:get()
                        local s = tostring(v)
                        if type(v) == "userdata" then
                            s = try(function() return fullpath(v) end) or s
                        end
                        items[#items + 1] = s
                    end)
                end)
            end
            w("  " .. prop .. " = [" .. table.concat(items, ", ") .. "]")
        end
        w("== ledger ==")
        for i, e in ipairs(Ledger) do
            w(("  %3d %s %s %s(%s)%s"):format(i, e.kind, e.path, e.fn or "", e.args or "", e.remote and " [remote]" or ""))
        end
    end
    f:close()
    log("wrote diagnostics")
end

------------------------------------------------------------------ driver
local t_levels, t_scan, t_hands = 0, 0, 0
local last_level_objs = -1

-- level about to reload: drop every cached engine object (slot objects); paths/ledger are kept
table.insert(P.Handlers.unload, function()
    for k in pairs(Slots) do Slots[k] = nil end
    for k in pairs(Ours) do Ours[k] = nil end
    for k in pairs(Watch) do Watch[k] = nil end
    for k in pairs(ChildCache) do ChildCache[k] = nil end   -- crash fix: CH2 door child actors die with the level
    last_level_objs = -1
    my_levels_str = nil
end)
local diag_done = false

table.insert(P.Handlers.restart, function() scan_classes() end)

table.insert(P.Handlers.tick, function(dt, have)
    local crumb = P.crumb or function() end
    if not have or not pawn() then return end
    local now = P.game_time()
    if now - t_scan > 2 then
        t_scan = now
        crumb("world: count levels")
        local lv = #(FindAllOf("Level") or {})
        if lv ~= last_level_objs then
            last_level_objs = lv
            crumb("world: scan_classes"); scan_classes()
            crumb("world: retry_pending"); retry_pending()
            crumb("world: report_levels"); report_levels(true)
        end
    end
    if now - t_levels > 1 then t_levels = now; crumb("world: sync_levels"); sync_levels(); crumb("world: cp_fix"); pcall(cp_fix_tick) end
    if now - t_hands > 0.5 then t_hands = now; crumb("world: check_hands"); check_hands(); crumb("world: check_rhand"); pcall(check_rhand); crumb("world: check_watch"); check_watch() end
    if not diag_done and now > 20 then diag_done = true; crumb("world: diagnostics"); diagnostics(false) end
    crumb("world: done")
end)

RegisterConsoleCommandHandler("coop_diag", function(_, _, out)
    diagnostics(true)
    pcall(function() out:Log("diagnostics written") end)
    return true
end)
RegisterConsoleCommandHandler("coop_ledger", function(_, _, out)
    local n = 0 for _ in pairs(Pending) do n = n + 1 end
    local s = ("ledger=%d pending=%d hooks=%d ctx_ok=%d ctx_fail=%d"):format(#Ledger, n, hook_count, ctx_ok, ctx_fail)
    log("%s", s); pcall(function() out:Log(s) end)
    return true
end)

if valid(FindFirstOf("PlayerBP_C")) then pcall(scan_classes) end
log("world sync v0.4 loaded (activations=%s pickups=%s inventory=%s levels=%s hands=%s)",
    tostring(SYNC_ACT), tostring(SYNC_DESTROY), tostring(SYNC_INV), tostring(SYNC_LEVELS), tostring(SYNC_HANDS))
