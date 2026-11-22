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
-- Chapter 1 roll-up doors (EventRaiseLowerDoors_C: behind hand scanners, two-hand pads, power room). They are
-- opened by many different pads/levers whose own "force" functions don't move the door in the other games,
-- so the door's own DoorOpen is shared as "Force Door Open" (REMAP) and applied with a guard (apply)
P.RaiseDoor = { state = {}, remote = {}, at = 0, CLASS = "EventRaiseLowerDoors_C", FN = "Force Door Open" }
-- Chapter 1 hand scanners (LeftHandAccessPad_C): putting the hand on / taking it off is shared live, so the
-- other games run the same scan (charge bar, sound) and open the same doors. What a replayed scan does
-- afterwards (Activate Blueprints, the doors' DoorOpen) is not sent back for ECHO s.
P.Pad = { CLASS = "LeftHandAccessPad_C", LIVE = { ["Activate With Hand"] = true, ["Deactivate With Hand"] = true },
    remote_at = -100, ECHO = 8, done = {} }     -- done: path -> completed (the game repeats Activate Blueprints every second)
-- "New Game" pressed in the main menu: for FRESH_SECS this game starts from the beginning, even if a friend
-- is further. The friend's catch-up batch on joining (their open doors, hands, items: "lbeg" .. "lend") and
-- their checkpoint are dropped then; what they do live from now on still comes through.
P.Fresh = { untilT = -1, SECS = 120, batch = {}, hooked = false,
    FN = ":BndEvt__UI_MainMenu_NewGameButton_K2Node_ComponentBoundEvent_1_OnPressed__DelegateSignature" }
P.fresh = function() return os.clock() < P.Fresh.untilT end
P.old_progress = function(from) return P.Fresh.batch[from] and P.fresh() end   -- drop this catch-up event?
P.NewGameReset = {}      -- functions run on New Game (other modules forget what they remembered)
P.LevelsChanged = {}     -- functions run when a streamed area loaded / unloaded (other modules drop cached parts)
-- Quiet time: while the game tears levels down (dying -> reload, teleport, a streamed area being unloaded)
-- the hooked Blueprint functions still fire on half-destroyed actors. Reading their params / calling functions
-- on them from the hook (GetParentActor...) crashed the game inside UE4SS (crash reports 1.6.3: CH2 after a
-- death, a teleport, a level release). Then the hooks do nothing and friends' events wait (Pending).
P.Quiet = { untilT = -1, load = false, MAX_DEATH = 60, AFTER_LOAD = 3, RELEASE = 4 }
P.hush = function(secs) P.Quiet.untilT = math.max(P.Quiet.untilT, os.clock() + secs) end
P.quiet = function() return P.Quiet.load or os.clock() < P.Quiet.untilT end
-- level lists of every streaming volume, by address, read while nothing is loading (see "Load Levels" hook)
P.VolLists = {}
P.VolNeedScan = true
-- a level slot's object, looked up fresh by its path (never a kept object: see scan_slots)
P.sobj = function(sl)
    if not sl or not sl.path then return nil end
    local o = P.try(StaticFindObject, sl.path)
    if o and P.valid(o) then return o end
    return nil
end
P.LATE_CLASSES = { LeftHandAccessPad_C = true, SecurityPadInteractionBP_C = true, PowerConnector_Master_C = true, EventRaiseLowerDoors_C = true, ExtendoTwoHandActivation_C = true }
local SYNC_DESTROY = Config.sync_destroy ~= false
local SYNC_LEVELS = Config.sync_levels ~= false
local SYNC_HANDS = Config.sync_hands ~= false
local SYNC_INV = Config.sync_inventory ~= false
local SHARE_CP1 = Config.share_checkpoints ~= false   -- Chapter 1: friends' checkpoints are saved here too
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
            if P.quiet() or not obj:IsValid() then return nil end
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

local watch_actor, level_count, protect_levels   -- forward declarations
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
    if path and path:find("VHSPlayerBP", 1, true) then return end    -- a played tape is a moment, not a state
    -- furnace doors close again by themselves (Mommy chase): opening them again after a reload / death let
    -- Mommy run through, so a friend's furnace door is only shared live, never re-applied
    if path and path:find("FurnaceDoor", 1, true) then return end
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
    -- (an area reload can put the new parent at the old address: the cached child is only trusted within the
    -- same level generation, see P.LevelsChanged)
    if c and c.paddr == paddr and c.lgen == (P.LevelGen or 0) then return c.a end
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
    ChildCache[path] = found and { a = found, paddr = paddr, lgen = P.LevelGen or 0 } or nil
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
    if cname:find("/DoubleDoors%.") then return call_any(a, "Force Open Door") and 1 or 0 end    -- Chapter 1
    if cname:find("/SingleDoors_BP%.") then return call_any(a, "Force Door Open") and 1 or 0 end
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
local CP_FNS_ALL = { ["Trigger Checkpoint"] = true, ["Save New Checkpoint"] = true, ["Load Checkpoint"] = true }
local lsa_fn          -- level-script events that are shared (defined with the hooks)
-- Checkpoints with 3+ players: only ever move forward. A remote "Save New Checkpoint" behind the
-- furthest one this game has seen (its own or anyone's) is ignored, so a player who is behind can't
-- reset everyone else's "Load Game" position.
local CP_MAX = -1
-- the furthest checkpoint THIS game's world has really been through (reached by our own player, or
-- spawned at after a load). Other players' checkpoints are saved here too (CP_MAX), but the world (chases,
-- minigames, scripted sequences) is only "there" once this game itself got that far. Sent in the state line
-- (C=n) so a teleport (F6) to a player who is further can respawn at their checkpoint first.
local LOCAL_CP = -1
local RemoteCPUntil = -1    -- a remote checkpoint trigger was replayed: saves until then are not our own
local LOCAL_CP_SEEN = false  -- the first save after starting is the load itself: no split popup
local CP_FIX = nil       -- set when a replayed trigger saved an older checkpoint: re-save the furthest
local function cp_fix_tick()
    if not CP_FIX then return end
    local n = CP_FIX
    CP_FIX = nil
    local gm = try(FindFirstOf, P.CHAPTER == 1 and "Chapter1_Gamemode_C" or "Chapter2_Gamemode_C")
    if not valid(gm) then return end
    replaying = replaying + 1
    local ok = pcall(function() gm["Save New Checkpoint"](gm, n) end)
    replaying = replaying - 1
    trace("checkpoint restored to %d (%s)", n, tostring(ok))
end
local function cp_number(args) return tonumber(tostring(args or ""):match("^n:(%-?%d+)")) end
-- Chapter 1 (worked like this in 1.1): the furthest checkpoint anyone reached is saved in every game, so
-- "Load Game" (and a respawn) puts everyone there. Saving a checkpoint in Chapter 1 only writes the save
-- slot (no level streaming), so it is safe to do while the player is somewhere else. Forward only.
local CP1_PENDING = nil
local function cp1_apply(n, from)
    if P.CHAPTER ~= 1 or not SHARE_CP1 or not n then return end
    if P.fresh() then return end                         -- just pressed New Game: start from the beginning
    if n < CP_MAX and from and Coop.active() then
        Coop.send_to(from, "cp1", tostring(CP_MAX))      -- they are behind: tell them ours right away
        return
    end
    if n <= CP_MAX then return end
    CP_MAX = n
    CP1_PENDING = n
end
local CP1 = { RESEND = 5, sent_at = -100, was_active = false }   -- (this file is at Lua's 200-locals limit: use tables)
local function cp1_tick()
    -- a new checkpoint is sent the moment it is saved; on top of that our furthest one goes out right when the
    -- connection comes up (a save made while loading, before it was up, was lost) and again every 5 s
    local active = Coop.active()
    if active and not CP1.was_active then CP1.sent_at = -100 end
    CP1.was_active = active
    if P.CHAPTER == 1 and SHARE_CP1 and CP_MAX >= 0 and active and P.game_time() - CP1.sent_at > CP1.RESEND then
        CP1.sent_at = P.game_time()
        Coop.send_event("cp1", tostring(CP_MAX))
    end
    if not CP1_PENDING then return end
    local gm = try(FindFirstOf, "Chapter1_Gamemode_C")
    if not valid(gm) then return end                 -- loading: try again next tick
    local n = CP1_PENDING
    CP1_PENDING = nil
    replaying = replaying + 1
    local ok = pcall(function() gm["Save New Checkpoint"](gm, n) end)
    replaying = replaying - 1
    log("friend's checkpoint %d saved here (Load Game starts there) %s", n, ok and "" or "FAILED")
end
Coop.on("cp1", function(from, rest) cp1_apply(tonumber(rest), from) end)
table.insert(P.Handlers.join, function(id)
    if P.CHAPTER == 1 and SHARE_CP1 and CP_MAX >= 0 then Coop.send_to(id, "cp1", tostring(CP_MAX)) end
end)
-- Game controllers of deadly minigames/chases: replaying their start (ElectricalInterface) in a game whose
-- player is elsewhere ran the game against THAT player - e.g. a friend started Statues and the PJ game killed a
-- player in the hub. Such events wait (pending) until our player is near the controller.
local GATED = { "ToggleGameController", "Whack-A-Mole_Controller", "GameshowController", "Mommy_Chase", "StatuesCaterpillar" }
local GATE_DIST = 4000   -- cm
local function near_enough(path, a)
    local name = path:match("PersistentLevel%.(.+)$") or ""
    local gated = false
    for _, g in ipairs(GATED) do if name:find(g, 1, true) then gated = true; break end end
    if not gated then return true end
    local p = pawn()
    local me = p and try(function() return p:K2_GetActorLocation() end)
    local at = try(function() return a:K2_GetActorLocation() end)
    if not (me and at) then return false end
    local dx, dy, dz = me.X - at.X, me.Y - at.Y, me.Z - at.Z
    return dx * dx + dy * dy + dz * dz < GATE_DIST * GATE_DIST
end

local VHS_DIST = 1500     -- cm: a friend's tape only plays for you when you stand at the recorder too
local function apply(e)
    if e.kind == "act" and (e.fn == "Trigger Checkpoint" or e.fn == "Save New Checkpoint") then RemoteCPUntil = P.game_time() + 3 end
    if e.kind == "act" and e.fn == "On Interact" and e.path and e.path:find("VHSPlayerBP", 1, true) then
        local a = find_actor(e.path)
        local p = pawn()
        local me = p and try(function() return p:K2_GetActorLocation() end)
        local at = a and try(function() return a:K2_GetActorLocation() end)
        if not (me and at) or (me.X - at.X) ^ 2 + (me.Y - at.Y) ^ 2 + (me.Z - at.Z) ^ 2 > VHS_DIST * VHS_DIST then
            trace("VHS tape not played here (too far)")
            return true
        end
    end
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
    elseif e.kind == "act" and e.fn == P.RaiseDoor.FN and e.path and e.path:find((P.RaiseDoor.CLASS:gsub("_C$", "")), 1, true) then
        local a = find_actor(e.path)
        if not a then return false end
        if try(function() return a["IsClosed"] end) == false then return true end   -- open here already
        P.RaiseDoor.remote[e.path] = true                       -- (its own DoorOpen must not be sent back)
        local path = e.path
        local function open_it()
            local a2 = find_actor(path)
            if not a2 or try(function() return a2["IsClosed"] end) == false then return end
            local r = call_with(a2, P.RaiseDoor.FN, "")
            log("roll-up door opened by a friend: %s (%s)", path:match("([^.]+)$") or path, tostring(r))
        end
        if P.late then P.late(open_it, "roll-up door") else open_it() end   -- timeline start: not inside a tick
        return true
    elseif e.kind == "act" then
        local a = find_actor(e.path)
        if not a then return false end
        if not near_enough(e.path, a) then return false end   -- stays pending until we come close
        local acls = P.CHAPTER == 1 and tostring(try(function() return a:GetClass():GetFullName() end) or ""):match("([^%.]+)$")
        if acls and P.LATE_CLASSES[acls] and P.late then
            -- Chapter 1 scanners / doors start timelines and sounds: run them at the late point (not inside an
            -- actor tick, where that crashed / deadlocked the game)
            -- only a friend's scan counts for the echo time (not their power / door events on the scanner)
            if acls == P.Pad.CLASS and (e.fn == "Activate With Hand" or e.fn == "Force Complete") then
                P.Pad.remote_at = P.game_time()
                P.Pad.done[e.path] = true          -- its completion here is the friend's: not sent back
            end
            if acls == P.Pad.CLASS and e.fn == "Deactivate With Hand" then P.Pad.done[e.path] = nil end   -- (scan broken off)
            local path, fn, args = e.path, e.fn, e.args
            P.late(function()
                local a2 = find_actor(path)
                if a2 and acls == "PowerConnector_Master_C" and try(function() return a2["Is Puzzle Complete?"] end) == true then
                    return                                   -- powered here already: don't run the chain twice
                end
                if a2 and fn == "Short Circuit Event" then
                    -- a short only before the power puzzle is solved here (never knock out restored power)
                    local m = try(FindFirstOf, "PowerConnector_Master_C")
                    if (m and try(function() return m["Is Puzzle Complete?"] end) == true)
                        or try(function() return a2["canShortOut?"] end) == false then return end
                end
                if a2 then
                    if acls == P.Pad.CLASS and (fn == "Activate With Hand" or fn == "Force Complete") then
                        P.Pad.remote_at = P.game_time()
                        -- the friend's scanner had power (their cable / breaker): ours may not yet - a scan or
                        -- Force Complete on an unpowered scanner does nothing, so switch it on first
                        if (fn == "Activate With Hand" or fn == "Force Complete") and try(function() return a2["IsPowered?"] end) == false then
                            call_with(a2, "PowerUp", "")
                            log("friend's hand scanner had power: powered %s here", path:match("([^.]+)$") or path)
                        end
                    end
                    local r = call_with(a2, fn, args)
                    log("friend's %s: %s on %s (%s)", acls == P.Pad.CLASS and "hand scanner" or "door", fn, path:match("([^.]+)$") or path, r)
                end
            end, "scanner/door")
            return true
        end
        if P.CHAPTER == 1 and lsa_fn(e.fn) and P.late then
            -- Chapter 1: a level-script event can start animations/sequences; animation calls from inside an
            -- actor tick deadlock the game there (see ARCHITECTURE "Late queue") -> run it at the late point
            local path, fn, args = e.path, e.fn, e.args
            P.late(function()
                local a2 = find_actor(path)
                if a2 then call_with(a2, fn, args) end
            end, "level event")
            return true
        end
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

-- A friend reached a new checkpoint while we are still inside a chase / escape (Statues, Mommy's chase):
-- the chase would go on here and catch us even after teleporting to them. Bring us to their checkpoint
-- (respawn there + teleport, like F6) after a short notice.
local AutoFollow = nil      -- { id, at }
local AUTO_FOLLOW_DELAY = 3
local AUTO_FOLLOW_DIST = 2000   -- cm: only when we are not next to them anyway
-- The checkpoints a chase starts from: if our own world is at one of them, we are (still) in that chase.
-- (Whether a chase level is loaded says nothing: level sync also loads a friend's chase level here.)
-- 23 = Statues (PJ Pug-a-Pillar); 31-33 = Mommy's chase (level Mommy_Chase_Redone, its chain splines lie
-- between checkpoints 31 and 33). config.txt chase_cps=23,31,32,33 overrides.
local CHASE_CPS = { [23] = "Statues", [31] = "Mommy chase", [32] = "Mommy chase", [33] = "Mommy chase" }
if Config.chase_cps then
    CHASE_CPS = {}
    for n in tostring(Config.chase_cps):gmatch("%d+") do CHASE_CPS[tonumber(n)] = "chase" end
end
local function chase_loaded() return CHASE_CPS[LOCAL_CP] or false end
-- driven by the checkpoint every player sends in its state line (C=n): it went up while we are behind,
-- inside a loaded chase and far from them
local FollowSeen = {}       -- player id -> last checkpoint seen in their state
local function check_auto_follow()
    if P.CHAPTER ~= 2 or Config.auto_follow == false or Config.auto_follow == "false" or AutoFollow then return end
    for id, pl in pairs(Net.players) do
        local st = tostring(pl.state or "")
        local c = tonumber(st:match(" C=(%-?%d+)"))
        local seen = FollowSeen[id]
        FollowSeen[id] = c or seen
        if c and seen and c > seen and c > LOCAL_CP then
            -- (checkpoint events are not shared any more - the state line tells us)
            if P.popup and not chase_loaded() then pcall(P.popup, ("reached checkpoint %d"):format(c), "cp", pl.name or "A player") end
            local chase = chase_loaded()
            local p = pawn()
            local me = p and try(function() return p:K2_GetActorLocation() end)
            local x, y, z = st:match("^(%S+) (%S+) (%S+)")
            local far = true
            if me and x then
                local dx, dy, dz = me.X - tonumber(x), me.Y - tonumber(y), me.Z - tonumber(z)
                far = dx * dx + dy * dy + dz * dz > AUTO_FOLLOW_DIST * AUTO_FOLLOW_DIST
            end
            if chase and far then
                AutoFollow = { id = id, at = P.game_time() + AUTO_FOLLOW_DELAY }
                log("follow: %s reached checkpoint %d while we are in %s (ours %d)", pl.name or tostring(id), c, chase, LOCAL_CP)
                if P.popup then pcall(P.popup, ("%s made it! Bringing you there..."):format(pl.name or "Your friend")) end
                return
            end
        end
    end
end
local function auto_follow_tick()
    if not AutoFollow or P.game_time() < AutoFollow.at then return end
    local id = AutoFollow.id
    AutoFollow = nil
    if _G.PoppyCoop_follow then _G.PoppyCoop_follow(id) end
end

local function receive(e, from)
    -- Chapter 1's GrabPack box (GrabPackDoor): never synced. Leaving a game for the main menu fires "open" on it
    -- while the level is torn down, and that reached a friend who had just started a New Game (the box stood
    -- open). It isn't needed either: the blue hand itself is given to every player.
    if e.path and e.path:find("GrabPackDoor", 1, true) then return end
    trace("RECV from %s: %s %s %s", tostring(from), tostring(e.kind), tostring(e.path), tostring(e.fn))
    if P.Fresh.batch[from] and P.fresh() then
        trace("DROP old progress from %s (new game): %s %s %s", tostring(from), tostring(e.kind), tostring(e.path), tostring(e.fn))
        return
    end
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
    if e.kind == "act" then
        if lsa_fn(e.fn) then log("level event %s from player %s", tostring(e.fn):sub(1, 60), tostring(from)) end
    end
    if P.quiet() or not apply(e) then
        Pending[key .. ((e.kind == "pfn" or e.kind == "cfn") and ("#" .. #Ledger) or "")] = e
        trace("PENDING %s (target not loaded)", key)
    end
end

local function retry_pending()
    if P.ReplayHold and P.game_time() < P.ReplayHold then return end
    if P.quiet() then return end
    for key, e in pairs(Pending) do
        if apply(e) then Pending[key] = nil end
    end
end

-- A streamed level just (re)loaded: its actors are back in their initial state, so re-apply what
-- other players already did there (opened doors, picked-up items...).
local function replay_level(pkg)
    if not pkg then return end
    if P.ReplayHold and P.game_time() < P.ReplayHold then P.HeldReplays[pkg] = true; return end   -- see new_game_check
    local needle = "." .. pkg .. ":PersistentLevel."
    local n = 0
    for _, e in ipairs(Ledger) do
        -- (lever events bound in a level script are not re-run on reload: they start sequences)
        if e.remote and e.kind ~= "pfn" and e.kind ~= "cfn" and e.path:find(needle, 1, true)
            and not (e.fn and e.fn:find("^BndEvt__")) then
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
    Coop.send_to(id, "lbeg", "1")    -- catch-up batch starts (ends with "lend" at the end of this file; see P.Fresh)
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
    "Trigger Checkpoint", "Save New Checkpoint",     -- hooked to know our own checkpoint (LOCAL_CP); never shared
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
local CH1_DOOR_OPEN = { ["Event Open Door"] = true, UnlockAndOpenDoor = true, ["Open Left Door Event"] = true,
    ["Open Right Door Event"] = true, ["Force Open Door"] = true, ["Force Door Open"] = true }
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
    TrainGoLever_C = { Activated = "Activated" },                 -- Game Station train levers (1.4.8)
    -- Chapter 1
    SecurityPadInteractionBP_C = { OpenDoors = { "Force Correct Code", "b:1" } },   -- (takes one bool: true opens)
    LeftHandAccessPad_C = { ["Activate Blueprints"] = "Force Complete",
        ["Activate With Hand"] = "Activate With Hand", ["Deactivate With Hand"] = "Deactivate With Hand",
        -- power room scanner: the hand on it shorts the power out (then the power puzzle) - same short for everyone
        ["Short Circuit Event"] = "Short Circuit Event" },
    EventRaiseLowerDoors_C = { DoorOpen = "Force Door Open" },     -- roll-up doors (see P.RaiseDoor)
    -- power room: the solved power puzzle runs its whole chain (scanner power, lights, Huggy, doors, streaming)
    -- from this one event; sending its nested calls one by one didn't power anything for the others
    PowerConnector_Master_C = { ["On Powered_Event"] = "On Powered_Event" },
}
local function short_class(cname) return cname and cname:match("([^%.]+)$") end
local REMAP_TARGETS = {}
-- a target is a function name, or { name, encoded args } when the force function takes parameters
for _, m in pairs(REMAP) do for _, fn in pairs(m) do REMAP_TARGETS[type(fn) == "table" and fn[1] or fn] = true end end
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
    -- the VHS recorder: a friend playing a tape plays it for you too - only when you are next to it (see apply)
    if name:find("vhsplayer", 1, true) then return true end
    for _, p in ipairs(NO_REPLAY) do if name:find(p, 1, true) then return false end end
    for _, p in ipairs(REPLAY_PATTERNS) do if name:find(p, 1, true) then return true end end
    return false
end

-- Level scripts (level blueprints like HUB_C) react to levers and switches: the Game Station lights are
-- HUB_C:OnLightLeverPulled, the game doors BndEvt__HUB_BP_PullLever_*_OnActivation. Those events are shared
-- like any activation. Not shared: overlap triggers (each player walks through their own), load/restore
-- events (each game restores its own state), animation callbacks (they follow from a shared event).
local LSA_SKIP = { "^load", "begin", "finish", "fade", "update", "overlap", "checkpoint", "close", "construction",
    "tick", "^receive", "^generic", "player", "level", "sequence", "^set ", "%?" }
local LSA_WANT = { "lever", "pulled", "switch", "button", "power", "light", "activat", "turnon", "turn on", "breaker", "fuse", "unlock", "rubble" }
lsa_fn = function(fname)
    local l = tostring(fname or ""):lower()
    if l:find("^bndevt__") then
        return (l:find("onactivation", 1, true) or l:find("on activat", 1, true) or l:find("onpull", 1, true)) ~= nil
            and not l:find("overlap", 1, true)
    end
    if l:find("__", 1, true) then return false end
    for _, w in ipairs(LSA_SKIP) do if l:find(w) then return false end end
    for _, w in ipairs(LSA_WANT) do if l:find(w, 1, true) then return true end end
    return false
end
local LsaClass = {}          -- class full name -> true for level script classes
local function is_level_script(cls, cname)
    if LsaClass[cname] ~= nil then return LsaClass[cname] end
    local r, sc = false, cls
    for _ = 1, 6 do
        sc = try(function() return sc:GetSuperStruct() end)
        if not valid(sc) then break end
        local n = try(function() return sc:GetFName():ToString() end)
        if n == "LevelScriptActor" then r = true; break end
        if n == "Actor" then break end
    end
    LsaClass[cname] = r
    return r
end

-- Saving a checkpoint makes the game stream that checkpoint's level set (Gamemode "Save New Checkpoint" ->
-- "Load Levels"/"Update Level"): replayed in a game whose player is somewhere else it unloaded the floor under
-- them and they fell to their death (seen: a friend's Whack-a-Wuggy checkpoint killed a player in Musical
-- Memory). Checkpoint saves/triggers are therefore never shared; following a friend goes through F6/C=n.
local function is_checkpoint_event(path, fn)
    return CP_FNS_ALL[fn] or (path and (path:find("Checkpoint", 1, true) ~= nil)) or false
end

remote_allowed = function(e)
    local base = e.path and (e.path:match("^([^#]+)#") or e.path)
    if e.kind == "act" then
        if not is_level_placed(e.path) then return false end
        if is_checkpoint_event(e.path, e.fn) then return false end
        if ACT_SET[e.fn] or REMAP_TARGETS[e.fn] then return true end
        if e.fn == "CoopOpenDoor" then
            local a = find_actor(e.path)
            return a == nil or is_door_class(fullpath(try(function() return a:GetClass() end)) or "") ~= nil
        end
        if e.fn == "On Interact" then return replay_interact(e.path) end
        if lsa_fn(e.fn) then
            local a = find_actor(e.path)
            local cls = a and try(function() return a:GetClass() end)
            return valid(cls) and is_level_script(cls, fullpath(cls) or "") or false
        end
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

local function share_now(e)
    local key = ekey(e.kind, e.path, e.fn, e.args)
    ledger_add(e.kind, e.path, e.fn, e.args, false, e.kind == "pfn" or e.kind == "cfn")
    if e.kind ~= "pfn" and e.kind ~= "cfn" then
        if seen_recently(key) then
            if key:find("|On Interact|", 1, true) then mark(key) end   -- still the same held press
            trace("SEND skipped (sent recently): %s", key)
            return
        end
        mark(key)
    end
    trace("SEND %s", key)
    send(e)
end

-- A hooked Blueprint function that fires many times a second (per-frame logic) is never one we need to
-- share, and running Lua for it every frame costs FPS. Count calls; past 25 a second it is ignored.
-- UE4SS runs Blueprint hooks AFTER the function body, so the calls a lever event makes (lights'
-- ElectricalInterface, door functions...) are seen BEFORE the event itself. Activations are therefore
-- collected for one frame: if a level-script event is among them, only that event is sent (the other games
-- run it and get the same chain), otherwise all of them.
local FrameQ = {}
local CP_FNS = { ["Trigger Checkpoint"] = true, ["Save New Checkpoint"] = true }
local function share(e)
    if e.kind == "act" and not CP_FNS[e.fn] then FrameQ[#FrameQ + 1] = e; return end
    share_now(e)
end
local function flush_shares()
    if #FrameQ == 0 then return end
    local q = FrameQ
    FrameQ = {}
    local lsa
    for _, e in ipairs(q) do if e.lsa then lsa = e end end      -- the last one seen is the outermost
    if lsa then
        share_now(lsa)
        log("shared level event %s (%d nested calls not sent)", lsa.fn:sub(1, 60), #q - 1)
    else
        for _, e in ipairs(q) do share_now(e) end
    end
end

local Hot, HotCount, HotSec = {}, {}, -1
local DISCOVER = Config.discover == true or Config.discover == "true"
local function on_local_call(cname, fnname, ctx, ...)
    local hk = cname .. ":" .. fnname
    if P.crumb then P.crumb("hook " .. hk:match("([^/]+)$")) end
    local pf = P.Perf
    if pf then pf.hooks = pf.hooks + 1; pf.by[hk] = (pf.by[hk] or 0) + 1 end
    if Hot[hk] then return end
    -- Chapter 1 / 2 streaming volume (walking through it loads the next area): the volume may sit in an area
    -- that this very call unloads - reading it afterwards (its name, its level lists) read freed memory and
    -- crashed UE4SS for both players at the same spot. Its lists are read beforehand (P.cache_volumes); here
    -- only its address is compared (no engine read).
    if fnname == "Load Levels" and cname:find("LevelStreamingVolume", 1, true) then
        local okg, o = pcall(function() return ctx:get() end)
        local ad = okg and o and try(function() return tostring(o:GetAddress()) end)
        local v = ad and P.VolLists[ad]
        if v then pcall(claim_levels, v.load, true); pcall(claim_levels, v.unload, false) end
        P.hush(1.5)                         -- areas are changing now (see P.Quiet)
        if P.assets_changed then pcall(P.assets_changed) end   -- (main.lua: cached assets may be freed now)
        P.VolNeedScan = true
        return
    end
    if P.quiet() and not CP_FNS_ALL[fnname] and not DEATH_SET[fnname] then return end
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
            -- we (re)spawn here: our world is at this checkpoint. Names: PlayerCheckpoint4, PlayerCheckpoint8-12
            -- (one spawn point for 8..12), PlayerCheckpoint26_11 (26)
            if replaying == 0 then
                local a, b = path:match("PlayerCheckpoint(%d+)%-(%d+)$")
                a = tonumber(a or path:match("PlayerCheckpoint(%d+)"))
                b = tonumber(b) or a
                if a then
                    LOCAL_CP = (CP_MAX >= a and CP_MAX <= b) and CP_MAX or a
                    log("spawned at checkpoint %d", LOCAL_CP)
                    P.new_game_check(LOCAL_CP)
                end
            end
        elseif ACT_SET[fnname] and path:find("StreamInLevel", 1, true) then
            claim_levels(name_array(obj, "Levels To Stream In"), true)
        end
    end
    if fnname == "Save New Checkpoint" and args then
        local n = cp_number(args)
        -- (a replayed checkpoint trigger saves a frame or two later, outside the replay: not ours)
        if n and replaying == 0 and n > LOCAL_CP and P.game_time() > RemoteCPUntil then
            LOCAL_CP = n
            local t = math.floor(P.game_time())
            log("checkpoint %d reached at %d:%02d:%02d", n, t // 3600, t // 60 % 60, t % 60)
            -- split time (speedrun feel): session time when the checkpoint is reached
            if P.Stats and LOCAL_CP_SEEN then table.insert(P.Stats.splits, { n = n, t = t }) end
            if P.popup and LOCAL_CP_SEEN then pcall(P.popup, ("Checkpoint %d - %d:%02d:%02d"):format(n, t // 3600, t // 60 % 60, t % 60), "cp") end
            LOCAL_CP_SEEN = true
        end
        if n and n > CP_MAX then
            CP_MAX = n
            if P.CHAPTER == 1 and SHARE_CP1 and replaying == 0 and Coop.active() then Coop.send_event("cp1", tostring(n)) end
        elseif n and n < CP_MAX and (replaying > 0 or (P.CHAPTER == 1 and SHARE_CP1)) then
            CP_FIX = CP_MAX     -- an older trigger was replayed here / Chapter 1: keep the furthest saved
        end
    end
    if replaying > 0 or not Coop.active() or not path then return end
    if is_checkpoint_event(path, fnname) then return end      -- see is_checkpoint_event
    if fnname == "Pick Up Object" and cname:find("/Breakers%.") and P.Brk then     -- Storage breakers (see P.Brk)
        pcall(P.Brk.picked, obj)
        return
    end

    if DEATH_SET[fnname] and cname:find("PlayerBP", 1, true) then
        if not Game.dead then
            Game.dead = true
            P.hush(P.Quiet.MAX_DEATH)                -- the level reloads soon (until then: quiet, see P.Quiet)
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
    if LsaClass[cname] and lsa_fn(fnname) then
        if SYNC_ACT and args and is_level_placed(path) then
            share({ kind = "act", path = path, fn = fnname, args = args, lsa = true })
        end
        return
    end
    local rm = REMAP[short_class(cname)]
    if rm and rm[fnname] then
        -- (a scan / door a friend started here finishes by itself: don't send its RESULTS back - the scan
        -- itself, hand on / off, is always sent: a friend's power event must never block our own scan)
        local sc = short_class(cname)
        if P.CHAPTER == 1 and sc == P.RaiseDoor.CLASS
            and (P.game_time() - P.Pad.remote_at < P.Pad.ECHO or P.RaiseDoor.remote[path]) then return end
        if sc == P.Pad.CLASS and fnname == "Activate Blueprints" then
            if P.Pad.done[path] then return end
            P.Pad.done[path] = true
        end
        if SYNC_ACT and is_level_placed(path) then
            local tgt = rm[fnname]
            -- (the power event is sent alone: what it triggered this frame runs from it in the other games)
            share({ kind = "act", path = path, fn = type(tgt) == "table" and tgt[1] or tgt, args = type(tgt) == "table" and tgt[2] or "",
                lsa = (sc == "PowerConnector_Master_C" or fnname == "Short Circuit Event") or nil })
        end
        return
    end
    -- Chapter 2 doors are synced by the leaves' real rotation (pose sync in coop_extra); replaying
    -- their functions would snap them open the wrong way and would use up the other player's key.
    if DOOR_SET[fnname] and is_door_class(cname) then
        -- Chapter 1 doors: a player opened it (by hand, with a key, a code...) -> the other games run the
        -- door's own "force open" (opens a locked door without needing the key there)
        if P.CHAPTER == 1 and SYNC_ACT and CH1_DOOR_OPEN[fnname] and is_level_placed(path) then
            share({ kind = "act", path = path, fn = "CoopOpenDoor", args = "" })
        end
        return
    end
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
    if path:find("ToggleStreamingLevelVisibility", 1, true) then
        if protect_levels then pcall(protect_levels, path) end
        return
    end
    if SYNC_ACT and ACT_SET[fnname] and is_level_placed(path) then
        if path:find("GrabPackDoor", 1, true) then return end      -- (the GrabPack box: see receive)
        if not args then trace("  not replicable: %s", tostring(why)); return end
        share({ kind = "act", path = path, fn = fnname, args = args })
    end
end

local seen_class_addr = {}
local HookedPath = {}        -- "class path:function" -> registered once for the whole session
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
        -- UE4SS keeps a hook per function PATH and it survives the class being reloaded (every death / checkpoint
        -- load gives the level's classes new addresses). Registering again added another callback each time:
        -- after 7 respawns every hooked call ran 7 times, and each respawn re-registered thousands (~3 ms each).
        local hp = cname .. ":" .. fname
        if HookedPath[hp] then return end
        HookedPath[hp] = true
        local flags = try(function() return fns[fname]:GetFunctionFlags() end) or 0
        if (flags & 0x00100000) ~= 0 or (flags & 0x00000400) ~= 0 then return end   -- delegate / native: not hookable safely
        local ok, err = pcall(RegisterHook, cname .. ":" .. fname, function(ctx, ...) on_local_call(cname, fname, ctx, ...) end)
        if ok then
            local l = fname:lower()
            for _, w in ipairs(TRACE_WORDS) do if l:find(w, 1, true) then HookedFns[cname .. ":" .. fname] = true end end
        end
        if ok then hook_count = hook_count + 1 else HookedPath[hp] = nil; hook_fail = hook_fail + 1; trace("hook failed %s:%s %s", cname, fname, tostring(err)) end
    end
    for _, f in ipairs(ACT_FNS) do try_hook(f) end
    if is_door_class(cname) then for _, f in ipairs(DOOR_FNS) do try_hook(f) end end
    local rm = REMAP[short_class(cname)]
    if rm then for f in pairs(rm) do try_hook(f) end end
    for _, f in ipairs(INV_FNS) do try_hook(f) end
    for f in pairs(COMP_INV_SET) do try_hook(f) end
    for f in pairs(PICKUP_SET) do try_hook(f) end
    for _, f in ipairs(TRACE_FNS) do try_hook(f) end
    if is_level_script(cls, cname) then
        for fname in pairs(fns) do if lsa_fn(fname) then try_hook(fname) end end
    end
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

-- the player's own components (inventory might live in one)
local function scan_pawn_classes()
    local p = pawn()
    if not p then return end
    pcall(function()
        local comps = p:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
        for i = 1, #comps do
            local c = comps[i]:get()
            if valid(c) then hook_class(c:GetClass(), false) end
        end
    end)
end
-- every class seen by coop_extra's actor census (one shared pass over all actors, run when levels change)
local CensusCname = {}   -- class address -> full name ("" = not a blueprint class)
-- e.a (an actor) may only be touched in the census frame: queued entries keep only the class (classes live
-- as long as their level; the queue is dropped when levels change)
local function hook_census_class(e)
    if e.path then e = { cls = try(StaticFindObject, e.path) } end      -- queued: looked up fresh (see HookQ)
    local cls, a = e.cls, e.a
    if not valid(cls) then return end
    hook_class(cls)
    if not a then return end
    local ad = try(function() return cls:GetAddress() end)
    local cname = ad and CensusCname[ad]
    if not cname then cname = fullpath(cls) or ""; if ad then CensusCname[ad] = cname end end
    if cname:find("^/Game/") and valid(a) then hook_pickup_components(a, cls, cname) end
end
-- RegisterHook costs ~3 ms per function. A whole map load (hundreds of classes) is hooked at once (the
-- loading screen hides it); the few new classes of an area streamed in while playing are hooked a few per
-- frame (HOOK_BUDGET) so walking into a new area doesn't stutter. The queue is dropped when levels change
-- (a class of a level that streamed out may be freed) - the census after that change queues them again.
local HookQ = {}
local HOOK_BUDGET = 0.004
local HOOK_ALL_AT_ONCE = 60
local function hook_log(before)
    if hook_count ~= before then
        local n = 0 for _ in pairs(hooked_classes) do n = n + 1 end
        log("hooked %d functions (%d failed) across %d classes", hook_count, hook_fail, n)
    end
end
local function hook_queue_tick()
    if #HookQ == 0 then return end
    local before, c0 = hook_count, os.clock()
    while #HookQ > 0 and os.clock() - c0 < HOOK_BUDGET do
        pcall(hook_census_class, table.remove(HookQ))
    end
    hook_log(before)
    if #HookQ == 0 then retry_pending() end
end
P.CensusDone = P.CensusDone or {}
table.insert(P.CensusDone, function(classes)
    local c0 = os.clock()
    local new = {}
    for _, e in pairs(classes) do
        local ad = try(function() return e.cls:GetAddress() end)
        if ad and not seen_class_addr[ad] then new[#new + 1] = e end
    end
    if #new > HOOK_ALL_AT_ONCE or not Coop.active() then
        local before = hook_count
        for _, e in ipairs(new) do pcall(hook_census_class, e) end
        hook_log(before)
        retry_pending()
    else
        HookQ = {}
        for _, e in ipairs(new) do
            -- pickup components need the actor: now; the class hooks (the slow part) a few per frame
            local cname = fullpath(e.cls) or ""
            if cname:find("^/Game/") and valid(e.a) then pcall(hook_pickup_components, e.a, e.cls, cname) end
            -- only the path is kept: the class of an area that streams out in the meantime is freed, and
            -- touching it a frame later (even IsValid) crashed UE4SS (crash reports 1.6.3/1.6.4, Chapter 1)
            if cname ~= "" then HookQ[#HookQ + 1] = { path = cname } end
        end
    end
    if os.clock() - c0 > 0.005 then log("slow: class hooks %.1f ms (%d new classes)", (os.clock() - c0) * 1000, #new) end
end)

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
    if P.Fresh.batch[from] and P.fresh() then return end      -- (old progress after New Game, see P.Fresh)
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
    if P.Fresh.batch[from] and P.fresh() then return end      -- (old progress after New Game, see P.Fresh)
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
        -- (swapping the hand starts animations: not from inside the actor tick, see "Late queue")
        local n = RH.room
        if P.late then P.late(function() if pawn() then rhand_apply(n) end end, "right hand") else rhand_apply(n) end
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
        local short = nm:match("([%w_%-]+)$")
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
    local outer, name = (fullpath(ls) or ""):match("([%w_%-]+):([%w_]+)$")
    if outer then return outer .. ":" .. name end
end
local function slot_pkg(ls)
    local l = try(function() return ls:GetLoadedLevel() end)
    if valid(l) then return (fullpath(l) or ""):match("/([%w_%-]+)%.[%w_%-]+:PersistentLevel") end
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
    return path:match("/([%w_%-]+)%.[%w_%-]+:PersistentLevel")
end

-- the streaming slots live as long as the map: look them up again only when the set of loaded levels
-- changed or every 20 s (FindAllOf walks every engine object, ~10 ms - it used to run every second)
local SlotList, SlotListAt, SlotIds, SlotListStale = nil, -100, {}, false
local SlotListFullAt = -100
local function scan_slots()
    local seen = {}
    local now = P.game_time()
    -- (SlotList is dropped the moment the number of loaded levels changes, see the driver: a slot inside a
    -- level that streamed out must never be touched again)
    -- After a level change only the world's own list is read (World.StreamingLevels, a property read; it lacks
    -- slots nested inside streamed levels, e.g. AfterSlide:LevelStreamingDynamic_0). The full FindAllOf
    -- (~12 ms) runs every 30 s; only a full list may drop slots we no longer see.
    local full = false
    if not SlotList or now - SlotListFullAt > 30 then
        local quick = SlotList == nil and now - SlotListFullAt <= 30
        local list
        if quick then
            list = {}
            local p = pawn()
            pcall(function() p:GetWorld().StreamingLevels:ForEach(function(_, e) list[#list + 1] = e:get() end) end)
            if #list == 0 then quick = false end
        end
        if not quick then list = FindAllOf("LevelStreaming") or {}; SlotListFullAt = now; full = true end
        -- only PATHS are kept: a slot object inside an area that unloads is freed, and the kept object crashed
        -- UE4SS a moment later (CH1 power room unloading at the Steam Hallway, 1.6.x) - looked up fresh below
        local paths = {}
        for _, o in ipairs(list) do local pth = valid(o) and fullpath(o); if pth then paths[#paths + 1] = pth end end
        SlotList, SlotListAt, SlotIds, SlotListStale = paths, now, {}, false
    end
    for i, pth in ipairs(SlotList) do
        local ls = try(StaticFindObject, pth)
        if not valid(ls) then ls = nil end
        local n = SlotIds[i]
        if n == nil then n = ls and slot_id(ls) or false; SlotIds[i] = n end   -- name looked up once per list
        if ls and n and not seen[n] then
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
            s.obj, s.path, s.last_load = ls, pth, load
            -- every engine call costs ~0.1 ms and Chapter 2 has ~30 slots: visibility only matters for slots that
            -- are (being) loaded, most are idle
            if load or loaded then
                s.vis = try(function() return ls:IsLevelVisible() end) and true or false
                s.vis_want = try(function() return ls.bShouldBeVisible end) ~= false   -- the game may hide a loaded area
            else
                s.vis, s.vis_want = false, false
            end
            -- which map a slot holds only changes when it (re)loads: asking costs a full object name each time
            if loaded and (not s.pkg or not s.was_loaded) then
                local pkg = slot_pkg(ls)
                if pkg then s.pkg = pkg end
            end
            if loaded and not s.was_loaded and s.pkg then LevelReplayAt[s.pkg] = now + 1.0 end
            -- an area came or went: a reloaded actor often gets the SAME address as before, so cached parts of
            -- it (door leaves, bridge meshes...) looked alive but were freed -> UE4SS crash (1.6.3-1.6.5 reports,
            -- 30-60 s after the mod reloaded an area for the other player). Other modules drop their caches.
            if s.was_loaded ~= nil and loaded ~= s.was_loaded then
                for _, f in ipairs(P.LevelsChanged) do pcall(f) end
            end
            s.was_loaded = loaded
        end
    end
    for n, sl in pairs(Slots) do
        if not seen[n] then
            if full then Slots[n] = nil; Ours[n] = nil
            else sl.obj = nil end           -- not in the quick list (nested slot): its level may be gone - never touch it
        end
    end
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
    for slot, pkg in list:gmatch("([%w_%-]+:[%w_]+)=([%w_%-%?]+)") do set[slot] = pkg end
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

-- A level we keep loaded only for a friend runs its own scripts here too: e.g. Whack-a-Wuggy's
-- ToggleStreamingLevelVisibility triggers unloaded the Hub/Hallway/Musical Memory under a player standing there
-- (the WAW level assumes the player just walked in) -> fell to their death. A toggle from such a friend-only
-- level must not touch our own areas: whatever it switched off is switched on again in the same frame
-- (the hook runs right after the toggle, before streaming acts on it).
protect_levels = function(path)
    if not SYNC_LEVELS then return end
    local pkg = path:match("/([%w_%-]+)%.[%w_%-]+:PersistentLevel")
    if not pkg then return end
    local friend_only = false
    for n, s in pairs(Slots) do if s.pkg == pkg and Ours[n] then friend_only = true; break end end
    if not friend_only then return end
    local restored = {}
    for n, s in pairs(Slots) do
        if s.want and not Ours[n] and P.sobj(s) then           -- one of our own areas
            local load = try(function() return P.sobj(s):ShouldBeLoaded() end)
            local vis = try(function() return P.sobj(s).bShouldBeVisible end)
            if load == false or (s.vis_want and vis == false) then
                pcall(function() P.sobj(s):SetShouldBeLoaded(true) end)
                if s.vis_want then pcall(function() P.sobj(s):SetShouldBeVisible(true) end) end
                restored[#restored + 1] = tostring(s.pkg or n)
            end
        end
    end
    if #restored > 0 then log("kept %s loaded: %s (a friend's level) tried to unload it", table.concat(restored, ", "), pkg) end
end

local function set_slot(n, on)
    local s = Slots[n]
    if not P.sobj(s) then return end
    if P.assets_changed then pcall(P.assets_changed) end      -- an area loads / unloads (see main.lua)
    pcall(function() P.sobj(s):SetShouldBeLoaded(on) end)
    pcall(function() P.sobj(s):SetShouldBeVisible(on) end)
    s.last_load = on
    -- we unload a level ourselves: queued class hooks / the level list may hold its objects - drop them now,
    -- not only when the next level count (1 s later) notices
    if not on then HookQ = {}; SlotList = nil end
end

local SyncProf = {}
-- Keeping a friend's areas loaded all the time (old default) let those levels run their own scripts and enemies
-- against OUR player: Whack-a-Wuggy unloaded our floor, Statues' PJ and Mommy's levels killed players in the hub
-- every ~30 s. Now off by default (config bg_levels=true / launcher "Keep friends' areas loaded"): F6 loads the
-- friend's area on demand (level_prep) and waits for the floor.
local BG_LEVELS = Config.bg_levels == true or Config.bg_levels == "true"
local NO_BACKGROUND = { StatuesRoom = true, Mommy_Chase_Redone = true }
for pk in tostring(Config.no_background_levels or ""):gmatch("[%w_%-]+") do NO_BACKGROUND[pk] = true end
local function sync_levels()
    local c0 = os.clock()
    scan_slots()
    SyncProf.scan = os.clock() - c0
    report_levels(false)
    if not SYNC_LEVELS then return end
    local need = {}
    for _, set in pairs(remote_levels) do
        for slot, pkg in pairs(set) do
            local n = resolve_slot(slot, pkg)
            -- deadly chase levels run their game against OUR player when loaded here (Statues' PJ killed a
            -- player in the hub): not kept loaded in the background; F6 (level_prep) still loads them
            if n and BG_LEVELS and not NO_BACKGROUND[pkg] then need[n] = pkg end
        end
    end
    local standing = nil
    for n, s in pairs(Slots) do
        if need[n] and not s.last_load then
            set_slot(n, true); Ours[n] = true
            log("loading %s (%s) for the other player", n, need[n])
        elseif need[n] and Ours[n] and s.last_load and not s.vis and P.sobj(s) then
            pcall(function() P.sobj(s):SetShouldBeVisible(true) end)
        elseif need[n] and not Ours[n] and s.last_load and not s.vis_want and P.sobj(s) then
            -- our game hid this area (walked past a visibility trigger) but a friend is in it: an
            -- invisible area has no floor, so teleporting there (F6) dropped players out of the map
            pcall(function() P.sobj(s):SetShouldBeVisible(true) end)
            s.vis_forced = true
            log("showing %s (%s) again for the other player", n, need[n])
        elseif not need[n] and not Ours[n] and s.vis_forced and s.last_load and P.sobj(s) then
            local now = P.game_time()
            s.unshown_since = s.unshown_since or now
            if now - s.unshown_since >= 10 then
                if standing == nil then standing = floor_pkg() or false end
                if standing ~= false and s.pkg == standing then
                    s.vis_forced, s.unshown_since = nil, nil          -- we walked in: it's ours now
                elseif standing ~= false then
                    pcall(function() P.sobj(s):SetShouldBeVisible(false) end)
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
                    P.hush(P.Quiet.RELEASE)
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
        if s and P.sobj(s) then
            if not s.last_load then
                set_slot(n, true); Ours[n] = true
                log("loading %s (%s) for the teleport", n, pkg)
            elseif not s.vis_want and not Ours[n] then
                pcall(function() P.sobj(s):SetShouldBeVisible(true) end)
                s.vis_forced = true
            end
            -- only wait for the main areas: sub-areas inside a streamed area (RevokedToys_CHP2:LevelStreaming...)
            -- may never appear here (parent not shown, or the other game's copy differs)
            local top = n:match("^([%w_%-]+):") == Game.map
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

------------------------------------------------------------------ checkpoints (follow)
P.cp_info = function() return CP_MAX, LOCAL_CP end
P.cp_set_local = function(n) LOCAL_CP = n end      -- dev tests
-- after a load the game spawns at its saved checkpoint, which is the furthest anyone reached (CP_MAX)
table.insert(P.Handlers.unload, function() if CP_MAX > LOCAL_CP then LOCAL_CP = CP_MAX end end)
table.insert(P.Handlers.state, function() return LOCAL_CP >= 0 and (" C=%d"):format(LOCAL_CP) or "" end)
-- save checkpoint n (the furthest) and restart the level: the game respawns there with that part of the
-- world in its proper state (chase over, doors open...). Chapter 2 only.
P.respawn_at_cp = function(n)
    local gm = try(FindFirstOf, "Chapter2_Gamemode_C")
    local p = pawn()
    if not (valid(gm) and p) then return false end
    n = math.max(n or -1, CP_MAX)
    replaying = replaying + 1
    local ok = pcall(function() gm["Save New Checkpoint"](gm, n) end)
    replaying = replaying - 1
    if not ok then return false end
    if n > CP_MAX then CP_MAX = n end
    local ks = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc = try(function() return p:GetController() end)
    log("follow: respawning at checkpoint %d", n)
    return pcall(function() ks:ExecuteConsoleCommand(p:GetWorld(), "RestartLevel", pc) end)
end

------------------------------------------------------------------ driver
level_count = function()
    local p = pawn()
    local n = p and try(function() return #p:GetWorld().Levels end)
    return n or -1
end
P.level_count = level_count
local t_levels, t_scan, t_hands, t_follow, t_pending = 0, 0, 0, 0, 0
local last_level_objs = -1

-- level about to reload: drop every cached engine object (slot objects); paths/ledger are kept
table.insert(P.Handlers.unload, function()
    for k in pairs(Slots) do Slots[k] = nil end
    for k in pairs(Ours) do Ours[k] = nil end
    HookQ = {}
    SlotList = nil
    for k in pairs(Watch) do Watch[k] = nil end
    for k in pairs(ChildCache) do ChildCache[k] = nil end   -- crash fix: CH2 door child actors die with the level
    last_level_objs = -1
    my_levels_str = nil
end)
local diag_done = false

table.insert(P.Handlers.restart, function() scan_classes() end)

------------------------------------------------------------------ Chapter 1 keys (team inventory)
-- Keys (GiftshopKey, SimonRoomKey, Security...) go into the player's "Inventory Items" string array straight
-- from the pickup blueprint, without a function the hooks could see. So the array is watched: a key that
-- shows up here is given to everyone, a key used up here is taken from everyone. After a load / respawn the
-- game restores the array from its save - that is never treated as a change; missing team keys are put back.
local Inv1 = { last = nil, team = {}, t = 0, addr = nil }
local function inv1_set(list) local t = {} for _, v in ipairs(list) do t[v] = true end return t end
local function inv1_has(p, name)
    for _, v in ipairs(name_array(p, "Inventory Items")) do if v == name then return true end end
    return false
end
local function inv1_add(p, name)
    if inv1_has(p, name) then return true end
    local arr = try(function() return p["Inventory Items"] end)
    local n = arr and try(function() return arr:GetArrayNum() end)
    if type(n) ~= "number" then return false end
    return pcall(function() arr[n + 1] = name end)
end
local function inv1_remove(p, name)
    if not inv1_has(p, name) then return end
    replaying = replaying + 1
    pcall(function() p["Remove Item From Inventory"](p, name) end)
    replaying = replaying - 1
end
local function inv1_valid_name(s) return type(s) == "string" and #s > 0 and #s <= 64 and s:match("^[%w_ %-]+$") ~= nil end
Coop.on("inv1", function(from, rest)
    if P.CHAPTER ~= 1 or not SYNC_INV then return end
    if P.Fresh.batch[from] and P.fresh() then return end    -- a friend's old keys after New Game (see P.Fresh)
    local op, name = tostring(rest or ""):match("^([%+%-])(.+)$")
    if not op or not inv1_valid_name(name) then return end
    Inv1.team[name] = op == "+" or nil
    local p = pawn()
    if not valid(p) then return end
    if op == "+" then
        if inv1_add(p, name) then log("key from %s: %s", tostring(from), name) end
    else
        inv1_remove(p, name)
    end
    if Inv1.last then Inv1.last[name] = op == "+" or nil end
end)
table.insert(P.Handlers.join, function(id)
    if P.CHAPTER ~= 1 or not SYNC_INV then return end
    for name in pairs(Inv1.team) do Coop.send_to(id, "inv1", "+" .. name) end
end)
local function inv1_reset() Inv1.last, Inv1.addr = nil, nil end
table.insert(P.Handlers.unload, inv1_reset)
table.insert(P.Handlers.restart, inv1_reset)
local function inv1_tick()
    if P.CHAPTER ~= 1 or not SYNC_INV then return end
    local p = pawn()
    if not valid(p) then return end
    local a = try(function() return p:GetAddress() end)
    local cur = inv1_set(name_array(p, "Inventory Items"))
    if not Inv1.last or Inv1.addr ~= a then
        -- fresh load / new pawn: this is the saved state, not a change. Give back what the team holds.
        Inv1.addr = a
        for name in pairs(Inv1.team) do if not cur[name] and inv1_add(p, name) then cur[name] = true end end
        Inv1.last = cur
        return
    end
    if not Coop.active() then Inv1.last = cur; return end
    for name in pairs(cur) do
        if not Inv1.last[name] and inv1_valid_name(name) then
            Inv1.team[name] = true
            Coop.send_event("inv1", "+" .. name)
            log("shared key: %s", name)
        end
    end
    for name in pairs(Inv1.last) do
        if not cur[name] and inv1_valid_name(name) then
            Inv1.team[name] = nil
            Coop.send_event("inv1", "-" .. name)
            log("key used up: %s", name)
        end
    end
    Inv1.last = cur
end
P.Inv1 = Inv1     -- diagnostics

table.insert(P.Handlers.tick, function(dt, have)
    local crumb = P.crumb or function() end
    -- the frame tick never runs inside a friend's replayed event: a counter left above 0 here made this game
    -- treat everything its own player did as a replay and share nothing any more (doors, code pad...)
    if replaying ~= 0 then
        if not P.ReplayStuckLogged then P.ReplayStuckLogged = true; log("replay counter was stuck at %d - reset (sharing works again)", replaying) end
        replaying = 0
    end
    if #FrameQ > 0 then crumb("world: flush"); pcall(flush_shares) end
    if #HookQ > 0 and have then crumb("world: hooks"); pcall(hook_queue_tick) end
    if AutoFollow and have then pcall(auto_follow_tick) end
    if not have or not pawn() then return end
    local now = P.game_time()
    pcall(cp1_tick)          -- every frame: a friend's checkpoint is saved here at once (only flag checks otherwise)
    if now - Inv1.t > 0.5 then Inv1.t = now; pcall(inv1_tick) end
    if now - t_follow > 1 then t_follow = now; pcall(check_auto_follow) end
    if now - t_pending > 5 and next(Pending) then t_pending = now; pcall(retry_pending) end   -- e.g. gated controllers once we are near
    if now - t_scan > 1 then
        t_scan = now
        crumb("world: count levels")
        -- the world's own level list (a property read, ~0 ms; FindAllOf("Level") cost 12 ms every time)
        local lv = level_count()
        if lv ~= last_level_objs then HookQ = {}; SlotList = nil end   -- (queued classes may be freed now)
        if lv ~= last_level_objs and not P.quiet() then      -- (the rescan after the quiet time: see P.Quiet)
            SlotList = nil
            HookQ = {}
            local c0 = os.clock()
            last_level_objs = lv
            -- new classes are hooked when coop_extra's census of the new level set is done (CensusDone)
            if P.census_step then scan_pawn_classes() else crumb("world: scan_classes"); scan_classes() end
            crumb("world: retry_pending"); retry_pending()
            crumb("world: report_levels"); report_levels(true)
            if os.clock() - c0 > 0.005 then log("slow: class scan %.1f ms", (os.clock() - c0) * 1000) end
        end
    end
    if now - t_levels > 2 then
        t_levels = now
        local c0 = os.clock()
        crumb("world: sync_levels"); sync_levels(); crumb("world: cp_fix"); pcall(cp_fix_tick)
        local S = P.Perf and P.Perf.sec
        if S then S.w_levels = (S.w_levels or 0) + os.clock() - c0 end
        if os.clock() - c0 > 0.005 then log("slow: level sync %.1f ms (slots %.1f ms, list age %.0f s)", (os.clock() - c0) * 1000, (SyncProf.scan or 0) * 1000, now - SlotListAt) end
    end
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

table.insert(P.Handlers.unload, function() P.RaiseDoor.remote = {}; P.Pad.done = {} end)

-- "New Game" from the main menu: the world starts over at checkpoint 0, but the ledger still remembered every
-- door / scanner / item from before and re-applied it when the levels loaded (doors stood open in the new game).
-- After a world change, re-applying is held until the spawn checkpoint is known (Load Checkpoint, a few
-- seconds): checkpoint 0 = a new game -> everything remembered is dropped; any other = Load Game / respawn ->
-- the held levels are re-applied as before. No spawn seen within REPLAY_HOLD s: re-applied anyway.
P.REPLAY_HOLD = 10
P.HeldReplays = {}
P.release_replays = function()
    P.ReplayHold = nil
    local held = P.HeldReplays
    P.HeldReplays = {}
    for pkg in pairs(held) do replay_level(pkg) end
    retry_pending()
end
P.new_game_check = function(cp)
    if cp == 0 then
        local n = #Ledger
        for i = #Ledger, 1, -1 do Ledger[i] = nil end
        for k in pairs(LedgerKeys) do LedgerKeys[k] = nil end
        for k in pairs(Pending) do Pending[k] = nil end
        CP_MAX, CP_FIX, LOCAL_CP_SEEN = 0, nil, false
        P.RaiseDoor.state, P.RaiseDoor.remote = {}, {}
        Inv1.team, Inv1.last, Inv1.addr = {}, nil, nil       -- (the code door's "Security" key came back)
        RH.room, RH.applied = 0, true                         -- (and Chapter 2's right hand type)
        P.ReplayHold, P.HeldReplays = nil, {}
        P.Pad.done = {}
        for _, f in ipairs(P.NewGameReset) do pcall(f) end    -- other modules' remembered state (coop_extra)
        P.NewGameAt = P.game_time()
        log("new game: forgot %d remembered world events (doors, items...)", n)
        return
    end
    if P.ReplayHold then P.release_replays() end
end
-- (the spawn at checkpoint 0 can come BEFORE this world change: then there is nothing left to hold)
table.insert(P.Handlers.unload, function()
    if P.NewGameAt and P.game_time() - P.NewGameAt < 20 then return end
    P.ReplayHold = P.game_time() + P.REPLAY_HOLD; P.HeldReplays = {}
end)
table.insert(P.Handlers.tick, function()
    if P.ReplayHold and P.game_time() >= P.ReplayHold then P.release_replays() end
end)

-- the friend's catch-up batch (see P.Fresh)
Coop.on("lbeg", function(from) P.Fresh.batch[from] = true end)
Coop.on("lend", function(from) P.Fresh.batch[from] = nil end)
P.start_new_game = function()
    P.Fresh.untilT = os.clock() + P.Fresh.SECS
    P.new_game_check(0)
    log("New Game pressed: starting from the beginning (friends' old progress ignored for %d s)", P.Fresh.SECS)
end
-- Chapter 1 main menu: hook its New Game button. The menu widget only exists in the menu, so look for it once
-- a second there (on the game thread; nothing cached is touched) until the hook is in. The hook stays for the
-- whole session (UE4SS keeps it by function path). It takes no parameters, so registering it from here is fine.
if P.CHAPTER == 1 and LoopAsync and ExecuteInGameThread then
    LoopAsync(1000, function()
        if P.Fresh.hooked then return true end
        if Game.pawn ~= nil or Game.loading then return false end
        ExecuteInGameThread(function()
            if P.Fresh.hooked then return end
            local u = try(FindFirstOf, "UI_MainMenu2_C")
            if not u or not try(function() return u:IsValid() end) then return end
            local cls = fullpath(try(function() return u:GetClass() end))
            if not cls then return end
            P.Fresh.hooked = true
            local ok, err = pcall(RegisterHook, cls .. P.Fresh.FN, function() pcall(P.start_new_game) end)
            log("New Game button %s", ok and "hooked" or ("not hooked: " .. tostring(err)))
        end)
        return false
    end)
end
-- quiet while a level loads (see P.Quiet): from the world change until a moment after the player is back
table.insert(P.Handlers.unload, function() P.Quiet.load = true end)
table.insert(P.Handlers.restart, function()
    P.Quiet.load = false
    P.Quiet.untilT = os.clock() + P.Quiet.AFTER_LOAD     -- (also ends a death's quiet time)
end)

-- streaming volumes' level lists (read here, outside their "Load Levels" call: see on_local_call)
P.cache_volumes = function()
    P.VolNeedScan = false
    local t = {}
    for _, a in ipairs(try(FindAllOf, "BP_LevelStreamingVolume_C") or {}) do
        pcall(function()
            if a:IsValid() then
                t[tostring(a:GetAddress())] = { load = name_array(a, "LevelsToLoad"), unload = name_array(a, "LevelsToUnload") }
            end
        end)
    end
    P.VolLists = t
end
table.insert(P.Handlers.restart, function() P.VolNeedScan = true end)
table.insert(P.Handlers.tick, function(dt, have)
    if have and P.VolNeedScan and not P.quiet() then pcall(P.cache_volumes) end
end)
table.insert(P.LevelsChanged, function() P.VolNeedScan = true end)
table.insert(P.LevelsChanged, function() if P.assets_changed then pcall(P.assets_changed) end end)

------------------------------------------------------------------ Chapter 1 Storage breakers
-- The red hand room (05_Storage): a RandomSpawner puts 3 breakers ("batteries") on 3 of 16 spawn points - a
-- different 3 in every game, and the spawned actors have different names everywhere. Synced by the spawn
-- points (level-placed, same names in every game): the first layout anyone reports is the team's (lower
-- player id wins a tie), every game moves its breakers onto those points, and a breaker picked up anywhere
-- disappears at that point for everyone (also later, after a reload: "taken").
P.Brk = { lay = nil, lay_from = nil, taken = {}, at = -100, pts = nil, pts_gen = -1, EVERY = 1.5, NEAR = 120, where = {} }
P.Brk.brk_points = function()
    if P.Brk.pts and P.Brk.pts_gen == (P.LevelGen or 0) then return P.Brk.pts end
    local pts = {}
    for _, a in ipairs(try(FindAllOf, "R_SpawnPoints_C") or {}) do
        pcall(function()
            if a:IsValid() then
                local l = a:K2_GetActorLocation()
                pts[#pts + 1] = { name = a:GetFName():ToString(), x = l.X, y = l.Y, z = l.Z }
            end
        end)
    end
    P.Brk.pts, P.Brk.pts_gen = pts, P.LevelGen or 0
    return pts
end
P.Brk.brk_nearest = function(l)
    local best, bd
    for _, p in ipairs(P.Brk.brk_points()) do
        local d = (p.x - l.X) ^ 2 + (p.y - l.Y) ^ 2 + (p.z - l.Z) ^ 2
        if not bd or d < bd then best, bd = p, d end
    end
    return best, bd and math.sqrt(bd)
end
-- our breakers this frame: { { a = actor, pt = spawn point or nil } } (looked up fresh, never kept)
P.Brk.brk_mine = function()
    local out = {}
    for _, a in ipairs(try(FindAllOf, "Breakers_C") or {}) do
        pcall(function()
            -- (spawned breakers live in the persistent level; the fixed ones elsewhere in Storage are never
            -- near a spawn point, so only breakers ON a spawn point count)
            if a:IsValid() then
                local l = a:K2_GetActorLocation()
                local pt, d = P.Brk.brk_nearest(l)
                if pt and d and d < P.Brk.NEAR then
                    out[#out + 1] = { a = a, pt = pt }
                    P.Brk.where[tostring(a:GetAddress())] = pt.name    -- (picked up: it's in the hand then, see picked)
                end
            end
        end)
    end
    return out
end
P.Brk.storage_loaded = function()
    for _, sl in pairs(Slots) do if sl.pkg == "05_Storage" and sl.was_loaded then return true end end
    return false
end
P.Brk.brk_send_layout = function(to)
    if not P.Brk.lay then return end
    local list = table.concat(P.Brk.lay, ",")
    if to then Coop.send_to(to, "brklay", list) else Coop.send_event("brklay", list) end
    for n in pairs(P.Brk.taken) do if to then Coop.send_to(to, "brktake", n) else Coop.send_event("brktake", n) end end
end
P.Brk.brk_apply = function()
    local mine = P.Brk.brk_mine()
    if #mine == 0 then return end
    if not P.Brk.lay then
        -- we are the first: our spawner's choice is the team's
        local lay = {}
        for _, b in ipairs(mine) do if b.pt then lay[#lay + 1] = b.pt.name end end
        if #lay == 0 then return end
        table.sort(lay)
        P.Brk.lay, P.Brk.lay_from = lay, Net.myid
        log("storage breakers: our layout is the team's (%s)", table.concat(lay, ","))
        if Coop.active() then P.Brk.brk_send_layout() end
        return
    end
    local want, used = {}, {}
    for _, n in ipairs(P.Brk.lay) do want[n] = true end
    for _, b in ipairs(mine) do if b.pt and want[b.pt.name] then used[b.pt.name] = true end end
    local pts = {}
    for _, p in ipairs(P.Brk.brk_points()) do pts[p.name] = p end
    for _, b in ipairs(mine) do
        if not (b.pt and want[b.pt.name]) then
            -- not on a team point: move it onto a free one
            for _, n in ipairs(P.Brk.lay) do
                if not used[n] and pts[n] then
                    used[n] = true
                    local p = pts[n]
                    pcall(function() b.a:K2_SetActorLocation({ X = p.x, Y = p.y, Z = p.z }, false, {}, true) end)
                    b.pt = p
                    log("storage breaker moved to the team's spot %s", n)
                    break
                end
            end
        end
    end
    for _, b in ipairs(mine) do
        if b.pt and P.Brk.taken[b.pt.name] then
            local a = b.a
            replaying = replaying + 1
            pcall(function() a:K2_DestroyActor() end)
            replaying = replaying - 1
            log("storage breaker at %s was picked up by a friend: removed", b.pt.name)
        end
    end
end
P.Brk.picked = function(obj)
    -- (the hook runs after the pickup: the breaker already hangs in the hand - use where it lay)
    local name = P.Brk.where[tostring(try(function() return obj:GetAddress() end))]
    if not name then
        local l = try(function() return obj:K2_GetActorLocation() end)
        local pt, d = l and P.Brk.brk_nearest(l)
        if pt and d and d <= P.Brk.NEAR then name = pt.name end
    end
    if not name then return end
    P.Brk.taken[name] = true
    Coop.send_event("brktake", name)
    log("storage breaker picked up at %s: removed for everyone", name)
end
P.Brk.brk_name_ok = function(n) return type(n) == "string" and n:match("^[%w_]+$") ~= nil and #n <= 64 end
Coop.on("brklay", function(from, rest)
    if P.CHAPTER ~= 1 or P.old_progress(from) then return end
    local lay = {}
    for n in tostring(rest or ""):gmatch("[^,]+") do if P.Brk.brk_name_ok(n) then lay[#lay + 1] = n end end
    if #lay == 0 or #lay > 16 then return end
    if P.Brk.lay and P.Brk.lay_from and P.Brk.lay_from >= 0 and P.Brk.lay_from <= from then return end   -- ours / an earlier one wins
    table.sort(lay)
    P.Brk.lay, P.Brk.lay_from, P.Brk.at = lay, from, -100
    log("storage breakers: using player %d's layout (%s)", from, table.concat(lay, ","))
end)
Coop.on("brktake", function(from, n)
    if P.CHAPTER ~= 1 or P.old_progress(from) or not P.Brk.brk_name_ok(n) then return end
    P.Brk.taken[n] = true
    P.Brk.at = -100                        -- apply at the next tick
end)
table.insert(P.Handlers.join, function(id) if P.CHAPTER == 1 then P.Brk.brk_send_layout(id) end end)
table.insert(P.NewGameReset, function() P.Brk.lay, P.Brk.lay_from, P.Brk.taken, P.Brk.where = nil, nil, {}, {} end)
table.insert(P.Handlers.unload, function() P.Brk.where = {} end)
table.insert(P.Handlers.tick, function(dt, have)
    if P.CHAPTER ~= 1 or not have or P.quiet() then return end
    local now = P.game_time()
    if now - P.Brk.at < P.Brk.EVERY then return end
    P.Brk.at = now
    if not P.Brk.storage_loaded() then return end
    -- (moving / removing actors: from the late queue, outside the actor tick)
    if P.late then P.late(function() pcall(P.Brk.brk_apply) end, "storage breakers") else pcall(P.Brk.brk_apply) end
end)
