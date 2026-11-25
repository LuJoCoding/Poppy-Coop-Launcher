-- PoppyCoop - Chapter 5 world sync (state based)
--
-- Chapter 5 runs its world on gameplay tags, set from C++ where UE4SS hooks can't see them. So instead of
-- hooking calls we WATCH the state about once a second and send what changed:
--   * object tags  - every interactive object has a NotifyReceiverComponent; using a lever, valve, hand
--                    scanner, breaker, button... adds "WorldAssets.GameplayEvent.Activated" (and others) to it.
--                    Adding the same tag in the other games makes the object and everything wired to it react
--                    there too (tested: a door opened from a remote AddLocalTag).
--   * game tags    - global progress flags in GameTagsSubsystem (keys picked up, story steps, areas unlocked).
-- Everything that happened is kept in a ledger, so a friend who joins later, reloads a checkpoint or streams
-- an area in again gets the same world state.
local P = _G.PoppyCoop
if not P or P.CHAPTER ~= 5 then return end
local Coop, log, valid, try, Cfg = P.Coop, P.log, P.valid, P.try, P.Config

local function on(v, def) if v == nil then return def end return v == true or v == "true" end
local SYNC_OBJECTS = on(Cfg.sync_activations, true)
local SYNC_GAME = on(Cfg.sync_story, true)
local SYNC_ITEMS = on(Cfg.sync_inventory, true)   -- 1.7.5: picked-up items (keys, notes, tapes, collectibles, hands)
local POLL = 1.0                         -- seconds between state reads
local MAX_SEND = 80                      -- changes sent per read at most (a level load can flip many at once)
local POPUPS = on(Cfg.popups, true)
local BATCH = 12                         -- ledger entries per message for late joiners

-- Only real interactive objects are synced. Triggers that fire when a player walks in (cutscenes, music,
-- teleports, darkness, tutorials) stay local: replaying them would start a cutscene or teleport the
-- other player wherever they are.
local OBJ_WANT = { "handscanner", "valve", "lever", "breaker", "button", "door", "receiver", "keypad", "keycard",
    "elevator", "power", "switch", "moveable", "socket", "panel", "generator", "battery", "fuse", "crank", "wheel",
    "gate", "hatch", "vent", "shutter", "scanner", "reader", "console", "terminal", "conductive", "pole", "jumppad",
    "magnet", "pressure", "plug", "pump", "lift", "bridge", "crane", "lock", "carriable" }
local OBJ_SKIP = { "sequence", "music", "teleport", "duck", "animation_trigger", "tutorial", "darkness", "camera",
    "sound", "streaming", "failsafe", "glowby_", "breakables", "cinematic", "jumpscare", "damagevolume", "notifytrigger",
    "questtrigger", "checkpoint", "character", "huggy", "poppy_", "kissy", "volume" }
local GAME_SKIP = { "^Tutorial%.", "^UI%.", "^Debug%." }

local function wanted_obj(name)
    if not name:find("UAID", 1, true) then return false end      -- placed in the level = same name in every game
    local l = name:lower()
    for _, w in ipairs(OBJ_SKIP) do if l:find(w, 1, true) then return false end end
    for _, w in ipairs(OBJ_WANT) do if l:find(w, 1, true) then return true end end
    return false
end
local function wanted_game(tag)
    for _, p in ipairs(GAME_SKIP) do if tag:find(p) then return false end end
    return true
end

local function short(o)
    local r = try(function() return o:GetFullName() end)
    if not r then return nil end
    return r:match("PersistentLevel%.(.+)$") or r:match("([^%.:%s]+)$")
end
local function tag_list(container)
    local out = {}
    pcall(function() container.GameplayTags:ForEach(function(_, e) out[#out + 1] = e:get().TagName:ToString() end) end)
    return out
end
local function as_set(l) local s = {} for _, v in ipairs(l) do s[v] = true end return s end
local function tagarg(t) return { TagName = FName(t) } end

-- state -------------------------------------------------------------------------------------------------
local Seen = {}       -- object name -> set of its tags at the last read
local Comp = {}       -- object name -> its NotifyReceiverComponent (refreshed every read)
local Want = {}       -- object name -> wanted_obj() (cached)
local GameSeen = nil  -- set of game tags at the last read
local Ledger = {}     -- "L <obj> <tag>" / "G <tag>" -> true (added) / false (removed): the shared world state
local Order = {}      -- ledger keys in the order they first happened (late joiners replay in order)
local stats = { sent = 0, applied = 0, pending = 0 }
local timer = 0

local function remember(key, added)
    if Ledger[key] == nil then Order[#Order + 1] = key end
    Ledger[key] = added
end

-- apply a remote change. Returns true when done (or nothing to do), false when the object isn't loaded yet.
local function apply_obj(obj, tag, added)
    local c = Comp[obj]
    if not valid(c) then return false end
    local has = Seen[obj] and Seen[obj][tag]
    if added and has then return true end
    if not added and not has then return true end
    local ok, err = pcall(function()
        if added then c:AddLocalTag(tagarg(tag)) else c:RemoveLocalTag(tagarg(tag)) end
    end)
    if not ok then log("ch5: %s %s on %s failed: %s", added and "add" or "remove", tag, obj, tostring(err)); return true end
    Seen[obj] = Seen[obj] or {}
    Seen[obj][tag] = added or nil         -- so the next read doesn't send it back
    stats.applied = stats.applied + 1
    return true
end
local function game_subsystem() return try(function() return FindFirstOf("GameTagsSubsystem") end) end
local function apply_game(tag, added)
    local g = game_subsystem()
    if not valid(g) then return false end
    if GameSeen and ((added and GameSeen[tag]) or (not added and not GameSeen[tag])) then return true end
    local ok, err = pcall(function()
        if added then g:GrantGameTag(tagarg(tag)) else g:RevokeGameTag(tagarg(tag)) end
    end)
    if not ok then log("ch5: game tag %s failed: %s", tag, tostring(err)); return true end
    if GameSeen then GameSeen[tag] = added or nil end
    stats.applied = stats.applied + 1
    return true
end

-- items ----------------------------------------------------------------------------------------------------
-- (1.7.5) Picking something up (BP_Item: keys, notes, cassettes, collectibles) only changes the picker's
-- PoppyInventoryManagerComponent - no tag. Without this a key stayed in the friend's world and the friend
-- never got it (locked doors close again by themselves). The inventory is read like the tags: a new item
-- definition is sent as "I <class path>"; the others add it and remove that item from their world.
local ItemsSeen = nil   -- set of item definition paths at the last read (nil = not read yet in this level)
local function inventory()
    local p = try(function() return FindFirstOf("BP_PoppyCharacter_C") end)
    return valid(p) and try(function() return p.PoppyInventoryManagerComponent end) or nil
end
local function item_defs(m)
    local out = {}
    pcall(function()
        local defs = m:GetAllItemDefinitions()
        for i = 1, #defs do pcall(function() out[#out + 1] = defs[i]:get():GetFullName():match("^%S+ (.+)$") end) end
    end)
    return out
end
-- the item lying in this world for that definition: gone (we have it / a friend picked it up)
local function remove_world_item(path)
    for _, a in ipairs(try(function() return FindAllOf("BP_Item_C") end) or {}) do
        pcall(function()
            if a:IsValid() and a.ItemDefinition:GetFullName():match("^%S+ (.+)$") == path then a:K2_DestroyActor() end
        end)
    end
end
local function apply_item(path, added)
    if not added then return true end                  -- used up / dropped: everyone keeps theirs
    local m = inventory()
    if not valid(m) then return false end
    if not (ItemsSeen and ItemsSeen[path]) then
        local d = try(StaticFindObject, path)
        if not valid(d) then return false end          -- (its level isn't loaded yet)
        local has = try(function() return m:ContainsItemDefinition(d) end)
        if not has then
            local ok, err = pcall(function() m:AddItemByDefinition(d) end)
            if not ok then log("ch5: item %s failed: %s", path, tostring(err)); return true end
            log("ch5: friend's item %s added", path:match("([^%.]+)$") or path)
        end
        if ItemsSeen then ItemsSeen[path] = true end   -- so the next read doesn't send it back
        stats.applied = stats.applied + 1
    end
    remove_world_item(path)
    return true
end

-- popups ---------------------------------------------------------------------------------------------------
-- "BP_HandScanner_C_UAID_74563CBB8A33578A02_1074243720" -> "hand scanner"
local function kind_of(obj)
    local k = obj:gsub("_C_UAID.*$", ""):gsub("^BP_", ""):gsub("_C$", "")
    k = k:gsub("PivotLockedMoveable_", ""):gsub("_?Variant$", ""):gsub("_", " ")
    k = k:gsub("(%l)(%u)", "%1 %2"):lower():gsub("^base ", "")
    return k
end
local function pretty_tag(t)
    local last = t:match("([^%.]+)$") or t
    return (last:gsub("(%l)(%u)", "%1 %2"):gsub("_", " "))
end
local LastPopup = {}
local function popup_from(from, text)
    if not POPUPS or not P.popup then return end
    local now = os.clock()
    if (LastPopup[from] or -10) + 3 > now then return end      -- one per friend every 3 s
    LastPopup[from] = now
    local who = "A friend"
    pcall(function() local pl = P.Net.players[from]; if pl and pl.name then who = pl.name end end)
    pcall(P.popup, who .. " " .. text)
end
local function popup_for(from, e)
    local sign, kind, rest = e:match("^([%+%-])([LGI]) (.+)$")
    if sign ~= "+" then return end
    if kind == "L" then
        local obj, tag = rest:match("^(%S+) (%S+)$")
        if obj and tag == "WorldAssets.GameplayEvent.Activated" then popup_from(from, "used a " .. kind_of(obj)) end
    elseif rest:find("^Inventory%.Items%.") then
        popup_from(from, "found " .. pretty_tag(rest))
    elseif kind == "I" then
        local n = rest:match("ID_([%w_]+)_C$") or rest:match("([^%.]+)$") or rest
        n = n:gsub("_Level%d+", ""):gsub("^Notes_", "note "):gsub("^Key_", "key "):gsub("^Cassette_", "tape "):gsub("^Collectible_", "")
        popup_from(from, "found " .. pretty_tag(n))
    end
end

-- network --------------------------------------------------------------------------------------------------
-- "c5" payload: entries "+L obj tag" / "-L obj tag" / "+G tag" / "-G tag" separated by ";"
local Pending = {}    -- entries whose object isn't loaded in our game yet
local function entry_of(key, added) return (added and "+" or "-") .. key end
local function handle_entry(e)
    local sign, kind, rest = e:match("^([%+%-])([LGI]) (.+)$")
    if not sign then return true end
    local added = sign == "+"
    if kind == "I" then
        if not SYNC_ITEMS or not rest:match("^/[%w_/%.%-]+$") then return true end
        remember("I " .. rest, added)
        return apply_item(rest, added)
    end
    if kind == "G" then
        if not SYNC_GAME or not wanted_game(rest) then return true end
        remember("G " .. rest, added)
        return apply_game(rest, added)
    end
    local obj, tag = rest:match("^(%S+) (%S+)$")
    if not obj or not SYNC_OBJECTS then return true end
    remember("L " .. obj .. " " .. tag, added)
    return apply_obj(obj, tag, added)
end
Coop.on("c5", function(from, payload)
    local live = not tostring(payload or ""):find("^!")      -- "!" = catch-up for a late joiner: no popups
    for e in tostring(payload or ""):gsub("^!", ""):gmatch("[^;]+") do
        if live then popup_for(from, e) end
        if not handle_entry(e) then Pending[#Pending + 1] = e end
    end
end)
local Outbox = {}
local function send(key, added)
    remember(key, added)
    Outbox[#Outbox + 1] = entry_of(key, added)
end
local function flush()
    if #Outbox == 0 or not Coop.active() then Outbox = {}; return end
    if #Outbox > MAX_SEND then
        log("ch5: %d changes at once - sending the first %d (the ledger catches up the rest on join)", #Outbox, MAX_SEND)
        for i = #Outbox, MAX_SEND + 1, -1 do Outbox[i] = nil end
    end
    for i = 1, #Outbox, BATCH do
        Coop.send_event("c5", table.concat(Outbox, ";", i, math.min(#Outbox, i + BATCH - 1)))
    end
    stats.sent = stats.sent + #Outbox
    Outbox = {}
end
-- a friend joins: tell them everything that happened so far (in order)
table.insert(P.Handlers.join, function(id)
    local batch = {}
    for _, key in ipairs(Order) do
        batch[#batch + 1] = entry_of(key, Ledger[key])
        if #batch >= BATCH then Coop.send_to(id, "c5", "!" .. table.concat(batch, ";")); batch = {} end
    end
    if #batch > 0 then Coop.send_to(id, "c5", "!" .. table.concat(batch, ";")) end
    if #Order > 0 then log("ch5: sent %d world changes to player %d", #Order, id) end
end)

-- watching --------------------------------------------------------------------------------------------------
local NameAt = {}     -- component address -> owner name ("" = not wanted); cleared on every level load
local LastCount = -1
local function read_objects()
    Comp = {}
    local all = try(function() return FindAllOf("NotifyReceiverComponent") end) or {}
    -- areas stream in and out without a level load: a freed address can come back as another object, so the
    -- name cache is rebuilt whenever the set of components changes size
    if #all ~= LastCount then NameAt = {}; LastCount = #all end
    for _, c in ipairs(all) do
        if valid(c) then
            local addr = try(function() return c:GetAddress() end)
            local name = addr and NameAt[addr]
            if name == nil then
                local own = try(function() return c:GetOwner() end)
                name = valid(own) and short(own) or false
                if name and Want[name] == nil then Want[name] = wanted_obj(name) end
                if name and not Want[name] then name = "" end
                if addr and name ~= false then NameAt[addr] = name end
            end
            if name and name ~= "" then
                if Want[name] then
                    Comp[name] = c
                    local now = as_set(tag_list(c.LocalTags))
                    local old = Seen[name]
                    if old == nil then
                        -- first time we see it (level streamed in / reloaded): bring it to the shared state
                        Seen[name] = now
                        for key, added in pairs(Ledger) do
                            local o, t = key:match("^L (%S+) (%S+)$")
                            if o == name then apply_obj(o, t, added) end
                        end
                    else
                        for t in pairs(now) do if not old[t] then send("L " .. name .. " " .. t, true) end end
                        for t in pairs(old) do if not now[t] then send("L " .. name .. " " .. t, false) end end
                        Seen[name] = now
                    end
                end
            end
        end
    end
end
local function read_game()
    local g = game_subsystem()
    if not valid(g) then return end
    local list = {}
    pcall(function() g.GameTagsArray:ForEach(function(_, e) list[#list + 1] = e:get().TagName:ToString() end) end)
    if #list == 0 then list = tag_list(g.GameTags) end
    local now = as_set(list)
    if GameSeen == nil then
        GameSeen = now
        for key, added in pairs(Ledger) do
            local t = key:match("^G (%S+)$")
            if t then apply_game(t, added) end
        end
        return
    end
    for t in pairs(now) do if not GameSeen[t] and wanted_game(t) then send("G " .. t, true) end end
    for t in pairs(GameSeen) do if not now[t] and wanted_game(t) then send("G " .. t, false) end end
    GameSeen = now
end

local function read_items()
    local m = inventory()
    if not valid(m) then return end
    local now = as_set(item_defs(m))
    if ItemsSeen == nil then
        -- first read in this level: what we have is shared too (a friend may not have it), and what the
        -- team has goes into our inventory
        ItemsSeen = now
        for path in pairs(now) do if Ledger["I " .. path] == nil then send("I " .. path, true) end end
        for key, added in pairs(Ledger) do
            local path = key:match("^I (.+)$")
            if path and added then apply_item(path, true) end
        end
        return
    end
    for path in pairs(now) do
        if not ItemsSeen[path] then send("I " .. path, true); remove_world_item(path) end
    end
    ItemsSeen = now
end

table.insert(P.Handlers.tick, function(dt, have)
    if not have then return end
    timer = timer + (dt or 0)
    if timer < POLL then return end
    timer = 0
    if P.crumb then P.crumb("ch5: read") end
    if SYNC_OBJECTS then read_objects() end
    if SYNC_GAME then read_game() end
    if SYNC_ITEMS then read_items() end
    if #Pending > 0 then
        local still = {}
        for _, e in ipairs(Pending) do if not handle_entry(e) then still[#still + 1] = e end end
        Pending = still
    end
    stats.pending = #Pending
    flush()
end)
-- level loaded / respawned: every object is new again (it gets the shared state when it's seen)
table.insert(P.Handlers.restart, function() Seen = {}; Comp = {}; GameSeen = nil; NameAt = {}; ItemsSeen = nil end)

-- GrabPack hands on the friends' figures -----------------------------------------------------------------------
-- The jointed figure (main.lua, m1) ends its arms in round fists. In Chapter 5 those are swapped for the game's
-- own GrabPack hand (the mesh the player sees in first person): blue on the left, red on the right. The hand
-- sits on the fist and points along the forearm (elbow -> fist). The mesh's own axes aren't known here, so
-- the extra rotation/scale are kept in P.H5 and can be tuned live (developer exec: P.H5.yaw = 90 ...).
local UEHelpers = require("UEHelpers")
local H5 = { on = on(Cfg.ch5_hands, true), scale = 1.0, pitch = 0, yaw = -90, roll = 0, fwd = 2 }
P.H5 = H5
local HA = { mesh = "/PoppyCore/PoppyGrabPack/Hands/Meshes/SK_GrabpackHand.SK_GrabpackHand",
             ska = "/Script/Engine.SkeletalMeshActor",
             L = "/PoppyCore/PoppyGrabPack/Hands/MaterialInstances/MI_BaseHandBlue.MI_BaseHandBlue",
             R = "/Game/ch5_pro/Characters/GrabpackHands/MaterialInstances/MI_BaseHandRedOld.MI_BaseHandRedOld" }
local HAsset, hand_next = {}, 0
local function hand_assets()
    if HAsset.ok then return true end
    if os.clock() < hand_next then return false end
    hand_next = os.clock() + 3
    for k, path in pairs(HA) do
        if not valid(HAsset[k]) then HAsset[k] = try(StaticFindObject, path) end
    end
    HAsset.ok = valid(HAsset.mesh) and valid(HAsset.ska)
    if HAsset.ok then log("ch5: GrabPack hands for the figures (red material %s)", valid(HAsset.R) and "found" or "missing") end
    return HAsset.ok
end
local function spawn_hand(p, side, at)
    local world = UEHelpers.GetWorld()
    if not valid(world) then return nil end
    local a = try(function() return world:SpawnActor(HAsset.ska, { X = at.X, Y = at.Y, Z = at.Z }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not valid(a) then return nil end
    pcall(function() a:SetActorEnableCollision(false) end)
    pcall(function()
        local c = a.SkeletalMeshComponent
        if not pcall(function() c:SetSkeletalMeshAsset(HAsset.mesh) end) then c:SetSkeletalMesh(HAsset.mesh, true) end
        c:SetCollisionEnabled(0)
        c.CastShadow = false
    end)
    local mat = HAsset[side] or HAsset.L
    if valid(mat) then pcall(function() a.SkeletalMeshComponent:SetMaterial(0, mat) end) end
    -- in the figure's parts, so it is destroyed together with the figure
    local n = 0
    for k in pairs(p.parts) do n = math.max(n, k) end
    p.parts[n + 1] = a
    p.paths = p.paths or {}
    p.paths[n + 1] = try(function() return a:GetFullName():match("^%S+ (.+)$") end)
    return a
end
local function loc_of(a) return try(function() return a:K2_GetActorLocation() end) end
local function hands_tick()
    for _, p in pairs(P.Puppets or {}) do
        if p.m1 and p.parts then
            if not p.h5 and hand_assets() then
                p.h5 = {}
                for _, side in ipairs({ "L", "R" }) do
                    local fist = p.parts[p.m1["fist" .. side]]
                    local at = valid(fist) and loc_of(fist)
                    if at then
                        p.h5[side] = spawn_hand(p, side, at)
                        if p.h5[side] then pcall(function() fist:SetActorHiddenInGame(true) end) end
                    end
                end
            end
            for side, hand in pairs(p.h5 or {}) do
                local fist, elbow = p.parts[p.m1["fist" .. side]], p.parts[p.m1["elbow" .. side]]
                local f, e = valid(hand) and valid(fist) and loc_of(fist), valid(elbow) and loc_of(elbow)
                if f and e then
                    local dx, dy, dz = f.X - e.X, f.Y - e.Y, f.Z - e.Z
                    local len = math.max(0.001, math.sqrt(dx * dx + dy * dy + dz * dz))
                    local yaw = math.deg(math.atan(dy, dx))
                    local pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
                    pcall(function()
                        hand:K2_SetActorLocationAndRotation(
                            { X = f.X + dx / len * H5.fwd, Y = f.Y + dy / len * H5.fwd, Z = f.Z + dz / len * H5.fwd },
                            { Pitch = pitch + H5.pitch, Yaw = yaw + H5.yaw, Roll = (side == "L" and H5.roll or -H5.roll) }, false, {}, true)
                    end)
                    if p.h5scale ~= H5.scale then
                        pcall(function() hand:SetActorScale3D({ X = H5.scale, Y = H5.scale, Z = H5.scale }) end)
                    end
                end
            end
            if p.h5 then p.h5scale = H5.scale end
        end
    end
end
if H5.on then
    table.insert(P.Handlers.tick, function(dt, have)
        if not have or not next(P.Puppets or {}) then return end
        if P.crumb then P.crumb("ch5: hands") end
        hands_tick()
    end)
end

log("Chapter 5 world sync loaded (objects=%s story=%s items=%s)", tostring(SYNC_OBJECTS), tostring(SYNC_GAME), tostring(SYNC_ITEMS))
