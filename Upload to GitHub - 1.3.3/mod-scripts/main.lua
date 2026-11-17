--[[
  PoppyCoop - co-op multiplayer for Poppy Playtime Chapter 1 (UE 5.2, UE4SS 3.x)
  =============================================================================
  Architecture
    * Every player runs their own normal copy of the game.
    * PoppyCoopNet.exe (next to this mod) does all networking (UDP, reliable
      events, host relay). This script talks to it through two named pipes.
    * This script: sends the local player's state, draws other players as
      puppets, and (later modules) mirrors gameplay events.

  Config: Mods/PoppyCoop/config.txt   (mode=host|join|off, host_ip, port, name)
  Console (F10):  coop_status | coop_host [name] | coop_join <ip[:port]> [name] | coop_off
]]

local VERSION = "1.3.3"   -- 1.3.3: merge - keybinds.txt (F6 teleport), dev tools/perf log opt-in, 3+ players, public-room safety, hand fixes
local UEHelpers = require("UEHelpers")

-- Crash fix (2026-11-16): UE4SS's UEHelpers caches the PlayerController across level loads and then calls
-- IsValid() on the freed object (crash at UE4SS.dll+0x67881f, ~1 in 5 checkpoint reloads). Keep only
-- objects that live for the whole game (GameplayStatics CDO, GameInstance) and ask for the rest fresh.
local SafeUE = { gs = nil, gi = nil }
function SafeUE.gameplay_statics()
    if not SafeUE.gs then
        local ok, o = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
        if ok and o and o:IsValid() then SafeUE.gs = o end
    end
    return SafeUE.gs
end
function SafeUE.game_instance()
    if SafeUE.gi then return SafeUE.gi end
    local gs = SafeUE.gameplay_statics()
    if not gs then return nil end
    local ok, gi = pcall(function()
        local pc = FindFirstOf("PlayerController")          -- fresh, used only right now
        if not (pc and pc:IsValid()) then return nil end
        return gs:GetGameInstance(pc)
    end)
    if ok and gi and gi:IsValid() then SafeUE.gi = gi end
    return SafeUE.gi
end
function SafeUE.player_controller()                      -- never cache the result
    local gs, gi = SafeUE.gameplay_statics(), SafeUE.game_instance()
    if not (gs and gi) then return nil end
    local ok, pc = pcall(function() return gs:GetPlayerController(gi, 0) end)
    if ok and pc and pc:IsValid() then return pc end
    return nil
end
function SafeUE.world()
    local pc = SafeUE.player_controller()
    if not pc then return nil end
    local ok, w = pcall(function() return pc:GetWorld() end)
    if ok and w and w:IsValid() then return w end
    return nil
end
UEHelpers.GetPlayerController = SafeUE.player_controller   -- also used by coop_world / coop_extra (same Lua state)
UEHelpers.GetWorld = SafeUE.world
UEHelpers.GetWorldContextObject = SafeUE.player_controller

------------------------------------------------------------------------ util
local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print("[PoppyCoop] " .. (ok and s or tostring(fmt)) .. "\n")
end
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end
local function try(f, ...)
    local ok, r = pcall(f, ...)
    if not ok then return nil, r end
    return r
end

---------------------------------------------------------------------- paths
local MOD_DIR
for _, cand in ipairs({ "ue4ss\\Mods\\PoppyCoop", "Mods\\PoppyCoop", "..\\Mods\\PoppyCoop" }) do
    local f = io.open(cand .. "\\Scripts\\main.lua", "r")
    if f then f:close(); MOD_DIR = cand; break end
end
MOD_DIR = MOD_DIR or "ue4ss\\Mods\\PoppyCoop"

--------------------------------------------------------------------- config
local Config = { mode = "off", host_ip = "127.0.0.1", port = 27777, name = "Player", room = "public", autostart_helper = true,
                 send_hz = 20, color = "yellow" }

-- Normalize a server/relay address. Returns the address to use, or nil if it is unusable.
--   "wss://host/..." -> unchanged      "wss:host" / "wss:/host" -> "wss://host"   (repairs mangled input)
--   "host.workers.dev" -> "wss://host.workers.dev"   (the F10 console drops everything after "//")
--   "1.2.3.4" / "example.com" -> unchanged (plain UDP host)       "wss:" / "wss" -> nil
local function normalize_server(s)
    s = tostring(s or ""):match("^%s*(.-)%s*$")
    if s == "" then return nil end
    local scheme, rest = s:match("^(wss?):/*(.*)$")
    if scheme then
        if rest == "" then return nil end
        return scheme .. "://" .. rest
    end
    if s == "ws" or s == "wss" then return nil end
    if s:lower():match("%.workers%.dev/?$") or s:lower():match("%.workers%.dev/") then return "wss://" .. s end
    return s
end
local function is_relay(s) return tostring(s or ""):match("^wss?://") ~= nil end

local function load_config()
    local f = io.open(MOD_DIR .. "\\config.txt", "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and not line:match("^%s*#") then
            if v == "true" then v = true elseif v == "false" then v = false
            elseif tonumber(v) then v = tonumber(v) end
            Config[k] = v
        end
    end
    f:close()
    -- test launchers can give each game window its own identity (several games share one config.txt)
    for k, env in pairs({ name = "POPPYCOOP_NAME", room = "POPPYCOOP_ROOM", color = "POPPYCOOP_COLOR" }) do
        local v = os and os.getenv and os.getenv(env)
        if v and v ~= "" then Config[k] = v end
    end
    Config.name = tostring(Config.name):gsub("[^%w_%-]", "_"):sub(1, 24)
    local hs = normalize_server(Config.host_ip)
    if hs then Config.host_ip = hs
    else print("[PoppyCoop] config.txt host_ip '" .. tostring(Config.host_ip) .. "' is not a usable address\n") end
end

local function save_config()
    local f = io.open(MOD_DIR .. "\\config.txt", "w")
    if not f then return end
    f:write("# PoppyCoop config. mode = host | join | off\n")
    for _, k in ipairs({ "mode", "name", "host_ip", "port", "room", "autostart_helper", "send_hz", "color" }) do
        f:write(("%s=%s\n"):format(k, tostring(Config[k])))
    end
    f:close()
end

-------------------------------------------------------------------- network
local Net = {
    up = nil, down = nil, connected = false, launched_at = -100, last_try = -100,
    myid = -1, status = "offline", npeers = 0, rtt = -1,
    outbox = {},          -- reliable lines queued for next poll
    players = {},         -- [id] = { name=, state=, ... }
}

-- Unique per running game: two copies on one PC (even with the same player name) must never share a
-- helper pipe. tostring({}) is a memory address, different in every process.
local INSTANCE = (tostring({}):match("0x(%x+)") or tostring(os.time())):sub(-8) .. tostring(math.floor((os.clock() * 1000) % 1000))
local function pipe_base()
    return ("poppycoop_%s_%s"):format(Config.mode, INSTANCE)
end

local function net_close()
    if Net.up then pcall(function() Net.up:close() end) end
    if Net.down then pcall(function() Net.down:close() end) end
    Net.up, Net.down, Net.connected = nil, nil, false
end

-- Which chapter is this? Chapter 2's project folder is "Playtime_Prototype4" (Chapter 1: "Poppy_Playtime").
-- Rooms are kept per chapter, so "public" in Chapter 2 never mixes with "public" in Chapter 1.
-- (UE4SS runs with the game's Win64 folder as working directory, so look for the game exe there)
local function file_exists(f) local h = io.open(f, "rb"); if h then h:close(); return true end; return false end
local CHAPTER = (MOD_DIR:lower():find("playtime_prototype4", 1, true) or file_exists("Playtime_Prototype4-Win64-Shipping.exe")) and 2 or 1
if os.getenv and tonumber(os.getenv("POPPYCOOP_CHAPTER") or "") then CHAPTER = tonumber(os.getenv("POPPYCOOP_CHAPTER")) end   -- testing
local function wire_room()
    local r = (tostring(Config.room):gsub("[^%w_%-]", "_"))
    return CHAPTER == 1 and r or ("c" .. CHAPTER .. "-" .. r)
end

local function launch_helper()
    local exe = MOD_DIR .. "\\PoppyCoopNet.exe"
    local f = io.open(exe, "rb")
    if not f then log("helper missing: %s", exe); return end
    f:close()
    local role = Config.mode == "host" and ("--host %d"):format(Config.port)
        or (is_relay(Config.host_ip) and ("--join %s --room %s"):format(Config.host_ip, wire_room())
            or ("--join %s:%d --room %s"):format(Config.host_ip, Config.port, wire_room()))
    -- separate log per test window when several games share this folder (see POPPYCOOP_NAME)
    local tag = (os.getenv and os.getenv("POPPYCOOP_NAME")) and ("_" .. tostring(Config.name):gsub("[^%w_%-]", "_")) or ""
    local cmd = ('start "" /B "%s" %s --name %s --pipe %s --log "%s\\net_%s%s.log"'):format(
        exe, role, Config.name, pipe_base(), MOD_DIR, Config.mode, tag)
    if not os or not os.execute then log("os.execute unavailable; start the helper manually"); return end
    log("launching helper: %s", cmd)
    os.execute(cmd)
end

local clock = os.clock  -- replaced by game time once ticking
local game_time = 0

local function net_try_connect()
    if Net.connected or Config.mode == "off" then return end
    if game_time - Net.last_try < 1.0 then return end
    Net.last_try = game_time
    local base = "\\\\.\\pipe\\" .. pipe_base()
    local up = io.open(base .. "_up", "wb")
    if not up then
        if Config.autostart_helper and game_time - Net.launched_at > 8 then
            Net.launched_at = game_time
            launch_helper()
        end
        return
    end
    local down = io.open(base .. "_down", "rb")
    if not down then up:close(); return end
    Net.up, Net.down, Net.connected = up, down, true
    Net.players = {}
    log("connected to helper (%s)", pipe_base())
end

local Handlers = { event = {}, join = {}, leave = {}, tick = {}, restart = {}, unload = {}, state = {} }   -- module hooks

local function on_line(line)
    local k = line:sub(1, 1)
    if k == "I" then
        local id, st, np, rtt = line:match("^I (%-?%d+) (%S+) (%d+) (%-?%d+)")
        Net.myid, Net.status, Net.npeers, Net.rtt = tonumber(id), st, tonumber(np), tonumber(rtt)
    elseif k == "S" then
        local id, payload = line:match("^S (%d+) (.*)$")
        id = tonumber(id)
        if id then
            local p = Net.players[id] or { name = "P" .. id }
            Net.players[id] = p
            p.state, p.state_time = payload, game_time
        end
    elseif k == "R" then
        local id, payload = line:match("^R (%d+) (.*)$")
        id = tonumber(id)
        local kind, rest = payload:match("^(%S+)%s?(.*)$")
        local h = kind and Handlers.event[kind]
        if h then
            local ok, err = pcall(h, id, rest)
            if not ok then log("event %s failed: %s", kind, tostring(err)) end
        end
    elseif k == "J" then
        local id, name = line:match("^J (%d+) (.*)$")
        id = tonumber(id)
        Net.players[id] = Net.players[id] or {}
        Net.players[id].name = name
        log("%s joined (id %d)", name, id)
        for _, h in ipairs(Handlers.join) do pcall(h, id, name) end
    elseif k == "L" then
        local id = tonumber(line:match("^L (%d+)"))
        local p = Net.players[id]
        log("%s left", p and p.name or tostring(id))
        for _, h in ipairs(Handlers.leave) do pcall(h, id) end
        Net.players[id] = nil
    end
end

-- One synchronous round trip with the helper. state_line may be nil.
local function net_poll(state_line)
    if not Net.connected then return end
    local ok, err = pcall(function()
        if state_line then Net.up:write("S ", state_line, "\n") end
        for i = 1, #Net.outbox do Net.up:write(Net.outbox[i], "\n") end
        Net.outbox = {}
        Net.up:write("POLL\n")
        Net.up:flush()
        for _ = 1, 10000 do
            local line = Net.down:read("l")
            if line == nil then error("helper closed pipe") end
            if line == "." then break end
            on_line(line)
        end
    end)
    if not ok then
        log("helper link lost: %s", tostring(err))
        net_close()
        for id in pairs(Net.players) do for _, h in ipairs(Handlers.leave) do pcall(h, id) end end
        Net.players = {}
    end
end

-- public API for other modules
local Coop = {}
function Coop.send_event(kind, payload) Net.outbox[#Net.outbox + 1] = "R " .. kind .. (payload and (" " .. payload) or "") end
function Coop.send_to(id, kind, payload) Net.outbox[#Net.outbox + 1] = ("D %d %s %s"):format(id, kind, payload or "") end
function Coop.on(kind, fn) Handlers.event[kind] = fn end
-- The "lead" (sends world history to late joiners): the host in host mode, or on a dedicated server
-- the lowest player id in the room (the first to join; the next one takes over if they leave).
function Coop.is_host()
    if Config.mode == "host" then return true end
    if Net.myid < 0 then return false end
    for id in pairs(Net.players) do if id < Net.myid then return false end end
    return true
end
function Coop.active() return Net.connected and Net.myid >= 0 end

------------------------------------------------------------------- game side
local Game = { pc = nil, pawn = nil, map = "?", world = nil }

local function refresh_player()
    local pc = SafeUE.player_controller()                -- fresh every time (crash fix)
    Game.pc = pc
    if not pc then Game.pawn = nil; return false end
    local pawn = try(function() return pc.Pawn end)
    Game.pawn = valid(pawn) and pawn or nil
    local full = try(function() return pc:GetFullName() end) or ""
    Game.map = full:match("/Game/[%w_/]-/([%w_]+)%.[%w_]+:") or full:match("/Game/([%w_]+)%.") or "?"
    return Game.pawn ~= nil
end

local SenderCaps = {}
-- GrabPack hands are native GrabpackHand actors (HandSlot 0 = Left/blue, 1 = Right/red).
-- While a hand is launched it flies away from the player; we send its world position so other
-- players see the hand shoot out on a cable. Found once (then every few seconds), owner-checked,
-- and switched off for the session after any engine error (errors leak Lua C stack).
local HandScan = { at = -100, list = {}, off = false, logged = false }
local function owned_by(a, pawn_addr)
    local o = a
    for _ = 1, 4 do
        local ok, nxt = pcall(function() return o:GetOwner() end)
        if not ok or not valid(nxt) then return false end
        if nxt:GetAddress() == pawn_addr then return true end
        o = nxt
    end
    return false
end
local function scan_hands(pawn)
    HandScan.at = game_time
    HandScan.list = {}
    local all = try(function() return FindAllOf("GrabpackHand") end) or {}
    local pa = try(function() return pawn:GetAddress() end)
    local mine, other = {}, {}
    for _, h in ipairs(all) do
        if valid(h) then
            local slot = try(function() return h.HandSlot end)
            if type(slot) == "number" and (slot == 0 or slot == 1) then
                if pa and owned_by(h, pa) then mine[#mine + 1] = { a = h, slot = slot }
                else other[#other + 1] = { a = h, slot = slot } end
            end
        end
    end
    -- if ownership can't be read, fall back to "the player's hands are the ones nearest the player"
    HandScan.list = #mine > 0 and mine or other
    HandScan.owned = #mine > 0
    if not HandScan.logged and #all > 0 then
        HandScan.logged = true
        log("grabpack hands: %d found, %d owned by you%s", #all, #mine, #mine == 0 and " (using nearest)" or "")
    end
end
local CH2_HANDS = { { tag = "L", ext = "Extended Hand L", obj = "Extendo Hand L" },
                    { tag = "R", ext = "Extended HandR", obj = "Extendo Hand R" } }
local function hand_tokens_ch2(pawn, loc)
    local out = ""
    for _, h in ipairs(CH2_HANDS) do
        local a = try(function() return pawn[h.obj] end)
        if a and valid(a) then
            -- the ExtendoHand actor stays at the launcher; its "Hand Pivot" component is what flies
            local hl = try(function() return a["Hand Pivot"]:K2_GetComponentLocation() end)
                or try(function() return a.Palm:K2_GetComponentLocation() end)
            if hl then
                local dx, dy, dz = hl.X - loc.X, hl.Y - loc.Y, hl.Z - loc.Z
                local d2 = dx * dx + dy * dy + dz * dz
                -- the ExtendoHand actor only exists while the hand is out: send it from the first frame
                if d2 > 20 * 20 and d2 < 4000 * 4000 then
                    out = out .. (" %s=%.0f,%.0f,%.0f"):format(h.tag, hl.X, hl.Y, hl.Z)
                end
            end
        end
    end
    return out
end
local function hand_tokens(pawn, loc)
    if CHAPTER == 2 then
        local ok, s = pcall(hand_tokens_ch2, pawn, loc)
        return ok and s or ""
    end
    if HandScan.off then return "" end
    if game_time - HandScan.at > 3 then scan_hands(pawn) end
    local best = {}
    local ok, err = pcall(function()
        for _, e in ipairs(HandScan.list) do
            if e.a:IsValid() then
                local hl = e.a:K2_GetActorLocation()
                local dx, dy, dz = hl.X - loc.X, hl.Y - loc.Y, hl.Z - loc.Z
                local d2 = dx * dx + dy * dy + dz * dz
                if not best[e.slot] or (not HandScan.owned and d2 < best[e.slot].d2) then
                    best[e.slot] = { d2 = d2, x = hl.X, y = hl.Y, z = hl.Z }
                end
            end
        end
    end)
    if not ok then HandScan.off = true; log("grabpack hand sync disabled: %s", tostring(err)); return "" end
    local out = ""
    for slot, tag in pairs({ [0] = "L", [1] = "R" }) do
        local b = best[slot]
        -- resting hands sit ~0.5-1 m from the capsule; anything further is launched (max reach ~20 m)
        if b and b.d2 > 170 * 170 and b.d2 < 2500 * 2500 then
            out = out .. (" %s=%.0f,%.0f,%.0f"):format(tag, b.x, b.y, b.z)
        end
    end
    return out
end

-- modules (e.g. coop_extra's motion sync) may append their own tokens to the state line
local function extra_tokens()
    local out = ""
    for _, f in ipairs(Handlers.state) do
        local ok, s = pcall(f)
        if ok and type(s) == "string" then out = out .. s end
    end
    return out
end

local function local_state()
    local pawn = Game.pawn
    local loc = pawn:K2_GetActorLocation()
    local rot = try(function() return Game.pc:GetControlRotation() end) or pawn:K2_GetActorRotation()
    local flags = 0
    -- only a real boolean true counts: a property this chapter doesn't have comes back as an
    -- (invalid) object, which Lua treats as true (Chapter 2 puppets were always crouching)
    local function yes(name) return try(function() return pawn[name] end) == true end
    if yes("IsCrouching") or yes("Wants To Crouch?") or yes("bIsCrouched") then flags = flags | 1 end
    if yes("IsSprinting") or yes("Wants to Run?") then flags = flags | 2 end
    if yes("Flashlight On?") or yes("FlashlightOn") then flags = flags | 4 end
    if CHAPTER == 2 and try(function() return pawn["CurrentRight Extendo Hand"] end) == 1 then flags = flags | 32 end   -- green hand
    if Game.dead then flags = flags | 16 end
    -- airborne + capsule height: probed once; disabled for the session if the engine rejects it
    -- (engine-side errors leak Lua C stack, so never retry a failing call every frame)
    local z = loc.Z
    if SenderCaps.ok ~= false then
        local ok, falling, hh = pcall(function()
            return pawn.CharacterMovement:IsFalling(), pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
        end)
        if ok and type(hh) == "number" then
            SenderCaps.ok = true
            if falling then flags = flags | 8 end
            z = loc.Z - hh + 88          -- normalise: always "standing capsule centre" above the feet
        else
            SenderCaps.ok = false
            log("jump/crouch height detection unavailable: %s", tostring(falling))
        end
    end
    -- trailing token = body colour picked in the launcher (older versions simply ignore it)
    local colour = tostring(Config.color or "yellow"):lower():match("^%a+$") or "yellow"
    return ("%.1f %.1f %.1f %.1f %.1f %d %s %s"):format(loc.X, loc.Y, z, rot.Yaw, rot.Pitch, flags, Game.map, colour)
        .. hand_tokens(pawn, loc) .. extra_tokens()
end

-------------------------------------------------------------------- puppets
local Puppets = {}   -- [id] = { body, head, tag, cur = {x,y,z,yaw}, tgt = {...} }
local Assets = {}

-- LoadAsset is only allowed on UE4SS's game-thread queue (calling it from our tick hook raises an
-- engine error, and every engine error leaks Lua C stack until the game crashes). So loading is
-- requested here, at most once per path per session, and the caller looks again a moment later.
local AssetRequested = {}
local function load_async(path)
    if not path or AssetRequested[path] or not LoadAsset or not ExecuteInGameThread then return end
    AssetRequested[path] = true
    pcall(ExecuteInGameThread, function() pcall(LoadAsset, path) end)
end
local function find_asset(path)
    local o = try(StaticFindObject, path)
    if valid(o) then return o end
    if not path:find("^/Script/") then load_async(path) end
    return nil
end

local function resolve_assets()
    if Assets.done then return end
    Assets.smactor = find_asset("/Script/Engine.StaticMeshActor")
    Assets.textactor = find_asset("/Script/Engine.TextRenderActor")
    Assets.body = find_asset("/Engine/BasicShapes/Cylinder.Cylinder")
    Assets.head = find_asset("/Engine/BasicShapes/Sphere.Sphere")
    Assets.cube = find_asset("/Engine/BasicShapes/Cube.Cube")
    if not Assets.body and Game.pawn then
        -- fall back to borrowing the GrabPack hand mesh from our own player
        local m = try(function() return Game.pawn["Right Gun Mesh"].StaticMesh end)
        if valid(m) then Assets.body = m end
    end
    Assets.head = Assets.head or Assets.body
    -- shapes not loaded yet: a load was requested; look again on the next spawn
    Assets.done = valid(Assets.smactor) and valid(Assets.body) and valid(Assets.cube) or false
    log("assets: actor=%s text=%s body=%s head=%s", tostring(valid(Assets.smactor)), tostring(valid(Assets.textactor)),
        tostring(valid(Assets.body)), tostring(valid(Assets.head)))
end

local function spawn_mesh(mesh, x, y, z, sx, sy, sz)
    local world = UEHelpers.GetWorld()
    if not valid(world) or not Assets.smactor then return nil end
    local a = try(function() return world:SpawnActor(Assets.smactor, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not valid(a) then return nil end
    pcall(function()
        local c = a.StaticMeshComponent
        c:SetMobility(2)
        if mesh then c:SetStaticMesh(mesh) end
        c:SetCollisionEnabled(0)
        c:SetCastShadow(true)
    end)
    pcall(function() a:SetActorEnableCollision(false) end)
    pcall(function() a:SetActorScale3D({ X = sx, Y = sy, Z = sz }) end)
    return a
end

local function spawn_tag(name, x, y, z)
    local world = UEHelpers.GetWorld()
    if not Assets.textactor or not valid(world) then return nil end
    local a = try(function() return world:SpawnActor(Assets.textactor, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not valid(a) then return nil end
    pcall(function()
        local t = a.TextRender
        t:SetHorizontalAlignment(1)
        t:SetWorldSize(18)
        t:SetTextRenderColor({ R = 255, G = 220, B = 40, A = 255 })
        if FText then t:K2_SetText(FText(name)) end
    end)
    pcall(function() a:SetActorEnableCollision(false) end)
    return a
end

-- GrabPack toy figure, built from engine shapes. Offsets in cm from the capsule centre
-- (x forward, y right, z up; feet at about -88). shape: c=cylinder s=sphere b=box
local YEL, TEAL, RED, BLUE, BROWN = "yellow", "teal", "red", "blue", "brown"
local TARGET_RGB = { yellow = { 1, 0.78, 0.05 }, teal = { 0.1, 0.5, 0.55 }, red = { 0.85, 0.06, 0.06 },
                     blue = { 0.12, 0.25, 0.95 }, brown = { 0.5, 0.33, 0.15 }, black = { 0.01, 0.01, 0.01 },
                     -- body colours players can pick in the launcher (used only if the game has a close material)
                     orange = { 1, 0.42, 0.02 }, pink = { 1, 0.35, 0.7 }, purple = { 0.5, 0.15, 0.9 }, green = { 0.15, 0.75, 0.2 } }
local BODY_COLOURS = { yellow = true, orange = true, red = true, pink = true, purple = true, green = true, teal = true, blue = true }
local FIGURE = {
    { "s", YEL,  0,   0,  72, 0.34, 0.34, 0.34, 0 },    -- head
    { "c", YEL,  0,   0,  50, 0.08, 0.08, 0.12, 0 },    -- neck
    { "b", YEL,  0,   0,  22, 0.30, 0.42, 0.48, 0 },    -- torso
    { "b", YEL,  0,   0,  -8, 0.24, 0.34, 0.14, 0 },    -- hips
    { "c", YEL,  0, -10, -50, 0.13, 0.13, 0.72, 0, "leg" },
    { "c", YEL,  0,  10, -50, 0.13, 0.13, 0.72, 0, "leg" },
    { "b", YEL,  6, -10, -85, 0.24, 0.13, 0.06, 0, "foot" },
    { "b", YEL,  6,  10, -85, 0.24, 0.13, 0.06, 0, "foot" },
    { "s", YEL,  0, -26,  38, 0.12, 0.12, 0.12, 0 },    -- shoulders
    { "s", YEL,  0,  26,  38, 0.12, 0.12, 0.12, 0 },
    { "c", YEL, 14, -26,  32, 0.10, 0.10, 0.30, 90, "arm" },   -- upper arms (pointing forward)
    { "c", YEL, 14,  26,  32, 0.10, 0.10, 0.30, 90, "arm" },
    { "c", TEAL, 38, -26, 32, 0.14, 0.14, 0.20, 90, "arm" },   -- GrabPack launchers
    { "c", TEAL, 38,  26, 32, 0.14, 0.14, 0.20, 90, "arm" },
    { "b", BLUE, 54, -26, 36, 0.05, 0.15, 0.20, 0, "arm" },    -- left hand (blue)
    { "b", RED,  54,  26, 36, 0.05, 0.15, 0.20, 0, "arm" },    -- right hand (red)
    { "b", RED, -22,   0, 26, 0.14, 0.40, 0.36, 0 },    -- backpack
    { "c", BROWN, -12, -30, 18, 0.06, 0.06, 0.40, 60 }, -- hose
    { "c", "black", 54, -26, 36, 0.025, 0.025, 0.001, 90, "cable", "L" },   -- launch cables (hidden until a hand flies)
    { "c", "black", 54,  26, 36, 0.025, 0.025, 0.001, 90, "cable", "R" },
}
local HAND_OF = { [BLUE] = "L", [RED] = "R" }

-- Player colours. Earlier versions scanned every material in the game for the closest colour, which
-- was slow (frame freezes) and picked odd things (vent lights, decals, copper). Now: ONE known-good
-- base material - the game's own yellow toy paint - and for each colour a dynamic copy of it with its
-- colour parameter changed. If tinting isn't possible, every part simply gets the plain base material,
-- never a random one.
local BAD_MAT = { "decal", "emiss", "glow", "light", "vent", "copper", "glass", "water", "screen", "neon", "lamp", "fx", "ui" }
local BASE_CANDIDATES = {
    "/Game/Materials/Instances/Environment/MI_Yellow.MI_Yellow",
    "/Game/Materials/Instances/MI_Yellow.MI_Yellow",
    "/Game/Materials/MI_Yellow.MI_Yellow",
}
local Tint = { base = nil, param = nil, mids = {}, tries = 0, next_try = 0, scanned = false, mid_ok = true }
local function bad_name(path)
    local l = tostring(path):lower()
    for _, w in ipairs(BAD_MAT) do if l:find(w, 1, true) then return true end end
    return false
end
local function color_cache_read()
    local t = {}
    local f = io.open(MOD_DIR .. "\\colors.txt", "r")
    if f then
        for line in f:lines() do local k, v = line:match("^(%w+)=(%S+)"); if k then t[k] = v end end
        f:close()
    end
    return t
end
local function color_cache_write(base)
    local f = io.open(MOD_DIR .. "\\colors.txt", "w")
    if not f then return end
    f:write("# PoppyCoop player paint (base material, tinted per player colour)\nbase=", base, "\n")
    f:close()
end
-- the colour parameter of the base material (e.g. "Color" / "Base Color"), never an emissive one
local function find_param(mat)
    local found
    pcall(function()
        mat.VectorParameterValues:ForEach(function(_, e)
            if found then return end
            local v = e:get()
            local nm = v.ParameterInfo.Name:ToString()
            local l = nm:lower()
            if not l:find("emiss", 1, true) and (l:find("color", 1, true) or l:find("colour", 1, true) or l:find("tint", 1, true) or l:find("albedo", 1, true)) then
                found = nm
            end
        end)
    end)
    return found
end
local function tint_base()
    if valid(Tint.base) then return Tint.base end
    if game_time < Tint.next_try or Tint.tries >= 12 then return nil end
    Tint.tries = Tint.tries + 1
    Tint.next_try = game_time + 2.5
    local cands = {}
    local cached = color_cache_read().base or color_cache_read().yellow
    if cached and not bad_name(cached) then cands[#cands + 1] = cached end
    for _, c in ipairs(BASE_CANDIDATES) do cands[#cands + 1] = c end
    for _, path in ipairs(cands) do
        local o = try(StaticFindObject, path)
        if valid(o) then Tint.base = o; break end
        if CHAPTER == 1 then load_async(path) end   -- loads in the background; found on a later try (Ch2 has other paths)
    end
    -- last resort, at most once per session: a loaded material named "...yellow..." (names only, cheap)
    -- (Chapter 2 has "PlayerMat_.." materials made for player figures: best match there)
    if not valid(Tint.base) and Tint.tries >= (CHAPTER == 2 and 2 or 4) and not Tint.scanned then
        Tint.scanned = true
        local best, rank = nil, 99
        pcall(function()
            for _, mic in ipairs(FindAllOf("MaterialInstanceConstant") or {}) do
                local fn = valid(mic) and try(function() return mic:GetFullName() end) or ""
                local path = fn:match("^%S+%s+(%S+)$")
                local l = path and path:lower() or ""
                if path and path:find("^/Game/") and not bad_name(path) then
                    local r = l:find("playermat", 1, true) and 0 or l:find("mi_yellow", 1, true) and 1 or l:find("yellow", 1, true) and 2 or 99
                    if r < rank then best, rank = mic, r; if r == 0 then break end end
                end
            end
        end)
        if best then Tint.base = best end
    end
    if valid(Tint.base) then
        Tint.param = find_param(Tint.base)
        local fn = try(function() return Tint.base:GetFullName() end)
        local path = fn and fn:match("^%S+%s+(%S+)$")
        if path then color_cache_write(path) end
        log("player paint: %s (colour parameter: %s)", tostring(path), tostring(Tint.param))
        return Tint.base
    end
    if Tint.tries == 1 then log("player paint not loaded yet - figures get painted when it is") end
    return nil
end

-- returns true when the actor got its final paint
local function paint(actor, key)
    local base = tint_base()
    if not base then return false end
    local comp = try(function() return actor.StaticMeshComponent end)
    if not comp then return false end
    local rgb = TARGET_RGB[key] or TARGET_RGB.yellow
    local mid = Tint.mids[key]
    if valid(mid) then
        pcall(function() comp:SetMaterial(0, mid) end)
        return true
    end
    if Tint.param and Tint.mid_ok and FName then
        mid = try(function() return comp:CreateDynamicMaterialInstance(0, base, FName("None")) end)
        if valid(mid) then
            local ok = pcall(function() mid:SetVectorParameterValue(FName(Tint.param), { R = rgb[1], G = rgb[2], B = rgb[3], A = 1.0 }) end)
            if ok then Tint.mids[key] = mid; return true end
        end
        Tint.mid_ok = false                          -- don't try again this session: plain paint instead
        log("player paint: tinting not available - using the plain toy paint")
    end
    pcall(function() comp:SetMaterial(0, base) end)
    return true
end

-- UE4SS sometimes invalidates a Lua wrapper ("lua state has no instance") while the actor is fine.
-- Detect that once per part and re-acquire the actor by its path instead of erroring every frame.
local function part(p, i)
    local a = p.parts[i]
    if a == nil then return nil end
    local ok, v = pcall(function() return a:IsValid() end)
    if ok then return v and a or nil end
    local path = p.paths and p.paths[i]
    local o = path and try(StaticFindObject, path)
    if valid(o) then p.parts[i] = o; return o end
    p.parts[i] = nil
    return nil
end

-------------------------------------------------------------- Chapter 2 figure
-- The game ships an unused multiplayer prototype with a full player figure ("TrainingDummy": a
-- toy-plastic mannequin with idle/walk/run/crouch/jump/down animations). We dress it with the real
-- GrabPack parts (backpack, both launchers, the player's own hand mesh) and tint it with the player's
-- colour. Falls back to the block figure if any of it can't be loaded (e.g. Chapter 1).
local F2 = {
    mesh = "/Game/Assets/Characters/TrainingDummy/SK_TrainingDummy.SK_TrainingDummy",
    paint = "/Game/Assets/Materials/Environment_MATS/Instanced_Materials/yellowplastic_MATInst.yellowplastic_MATInst",
    backpack = "/Game/Assets/Meshes/hand_launcher/hand_launcher_backpack.hand_launcher_backpack",
    bpmat = "/Game/Assets/Materials/Environment_MATS/Main_Materials/hand_launcher_backpack_MAT.hand_launcher_backpack_MAT",
    gun = "/Game/Assets/Meshes/hand_launcher/hand_launcher_zero_origin.hand_launcher_zero_origin",
    gunmat = "/Game/Assets/Materials/Environment_MATS/Main_Materials/hand_launcher_MAT.hand_launcher_MAT",
    hand = "/Game/Player/Hands/handL_rig.handL_rig",
    cable = "/Engine/BasicShapes/Cylinder.Cylinder",
}
local F2_ANIM_DIR = "/Game/Assets/Characters/TrainingDummy/Animations/"
local F2_ANIMS = { idle = "A_DummyIdle", walk = "A_Dummy_Walk_rig_rigAction", run = "A_Dummy_Run_rig_rigAction",
    cidle = "A_Dummy_CrouchIdle", cwalk = "A_Dummy_CrouchForward_rig_rigAction", air = "A_Dummy_InAir", down = "A_Down_rig_DownIdle" }
-- attachments relative to the rig's bones (the rig's bones carry a x14.7 scale). The rig's mesh faces
-- +Y, so the figure's yaw is the player's yaw - 90; "wrist_R" is the figure's LEFT wrist.
local F2_PARTS = {      -- measured with the rig in its idle pose (relative to the bone: valid in every pose)
    { key = "backpack", sock = "neck",        L = { 0, 1.8319, -1.2259 },        R = { 0, -180, 90 },             S = { 0.02725, 0.02725, 0.02725 } },
    { key = "gunL",     sock = "wrist_R",     L = { -0.0045, 0.5449, -0.0119 },  R = { -19.661, 0.022, 1.331 },   S = { 0.02044, 0.02044, 0.02044 } },
    { key = "gunR",     sock = "wrist_R_001", L = { 0.0041, -0.5450, 0.0015 },   R = { -17.576, 0.386, -179.831 }, S = { 0.02044, 0.02044, 0.02044 } },
}
-- hands sit on the launcher fronts, palms forward like the player's own first-person hands (checked
-- against the first-person hand bones); 80 % of the first-person size
local F2_HAND = { L = { 0, 50.0, -12 }, RL = { 0, 0, 0 }, RR = { 0, 180, 0 }, S = 1.0667 }
local F2_COL = { L = { 0.12, 0.25, 0.95 }, R = { 0.85, 0.06, 0.06 }, G = { 0.15, 0.75, 0.2 } }
local F2A = {}           -- resolved assets
local F2_failed = false

local function f2_ready()
    if F2_failed or CHAPTER ~= 2 then return false end
    if F2A.ok then return true end
    local all = true
    for k, path in pairs(F2) do
        if not valid(F2A[k]) then F2A[k] = find_asset(path) end
        if not valid(F2A[k]) then all = false end
    end
    for k, name in pairs(F2_ANIMS) do
        local key = "anim_" .. k
        if not valid(F2A[key]) then F2A[key] = find_asset(F2_ANIM_DIR .. name .. "." .. name) end
        if not valid(F2A[key]) then all = false end
    end
    F2A.ska = F2A.ska or find_asset("/Script/Engine.SkeletalMeshActor")
    F2A.sma = F2A.sma or find_asset("/Script/Engine.StaticMeshActor")
    F2A.kml = F2A.kml or find_asset("/Script/Engine.Default__KismetMaterialLibrary")
    all = all and valid(F2A.ska) and valid(F2A.sma) and valid(F2A.kml)
    F2A.first = F2A.first or game_time
    if all then F2A.ok = true; log("figure: game's player model ready")
    elseif game_time - F2A.first > 45 then
        F2_failed = true
        local miss = {}
        for k in pairs(F2) do if not valid(F2A[k]) then miss[#miss + 1] = k end end
        for k in pairs(F2_ANIMS) do if not valid(F2A["anim_" .. k]) then miss[#miss + 1] = k end end
        log("figure: player model not available (%s) - using the block figure", table.concat(miss, ","))
    end
    return all
end

local function f2_tint(rgb)
    local world = UEHelpers.GetWorld()
    local m = try(function() return F2A.kml:CreateDynamicMaterialInstance(world, F2A.paint, FName("None"), 0) end)
    if not valid(m) then return F2A.paint end
    pcall(function() m:SetVectorParameterValue(FName("Tint"), { R = rgb[1], G = rgb[2], B = rgb[3], A = 1.0 }) end)
    return m
end

local function f2_spawn(cls, x, y, z)
    local world = UEHelpers.GetWorld()
    if not valid(world) then return nil end
    local a = try(function() return world:SpawnActor(cls, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not valid(a) then return nil end
    pcall(function() a:SetActorEnableCollision(false) end)
    return a
end

local function f2_attach(a, comp, sock, L, R, S)
    pcall(function()
        a:K2_AttachToComponent(comp, FName(sock), 0, 0, 0, false)
        local root = a:K2_GetRootComponent()
        root:K2_SetRelativeLocationAndRotation({ X = L[1], Y = L[2], Z = L[3] }, { Pitch = R[1], Yaw = R[2], Roll = R[3] }, false, {}, true)
        root:SetRelativeScale3D({ X = S[1], Y = S[2], Z = S[3] })
    end)
end

local function f2_hand_attach(p, tag)
    local h, g = p.f2["hand" .. tag], p.f2["gun" .. tag]
    if not (valid(h) and valid(g)) then return end
    local s = F2_HAND.S
    f2_attach(h, g.StaticMeshComponent, "None", F2_HAND.L, tag == "R" and F2_HAND.RR or F2_HAND.RL, { s, tag == "R" and -s or s, s })
    p.f2["free" .. tag] = false
end

-- build the figure; returns the puppet table or nil
local function f2_build(st)
    local x, y, z = st.x, st.y, st.z - 88
    local body = f2_spawn(F2A.ska, x, y, z)
    if not body then return nil end
    local f = { body = body }
    local colour = TARGET_RGB[(st.color and BODY_COLOURS[st.color]) and st.color or "yellow"] or TARGET_RGB.yellow
    pcall(function()
        local c = body.SkeletalMeshComponent
        c:SetSkeletalMesh(F2A.mesh, true)
        c:SetMaterial(0, f2_tint(colour))
        c:SetCollisionEnabled(0)
        c:PlayAnimation(F2A.anim_idle, true)
    end)
    f.anim = "idle"
    local bc = body.SkeletalMeshComponent
    for _, d in ipairs(F2_PARTS) do
        local a = f2_spawn(F2A.sma, x, y, z)
        if a then
            pcall(function()
                local c = a.StaticMeshComponent
                c:SetMobility(2)
                c:SetStaticMesh(d.key == "backpack" and F2A.backpack or F2A.gun)
                local mat = d.key == "backpack" and F2A.bpmat or F2A.gunmat
                for i = 0, c:GetNumMaterials() - 1 do c:SetMaterial(i, mat) end
                c:SetCollisionEnabled(0)
            end)
            f2_attach(a, bc, d.sock, d.L, d.R, d.S)
        end
        f[d.key] = a
    end
    for _, tag in ipairs({ "L", "R" }) do
        local h = f2_spawn(F2A.ska, x, y, z)
        if h then
            pcall(function()
                local c = h.SkeletalMeshComponent
                c:SetSkeletalMesh(F2A.hand, true)
                c:SetCollisionEnabled(0)
            end)
            f["mat" .. tag] = f2_tint(F2_COL[tag])
            pcall(function() h.SkeletalMeshComponent:SetMaterial(0, f["mat" .. tag]) end)
        end
        f["hand" .. tag] = h
        local anchor = f2_spawn(F2A.sma, x, y, z)
        -- must be movable, or it can't follow the launcher (static components ignore the attachment)
        if anchor then pcall(function() anchor.StaticMeshComponent:SetMobility(2) end) end
        if anchor and valid(f["gun" .. tag]) then
            local s = F2_HAND.S
            f2_attach(anchor, f["gun" .. tag].StaticMeshComponent, "None", F2_HAND.L, tag == "R" and F2_HAND.RR or F2_HAND.RL, { s, tag == "R" and -s or s, s })
        end
        f["anchor" .. tag] = anchor
        local cab = f2_spawn(F2A.sma, x, y, z)
        if cab then
            pcall(function()
                local c = cab.StaticMeshComponent
                c:SetMobility(2)
                c:SetStaticMesh(F2A.cable)
                c:SetMaterial(0, f2_tint(TARGET_RGB.black))
                c:SetCollisionEnabled(0)
                c:SetCastShadow(false)
                cab:SetActorHiddenInGame(true)
            end)
        end
        f["cable" .. tag] = cab
    end
    local p = { f2 = f, parts = { body }, paths = { try(function() return body:GetFullName():match("^%S+ (.+)$") end) } }
    for k, a in pairs(f) do
        if type(a) == "userdata" and k ~= "matL" and k ~= "matR" and k ~= "body" then
            p.parts[#p.parts + 1] = a
            p.paths[#p.parts] = try(function() return a:GetFullName():match("^%S+ (.+)$") end)
        end
    end
    p.f2.green = false
    f2_hand_attach(p, "L")
    f2_hand_attach(p, "R")
    return p
end

local function f2_play(f, name, rate)
    if f.anim ~= name then
        f.anim = name
        pcall(function() f.body.SkeletalMeshComponent:PlayAnimation(F2A["anim_" .. name], true) end)
    end
    if rate and math.abs((f.rate or 1) - rate) > 0.05 then
        f.rate = rate
        pcall(function() f.body.SkeletalMeshComponent:SetPlayRate(rate) end)
    end
end

-- per frame: place the figure, pick its animation, fly the hands, recolour the green hand
local function f2_update(p, st, c, dt, crouch, dead)
    local f = p.f2
    if not valid(f.body) then return end
    local air = (p.air or 0) > 0.5
    local spd = p.spd or 0
    if dead then f2_play(f, "down", 1)
    elseif air then f2_play(f, "air", 1)
    elseif crouch then
        if spd > 30 then f2_play(f, "cwalk", math.max(0.6, math.min(1.6, spd / 120))) else f2_play(f, "cidle", 1) end
    elseif spd > 330 then f2_play(f, "run", math.max(0.7, math.min(1.5, spd / 420)))
    elseif spd > 30 then f2_play(f, "walk", math.max(0.5, math.min(1.6, spd / 160)))
    else f2_play(f, "idle", 1) end
    pcall(function()
        f.body:K2_SetActorLocationAndRotation({ X = c.x, Y = c.y, Z = c.z - 88 }, { Pitch = 0, Yaw = c.yaw - 90, Roll = 0 }, false, {}, true)
    end)
    -- hands: attached to the launchers until one flies; then it travels to the sent position
    for _, tag in ipairs({ "L", "R" }) do
        local h, cab, g = f["hand" .. tag], f["cable" .. tag], f["gun" .. tag]
        local e, tgt = p.ext[tag], p.hand[tag]
        if valid(h) and valid(g) then
            local flying = e > 0.03 and tgt ~= nil
            -- where the hand rests on its launcher (an invisible anchor follows the launcher)
            local anc = f["anchor" .. tag]
            local src = valid(anc) and anc or (not f["free" .. tag] and h or nil)
            if src then
                local ok, l, r = pcall(function() return src:K2_GetActorLocation(), src:K2_GetActorRotation() end)
                if ok then f["rest" .. tag], f["rrot" .. tag] = { x = l.X, y = l.Y, z = l.Z }, { p = r.Pitch, y = r.Yaw, r = r.Roll } end
            end
            local rest = f["rest" .. tag]
            if flying and rest then
                if not f["free" .. tag] then
                    pcall(function() h:K2_DetachFromActor(1, 1, 1) end)
                    f["free" .. tag] = true
                end
                local hx, hy, hz = rest.x + (tgt.x - rest.x) * e, rest.y + (tgt.y - rest.y) * e, rest.z + (tgt.z - rest.z) * e
                local vx, vy, vz = tgt.x - rest.x, tgt.y - rest.y, tgt.z - rest.z
                local dyaw = math.deg(math.atan(vy, vx)) - c.yaw
                local rr = f["rrot" .. tag]
                pcall(function()
                    h:K2_SetActorLocationAndRotation({ X = hx, Y = hy, Z = hz },
                        { Pitch = rr.p, Yaw = rr.y + dyaw, Roll = rr.r }, false, {}, true)
                end)
                -- cable: thin black cylinder (100 tall along Z) from the launcher to the hand
                local lx, ly, lz = hx - rest.x, hy - rest.y, hz - rest.z
                local len = math.sqrt(lx * lx + ly * ly + lz * lz)
                if valid(cab) then
                    pcall(function()
                        if len > 5 then
                            cab:SetActorHiddenInGame(false)
                            -- the hand's origin sits a little below the launcher tube: lift the cable onto the tube axis
                            local lift = -F2_HAND.L[3] * g:GetActorScale3D().X
                            cab:K2_SetActorLocationAndRotation({ X = (rest.x + hx) / 2, Y = (rest.y + hy) / 2, Z = (rest.z + hz) / 2 + lift },
                                { Pitch = 90 + math.deg(math.atan(lz, math.sqrt(lx * lx + ly * ly))), Yaw = math.deg(math.atan(ly, lx)), Roll = 0 }, false, {}, true)
                            cab:SetActorScale3D({ X = 0.025, Y = 0.025, Z = len / 100 })
                        else
                            cab:SetActorHiddenInGame(true)
                        end
                    end)
                end
            elseif f["free" .. tag] then
                f2_hand_attach(p, tag)
                if valid(cab) then pcall(function() cab:SetActorHiddenInGame(true) end) end
            end
        end
    end
    -- green hand: the right hand takes the green colour while the player has it
    local green = (st.flags & 32) ~= 0
    if green ~= f.green then
        f.green = green
        local m = f.matR
        if valid(m) then
            local rgb = green and F2_COL.G or F2_COL.R
            pcall(function() m:SetVectorParameterValue(FName("Tint"), { R = rgb[1], G = rgb[2], B = rgb[3], A = 1.0 }) end)
        end
    end
end

local function destroy_puppet(id)
    local p = Puppets[id]
    if not p then return end
    for i in pairs(p.parts or {}) do
        local a = part(p, i)
        if a then pcall(function() a:K2_DestroyActor() end) end
    end
    if valid(p.tag) then pcall(function() p.tag:K2_DestroyActor() end) end
    Puppets[id] = nil
end

local function parse_state(s)
    local x, y, z, yaw, pitch, flags, map = s:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%d+) (%S+)")
    if not x then return nil end
    local colour = s:match("^%S+ %S+ %S+ %S+ %S+ %d+ %S+ (%a+)")
    local hands = nil
    for tag, hx, hy, hz in s:gmatch(" ([LR])=(%-?%d+),(%-?%d+),(%-?%d+)") do
        hands = hands or {}
        hands[tag] = { x = tonumber(hx), y = tonumber(hy), z = tonumber(hz) }
    end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw), pitch = tonumber(pitch),
             flags = tonumber(flags), map = map, color = colour, hands = hands }
end

local function update_puppets(dt)
    -- figures spawned before the paint was loaded: paint them as soon as it is (one pass, no rescans)
    for _, p in pairs(Puppets) do
        if p.unpainted and tint_base() then
            local left = false
            for i, d in ipairs(FIGURE) do
                local a = p.parts[i]
                if a and p.keys and not paint(a, p.keys[i]) then left = true end
            end
            p.unpainted = left or nil
        end
    end
    for id, pl in pairs(Net.players) do
        local st = pl.state and parse_state(pl.state)
        local p = Puppets[id]
        if st and st.map == Game.map and Game.pawn then
            if p and not part(p, p.f2 and 1 or 3) then destroy_puppet(id); p = nil end   -- world reloaded
            if p and p.color ~= st.color then destroy_puppet(id); p = nil end    -- picked another colour
            if not p and f2_ready() then
                p = f2_build(st)
                if p then
                    p.cur, p.color = { x = st.x, y = st.y, z = st.z, yaw = st.yaw }, st.color
                    resolve_assets()
                    p.tag = spawn_tag(pl.name or ("P" .. id), st.x, st.y, st.z + 120)
                    Puppets[id] = p
                    log("spawned figure for %s", pl.name or id)
                end
            end
            if not p and (F2_failed or CHAPTER ~= 2) then
                resolve_assets()
                p = { cur = { x = st.x, y = st.y, z = st.z, yaw = st.yaw }, color = st.color }
                p.parts = {}
                local meshes = { c = Assets.body, s = Assets.head, b = Assets.cube or Assets.body }
                for i, d in ipairs(FIGURE) do
                    local a = spawn_mesh(meshes[d[1]], st.x, st.y, st.z + d[5], d[6], d[7], d[8])
                    p.keys = p.keys or {}
                    local key = d[2]
                    if key == YEL and st.color and BODY_COLOURS[st.color] then key = st.color end
                    p.keys[i] = key
                    if a and not paint(a, key) then p.unpainted = true end
                    p.parts[i] = a
                    p.paths = p.paths or {}
                    p.paths[i] = a and try(function() return a:GetFullName():match("^%S+ (.+)$") end)
                end
                p.tag = spawn_tag(pl.name or ("P" .. id), st.x, st.y, st.z + 120)
                Puppets[id] = p
                log("spawned puppet for %s (%s)", pl.name or id, valid(p.parts[3]) and "ok" or "FAILED")
            end
            if not p then goto next_player end      -- figure assets still loading
            p.tgt = st
            local c = p.cur
            local dx, dy, dz = st.x - c.x, st.y - c.y, st.z - c.z
            -- vertical speed from consecutive updates; while airborne, predict ahead so the figure's
            -- jump reaches the real height instead of being flattened by the smoothing
            if p.st_t ~= pl.state_time then
                if p.st_t and pl.state_time and pl.state_time > p.st_t then p.vz = (st.z - p.st_z) / (pl.state_time - p.st_t) end
                p.st_t, p.st_z = pl.state_time, st.z
            end
            local tz = st.z
            if (st.flags & 8) ~= 0 and p.vz and pl.state_time then
                tz = st.z + p.vz * math.min(0.08, math.max(0, game_time - pl.state_time))
            end
            dz = tz - c.z
            if dx * dx + dy * dy + dz * dz > 600 * 600 then
                c.x, c.y, c.z = st.x, st.y, tz              -- teleport / respawn
            else
                local a, az = math.min(1, dt * 14), math.min(1, dt * 26)
                c.x, c.y, c.z = c.x + dx * a, c.y + dy * a, c.z + dz * az
            end
            local dyaw = ((st.yaw - c.yaw + 540) % 360) - 180
            c.yaw = c.yaw + dyaw * math.min(1, dt * 14)
            local crouch = (st.flags & 1) ~= 0
            local airborne = (st.flags & 8) ~= 0
            p.aim = (p.aim or 0) + ((math.max(-60, math.min(60, st.pitch > 180 and st.pitch - 360 or st.pitch))) - (p.aim or 0)) * math.min(1, dt * 12)
            p.air = (p.air or 0) + ((airborne and 1 or 0) - (p.air or 0)) * math.min(1, dt * 10)
            local cy, sy = math.cos(math.rad(c.yaw)), math.sin(math.rad(c.yaw))
            -- procedural walk: speed from how far the figure moved this frame
            local mvx, mvy = c.x - (p.lx or c.x), c.y - (p.ly or c.y)
            p.lx, p.ly = c.x, c.y
            local speed = dt > 0 and math.sqrt(mvx * mvx + mvy * mvy) / dt or 0
            if pl.pose == "run" or pl.pose == "stride" then speed = 450 end   -- placed figure posed as running
            p.spd = (p.spd or 0) + (speed - (p.spd or 0)) * math.min(1, dt * 8)
            local amount = math.min(1, p.spd / 350)                     -- 0 standing .. 1 sprinting
            p.phase = ((p.phase or 0) + dt * (4 + p.spd / 60) * (amount > 0.05 and 1 or 0)) % (2 * math.pi)
            if pl.pose == "stride" then p.phase = math.pi / 2 end            -- frozen mid-stride (for screenshots)
            local swing = math.sin(p.phase) * 32 * amount * (1 - p.air) -- degrees
            local bob = math.abs(math.sin(p.phase)) * 3 * amount
            -- launched hands: ease each hand out to the sent position (and back again when it retracts)
            p.ext = p.ext or { L = 0, R = 0 }
            p.hand = p.hand or {}
            local dead = (st.flags & 16) ~= 0
            for _, tag in ipairs({ "L", "R" }) do
                local h = (not dead) and st.hands and st.hands[tag]
                if h then
                    local cur = p.hand[tag]
                    if not cur or p.ext[tag] < 0.05 then p.hand[tag] = { x = h.x, y = h.y, z = h.z }
                    else local k = math.min(1, dt * 18); cur.x, cur.y, cur.z = cur.x + (h.x - cur.x) * k, cur.y + (h.y - cur.y) * k, cur.z + (h.z - cur.z) * k end
                end
                p.ext[tag] = p.ext[tag] + ((h and 1 or 0) - p.ext[tag]) * math.min(1, dt * (h and 16 or 9))
            end
            if p.f2 then
                f2_update(p, st, c, dt, crouch, dead)
                goto figure_done
            end
            do
            local rest = {}                -- world position of each hand on its launcher, filled below
            for i, d in ipairs(FIGURE) do
                local a = part(p, i)
                if a and d[10] ~= "cable" then
                    local ox, oy, oz = d[3], d[4], d[5]
                    local zs = d[8]
                    local pitch = d[9]
                    if (d[10] == "leg" or d[10] == "foot") and not crouch then
                        local side = oy < 0 and 1 or -1                  -- legs swing opposite each other
                        -- walking swing, blended into a jump tuck (left knee forward, right leg back)
                        local th = math.rad(swing * side + p.air * (oy < 0 and 28 or -14))
                        local L = (d[10] == "leg") and 36 or 72          -- distance from the hip pivot (z = -14)
                        ox = ox + L * math.sin(th)
                        oz = -14 - L * math.cos(th)
                        if d[10] == "leg" then pitch = swing * side + p.air * (oy < 0 and 28 or -14) end
                    else
                        oz = oz + bob
                    end
                    if d[10] == "arm" then
                        -- aim: rotate around the shoulder (x=0, z=32) by look pitch, lifted a little in the air
                        local ang = math.rad(p.aim + p.air * 12)
                        local dx, dz = ox, oz - 32
                        ox = dx * math.cos(ang) - dz * math.sin(ang)
                        oz = 32 + dx * math.sin(ang) + dz * math.cos(ang)
                        pitch = pitch + p.aim + p.air * 12
                    end
                    if crouch then
                        if d[10] == "leg" then oz, zs = -66, d[8] * 0.45
                        elseif d[10] ~= "foot" then oz = oz - 30 end
                    end
                    if (st.flags & 16) ~= 0 then
                        -- dead: lying on their back, pivoting at the feet
                        local fx, fz = ox, oz + 88
                        ox, oz = -fz, -80 + fx * 0.3
                        pitch = pitch - 90
                    end
                    local wx, wy, wz, wyaw = c.x + ox * cy - oy * sy, c.y + ox * sy + oy * cy, c.z + oz, c.yaw
                    local tag = d[10] == "arm" and d[1] == "b" and HAND_OF[d[2]]
                    if tag then
                        rest[tag] = { x = wx, y = wy, z = wz }
                        local e, h = p.ext[tag], p.hand[tag]
                        if e > 0.01 and h then
                            wx, wy, wz = wx + (h.x - wx) * e, wy + (h.y - wy) * e, wz + (h.z - wz) * e
                            local vx, vy, vz = h.x - rest[tag].x, h.y - rest[tag].y, h.z - rest[tag].z
                            wyaw = math.deg(math.atan(vy, vx))
                            pitch = math.deg(math.atan(vz, math.sqrt(vx * vx + vy * vy)))
                        end
                    end
                    pcall(function()
                        a:K2_SetActorLocationAndRotation({ X = wx, Y = wy, Z = wz },
                            { Pitch = pitch, Yaw = wyaw, Roll = 0 }, false, {}, true)
                        if crouch ~= p.crouched and d[10] == "leg" then a:SetActorScale3D({ X = d[6], Y = d[7], Z = zs }) end
                    end)
                end
            end
            -- cables: a thin cylinder (100 units tall along its axis) stretched from launcher to hand
            for i, d in ipairs(FIGURE) do
                if d[10] == "cable" then
                    local a = part(p, i)
                    local tag, r = d[11], rest[d[11]]
                    local e, h = p.ext[tag], p.hand[tag]
                    if a and r then
                        local show = e > 0.02 and h
                        local hx, hy, hz = r.x, r.y, r.z
                        if show then hx, hy, hz = r.x + (h.x - r.x) * e, r.y + (h.y - r.y) * e, r.z + (h.z - r.z) * e end
                        local vx, vy, vz = hx - r.x, hy - r.y, hz - r.z
                        local len = math.sqrt(vx * vx + vy * vy + vz * vz)
                        local key = show and len > 5
                        pcall(function()
                            if key then
                                a:K2_SetActorLocationAndRotation({ X = (r.x + hx) / 2, Y = (r.y + hy) / 2, Z = (r.z + hz) / 2 },
                                    { Pitch = 90 + math.deg(math.atan(vz, math.sqrt(vx * vx + vy * vy))), Yaw = math.deg(math.atan(vy, vx)), Roll = 0 }, false, {}, true)
                                a:SetActorScale3D({ X = d[6], Y = d[7], Z = len / 100 })
                                p["cab" .. tag] = true
                            elseif p["cab" .. tag] then
                                a:SetActorScale3D({ X = d[6], Y = d[7], Z = 0.001 })
                                p["cab" .. tag] = false
                            end
                        end)
                    end
                end
            end
            p.crouched = crouch
            local green = (st.flags & 32) ~= 0
            if green ~= (p.green or false) then
                for i, d in ipairs(FIGURE) do
                    if d[10] == "arm" and d[1] == "b" and d[2] == RED then
                        local a = part(p, i)
                        if a then paint(a, green and "green" or RED) end
                    end
                end
                p.green = green
            end
            end
            ::figure_done::
            p.crouched = crouch
            local headZ = c.z + (crouch and 42 or 72)
            if valid(p.tag) then
                -- face the local camera
                local my = Game.pawn:K2_GetActorLocation()
                local yaw = math.deg(math.atan(my.Y - c.y, my.X - c.x))
                pcall(function()
                    p.tag:K2_SetActorLocationAndRotation({ X = c.x, Y = c.y, Z = headZ + 32 }, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                end)
            end
        elseif p then
            destroy_puppet(id)
        end
        ::next_player::
    end
    for id in pairs(Puppets) do if not Net.players[id] then destroy_puppet(id) end end
end

table.insert(Handlers.leave, function(id) destroy_puppet(id) end)


----------------------------------------------------------------------- ghosts (trailer helpers)
-- Fake second players that only exist in YOUR game, so one person can film "two players together".
--   F7 / coop_buddy [name] [colour]  a buddy walks beside you, copying your moves a moment later
--   O  / coop_record                 start/stop recording your own movement (saved to recording.txt)
--   P  / coop_play [name] [colour]   replay the recording as a second player; walk alongside it
--   (default name "Huggy Wuggy"; F8/F9 are left free for other mods)
--   coop_ghost_off                   remove the buddy / replay
-- Works online or offline (mode=off). Ghosts use the same figure as real players.
local Ghost = { buddy = nil, play = nil, rec = nil, keys = {}, placed = {}, place_req = {} }
--   coop_place [name] [colour] [pose] [distance]  put a still figure in front of you (default 200), facing you
--        pose = stand (default) | stride (frozen mid-run, best for screenshots) | run (running on the spot)
--   coop_place_at x y z yaw [name] [colour] [pose]   same, at exact coordinates
--   coop_move fwd right up [turn]    nudge the last placed figure (cm / degrees), e.g. coop_move 0 0 80
--   coop_place_off                   remove all placed figures
local BUDDY_ID, PLAY_ID = 900, 901
local GHOST_DELAY, BUDDY_SIDE, BUDDY_BACK = 0.45, 115, 35
local history = {}                   -- recent { t, st } of the local player (for the buddy's delay)

local PLACE_ID0 = 910
local function ghost_active() return Ghost.buddy ~= nil or Ghost.play ~= nil or Ghost.rec ~= nil or next(Ghost.placed) ~= nil or #Ghost.place_req > 0 end
-- trailer-helper messages go to the log only (UE4SS console / UE4SS.log)
local function gsay(fmt, ...)
    local msg = fmt:format(...)
    log("%s", msg)
    -- deliberately NOT shown on screen: these messages would end up in trailer footage
end

local function ghost_state(st, x, y, colour)
    return ("%.1f %.1f %.1f %.1f %.1f %d %s %s"):format(x, y, st.z, st.yaw, st.pitch, st.flags, st.map, colour)
end

local function start_buddy(name, colour)
    Ghost.buddy = { name = name or "Huggy Wuggy", colour = colour or "blue" }
    Net.players[BUDDY_ID] = { name = Ghost.buddy.name }
    gsay("Buddy on: %s walks beside you (F7 = off)", Ghost.buddy.name)
end
local function stop_ghosts()
    Ghost.buddy, Ghost.play = nil, nil
    Net.players[BUDDY_ID], Net.players[PLAY_ID] = nil, nil
    for id in pairs(Ghost.placed) do Net.players[id] = nil end
    Ghost.placed = {}
    gsay("Buddy / replay removed")
end
local function toggle_record()
    if Ghost.rec then
        local f = io.open(MOD_DIR .. "\\recording.txt", "w")
        if f then
            for _, e in ipairs(Ghost.rec.lines) do f:write(("%.3f\t%s\n"):format(e[1], e[2])) end
            f:close()
        end
        gsay("Recording saved (%.0f s) - reload, then P to replay", Ghost.rec.len or 0)
        Ghost.rec = nil
    else
        Ghost.rec = { start = game_time, lines = {}, len = 0 }
        gsay("REC - recording your movement (O = stop)")
    end
end
local function start_play(name, colour)
    local lines = {}
    local f = io.open(MOD_DIR .. "\\recording.txt", "r")
    if f then
        for l in f:lines() do
            local t, st = l:match("^([%d%.]+)\t(.+)$")
            if t then lines[#lines + 1] = { tonumber(t), st } end
        end
        f:close()
    end
    if #lines == 0 then gsay("No recording yet - press O to record one"); return end
    Ghost.play = { name = name or "Huggy Wuggy", colour = colour or "blue", lines = lines, start = game_time, i = 1 }
    Net.players[PLAY_ID] = { name = Ghost.play.name }
    gsay("Replaying %.0f s as %s (P = remove)", lines[#lines][1], Ghost.play.name)
end

local function ghost_tick(dt)
    for _, k in ipairs(Ghost.keys) do
        if k == "buddy" then
            if Ghost.buddy then Ghost.buddy = nil; Net.players[BUDDY_ID] = nil; gsay("Buddy off") else start_buddy() end
        elseif k == "record" then toggle_record()
        elseif k == "play" then if Ghost.play then Ghost.play = nil; Net.players[PLAY_ID] = nil; gsay("Replay removed") else start_play() end end
    end
    Ghost.keys = {}
    if not ghost_active() then return end
    local mine = try(local_state)
    local st = mine and parse_state(mine)
    if not st then return end
    -- placed figures: create any requested ones, then keep them alive every frame
    for _, r in ipairs(Ghost.place_req) do
        local id = PLACE_ID0
        while Ghost.placed[id] do id = id + 1 end
        local x, y, z, yaw = r.x, r.y, r.z, r.yaw
        if not x then
            -- never spawn inside the player: put the figure in front of you, turned to face you
            local d = r.dist or 200
            local yr = math.rad(st.yaw)
            x, y, z, yaw = st.x + math.cos(yr) * d, st.y + math.sin(yr) * d, st.z, (st.yaw + 180) % 360
        end
        Ghost.placed[id] = { x = x, y = y, z = z, yaw = yaw, map = st.map, colour = r.colour, name = r.name, pose = r.pose }
        Ghost.last_placed = id
        gsay("Placed %s (%s, %s) at %.0f %.0f %.0f yaw %.0f", r.name, r.colour, r.pose, x, y, z, yaw)
    end
    Ghost.place_req = {}
    for _, m in ipairs(Ghost.move_req or {}) do
        local g = Ghost.last_placed and Ghost.placed[Ghost.last_placed]
        if g then
            local yr = math.rad(g.yaw)
            g.x = g.x + math.cos(yr) * m.f - math.sin(yr) * m.r
            g.y = g.y + math.sin(yr) * m.f + math.cos(yr) * m.r
            g.z = g.z + m.u
            g.yaw = (g.yaw + m.turn) % 360
            gsay("Moved %s to %.0f %.0f %.0f yaw %.0f", g.name, g.x, g.y, g.z, g.yaw)
        end
    end
    Ghost.move_req = {}
    for id, g in pairs(Ghost.placed) do
        g.line = ("%.1f %.1f %.1f %.1f %.1f %d %s %s"):format(g.x, g.y, g.z, g.yaw, 0, 0, g.map, g.colour)
        local p = Net.players[id] or { name = g.name }
        Net.players[id] = p
        p.name, p.pose = g.name, g.pose
        p.state, p.state_time = g.line, game_time
    end
    -- the buddy repeats what you did GHOST_DELAY seconds ago, a step to your side
    history[#history + 1] = { t = game_time, st = st }
    while #history > 2 and history[2].t < game_time - GHOST_DELAY do table.remove(history, 1) end
    if Ghost.buddy then
        local h = history[1].st
        local yr = math.rad(h.yaw)
        local x = h.x + math.cos(yr + math.pi / 2) * BUDDY_SIDE - math.cos(yr) * BUDDY_BACK
        local y = h.y + math.sin(yr + math.pi / 2) * BUDDY_SIDE - math.sin(yr) * BUDDY_BACK
        local p = Net.players[BUDDY_ID] or { name = Ghost.buddy.name }
        Net.players[BUDDY_ID] = p
        p.state, p.state_time = ghost_state(h, x, y, Ghost.buddy.colour), game_time
    end
    if Ghost.rec then
        Ghost.rec.len = game_time - Ghost.rec.start
        Ghost.rec.lines[#Ghost.rec.lines + 1] = { Ghost.rec.len, ghost_state(st, st.x, st.y, "yellow") }
    end
    if Ghost.play then
        local g = Ghost.play
        local t = game_time - g.start
        while g.i < #g.lines and g.lines[g.i + 1][1] <= t do g.i = g.i + 1 end
        local rec = parse_state(g.lines[g.i][2])
        local p = Net.players[PLAY_ID] or { name = g.name }
        Net.players[PLAY_ID] = p
        if rec then p.state, p.state_time = ghost_state(rec, rec.x, rec.y, g.colour), game_time end
        if g.i >= #g.lines and not g.done_logged then g.done_logged = true; gsay("Replay finished (P = remove)") end
    end
end

-- Teleport key (default F6, see keybinds.txt): go to a friend (handy when someone is stuck or far behind).
-- With 3+ players every press
-- goes to the next one.
local TpReq = false
local TpLast = nil
local function teleport_to_friend()
    local pawn = Game.pawn
    if not valid(pawn) then return end
    local P2 = _G.PoppyCoop
    local function say(msg) log("%s", msg); if P2 and P2.popup then pcall(P2.popup, msg) end end
    local ids = {}
    for id, pl in pairs(Net.players) do
        local st = pl.state and parse_state(pl.state)
        if st and id ~= BUDDY_ID and id ~= PLAY_ID and st.map == Game.map and (st.flags & 16) == 0 then ids[#ids + 1] = id end
    end
    if #ids == 0 then say("Nobody to teleport to (others are dead, loading or in another map)") return end
    table.sort(ids)
    local pick = ids[1]
    if TpLast then for _, id in ipairs(ids) do if id > TpLast then pick = id; break end end end
    TpLast = pick
    local pl = Net.players[pick]
    local st = parse_state(pl.state)
    pcall(function() pawn:K2_SetActorLocation({ X = st.x - 60, Y = st.y, Z = st.z + 30 }, false, {}, true) end)
    say("Teleported to " .. (pl.name or ("player " .. pick)))
end
-- Keys come from ue4ss\Mods\PoppyCoop\keybinds.txt (written with the defaults on first run).
-- Names are UE4SS key names: F1..F12, A..Z, ONE..NINE, NUM_ZERO..NUM_NINE, INS, HOME, END, PAGE_UP ...
local KB = { teleport = "F6", buddy = "F7", record = "O", play = "P" }
do
    local fn = MOD_DIR .. "\\keybinds.txt"
    local f = io.open(fn, "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*(%w+)%s*=%s*([%w_]+)")
            if k and KB[k] then
                v = v:upper()
                if Key and Key[v] ~= nil then KB[k] = v else log("keybinds.txt: unknown key '%s' for %s, using %s", v, k, KB[k]) end
            end
        end
        f:close()
    else
        f = io.open(fn, "w")
        if f then
            f:write("# PoppyCoop keys - change a key, save, restart the game. F8/F9 are left free for other mods.\n")
            for _, k in ipairs({ "teleport", "buddy", "record", "play" }) do f:write(k, "=", KB[k], "\n") end
            f:close()
        end
    end
end
local function bind(name, fn) pcall(function() RegisterKeyBind(Key[KB[name]], fn) end) end
bind("teleport", function() TpReq = true end)
bind("buddy", function() Ghost.keys[#Ghost.keys + 1] = "buddy" end)
bind("record", function() Ghost.keys[#Ghost.keys + 1] = "record" end)
bind("play", function() Ghost.keys[#Ghost.keys + 1] = "play" end)
log("keys: teleport=%s buddy=%s record=%s play=%s", KB.teleport, KB.buddy, KB.record, KB.play)

----------------------------------------------------------------------- tick
local send_accum, last_sent, last_sent_t = 0, nil, 0

-- perf report (every 15 s) only for developers: create ue4ss\Mods\PoppyCoop\perf_on.txt
local PERF_LOG = (function() local f = io.open(MOD_DIR .. "\\perf_on.txt", "r"); if f then f:close(); return true end return false end)()
local Perf = { frames = 0, real = 0, lua = 0, hooks = 0, by = {}, sec = {} }
local function tick(dt)
    game_time = game_time + dt
    if Game.loading then return end     -- a level is loading: don't touch any engine object
    local ghosts = ghost_active() or #Ghost.keys > 0
    if Config.mode == "off" and not ghosts then return end
    if Config.mode ~= "off" then net_try_connect() end
    if not Net.connected then
        -- offline: only the trailer ghosts run
        if ghosts and refresh_player() then
            ghost_tick(dt); update_puppets(dt)
            local P = _G.PoppyCoop
            if P and P.popups_tick then pcall(P.popups_tick) end
        end
        return
    end
    local have = refresh_player()
    if have and ghosts then ghost_tick(dt) end
    send_accum = send_accum + dt
    if send_accum >= 1 / Config.send_hz then
        send_accum = 0
        local st = have and try(local_state) or nil
        -- don't resend identical state more than once a second
        if st and st == last_sent and game_time - last_sent_t < 1 then st = nil end
        if st then last_sent, last_sent_t = st, game_time end
        net_poll(st)
    end
    local c0 = os.clock()
    if have then update_puppets(dt) end
    Perf.sec.figures = (Perf.sec.figures or 0) + os.clock() - c0
    if TpReq then TpReq = false; if have then pcall(teleport_to_friend) end end
    for i, h in ipairs(Handlers.tick) do
        local c1 = os.clock()
        local ok, err = pcall(h, dt, have)
        if not ok then log("module tick error: %s", tostring(err)) end
        local k = "mod" .. i
        Perf.sec[k] = (Perf.sec[k] or 0) + os.clock() - c1
    end
end

-- Performance meter: every 15 s one line in UE4SS.log + perf_<name>.txt (fps, mod time per frame,
-- hooked game-function calls per second and the busiest ones).
local function perf_report()
    local fps = Perf.frames / Perf.real
    local ms = Perf.lua * 1000 / math.max(Perf.frames, 1)
    local top = {}
    for k, n in pairs(Perf.by) do top[#top + 1] = { k = k, n = n } end
    table.sort(top, function(a, b) return a.n > b.n end)
    local t = {}
    for i = 1, math.min(5, #top) do t[#t + 1] = ("%s=%.0f/s"):format(top[i].k:match("([^/.]+:.+)$") or top[i].k, top[i].n / Perf.real) end
    local secs = {}
    for k, v in pairs(Perf.sec) do secs[#secs + 1] = ("%s=%.2f"):format(k, v * 1000 / math.max(Perf.frames, 1)) end
    table.sort(secs)
    local line = ("perf: %.1f fps | mod %.2f ms/frame (%.0f%% of frame) [%s] | hooks %.0f/s | %s"):format(
        fps, ms, ms * fps / 10, table.concat(secs, " "), Perf.hooks / Perf.real, table.concat(t, " "))
    log("%s", line)
    local f = io.open(MOD_DIR .. "\\perf_" .. tostring(Config.name):gsub("[^%w_%-]", "_") .. ".txt", "a")
    if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end
    Perf.frames, Perf.real, Perf.lua, Perf.hooks, Perf.by, Perf.sec = 0, 0, 0, 0, {}, {}
end

-- Drive the tick from the player's own per-frame Blueprint tick (runs on the game thread).
local tick_hooked = false
local world_unloading   -- defined below
local function hook_tick()
    if tick_hooked then return end
    local ok, err = pcall(function()
        -- Frame time from the engine's real-time clock (reading the hook's DeltaSeconds param is
        -- unreliable in UE4SS 3.0.1). Falls back to os.clock (wall time with the MSVC runtime).
        local function realtime()
            local ok, v = pcall(function()
                -- world context = GameInstance: lives for the whole game, never a stale world (crash fix)
                return SafeUE.gameplay_statics():GetRealTimeSeconds(SafeUE.game_instance())
            end)
            if ok and type(v) == "number" then return v end
            return os.clock()
        end
        local last = realtime()
        RegisterHook("/Game/Player/PlayerBP.PlayerBP_C:ReceiveTick", function()
            -- a new world (checkpoint reload) -> forget cached objects BEFORE anything touches them
            local w = SafeUE.world()
            local wa = w and try(function() return tostring(w:GetAddress()) end)
            if wa and Game.world_addr and wa ~= Game.world_addr then world_unloading(); Game.loading = false end
            if wa then Game.world_addr = wa end
            local now = realtime()
            local dt = now - last
            last = now
            local c0 = os.clock()
            if dt > 0 and dt < 5 then Perf.real = Perf.real + dt end
            if dt <= 0 or dt > 0.5 then dt = 0.016 end
            local ok2, e2 = pcall(tick, dt)
            if not ok2 then log("tick error: %s", tostring(e2)) end
            Perf.lua = Perf.lua + (os.clock() - c0)
            Perf.frames = Perf.frames + 1
            if Perf.real >= 15 then if PERF_LOG then pcall(perf_report) else Perf.frames, Perf.real, Perf.lua, Perf.hooks, Perf.by, Perf.sec = 0, 0, 0, 0, {}, {} end end
        end)
    end)
    if ok then tick_hooked = true; log("tick hooked to PlayerBP") else log("tick hook failed: %s", tostring(err)) end
end

-- Register hooks directly inside this (top-level registered) hook callback, NOT from
-- ExecuteWithDelay/LoopAsync: hooks registered from async callbacks get broken params in UE4SS 3.0.1.
-- A level is about to load (checkpoint reload, death, Load Game): every cached engine object is about
-- to be destroyed. Forget them all NOW; touching a stale pointer later (even IsValid) can crash the game.
function world_unloading()
    Game.loading = true
    Game.pc, Game.pawn = nil, nil
    HandScan.list, HandScan.at = {}, -100
    for k in pairs(Puppets) do Puppets[k] = nil end   -- the engine destroys the actors itself
    for k in pairs(Assets) do Assets[k] = nil end
    for k in pairs(F2A) do F2A[k] = nil end           -- figure assets may be garbage collected with the level
    for k in pairs(AssetRequested) do AssetRequested[k] = nil end   -- ...so they may need loading again
    Tint.base, Tint.mids, Tint.tries, Tint.next_try = nil, {}, 0, 0
    for _, h in ipairs(Handlers.unload) do pcall(h) end
    log("level loading: cleared cached objects")
end
-- NOTE: RegisterLoadMapPreHook crashes this game on startup with UE4SS 3.0.1, so it is NOT used.
-- Instead we notice the new world when the new player spawns (nothing ticks during a level load).

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    -- fresh lookup of the current world (never through a cached object)
    local w = try(function() local wo = SafeUE.world(); return wo and tostring(wo:GetAddress()) end)
    if w and Game.world_addr and w ~= Game.world_addr then world_unloading() end
    if w then Game.world_addr = w end
    Game.dead = false
    if Game.loading then log("level loaded: resuming") end
    Game.loading = false
    Game.pc = nil
    hook_tick()
    for _, h in ipairs(Handlers.restart) do
        local ok, err = pcall(h)
        if not ok then log("module restart error: %s", tostring(err)) end
    end
end)
-- if we were hot-reloaded while already in game
ExecuteWithDelay(1500, function() ExecuteInGameThread(function()
    if valid(FindFirstOf("PlayerBP_C")) then hook_tick() end
end) end)

------------------------------------------------------------- console commands
local function status_text()
    local names = {}
    for id, p in pairs(Net.players) do names[#names + 1] = ("%d:%s"):format(id, p.name or "?") end
    return ("PoppyCoop %s | mode=%s room=%s lead=%s name=%s | helper=%s id=%d status=%s rtt=%dms | players: %s | map=%s"):format(
        VERSION, Config.mode, tostring(Config.room), tostring(Coop.is_host()), Config.name, Net.connected and "up" or "down", Net.myid, Net.status, Net.rtt or -1,
        table.concat(names, ", "), Game.map)
end

local function restart_net()
    if Net.connected then pcall(function() Net.up:write("QUIT\n"); Net.up:flush() end) end
    net_close()
    for id in pairs(Puppets) do destroy_puppet(id) end
    Net.players, Net.myid, Net.status = {}, -1, "offline"
    Net.launched_at, Net.last_try = -100, -100
end

local function reply(out, s) log("%s", s); pcall(function() out:Log(s) end) end

RegisterConsoleCommandHandler("coop_status", function(_, _, out) reply(out, status_text()); return true end)
RegisterConsoleCommandHandler("coop_host", function(_, params, out)
    restart_net(); Config.mode = "host"; if params[1] then Config.name = params[1] end; save_config()
    reply(out, "hosting on port " .. Config.port .. " as " .. Config.name); return true
end)
RegisterConsoleCommandHandler("coop_join", function(full, params, out)
    -- the game console splits words like "Mushy_1" in its params list, so parse the raw line ourselves
    local toks = {}
    for w in tostring(full or ""):gmatch("%S+") do toks[#toks + 1] = w end
    if toks[1] and toks[1]:lower() == "coop_join" then table.remove(toks, 1) end
    if #toks > 0 then params = toks end
    if not params[1] then reply(out, "usage: coop_join <relay-or-ip[:port]> [name] [room]   e.g. coop_join poppycoop-relay.poppycoopnet.workers.dev Mushy public"); return true end
    -- prefer the URL from the full command line (params can be split on ':'), then normalize
    local raw = tostring(full or ""):match("(wss?://%S+)") or params[1]
    local addr = normalize_server(raw)
    if not addr then
        reply(out, "that address got cut off ('" .. tostring(raw) .. "'): the console drops text after '//'. Type it without wss://, e.g. coop_join poppycoop-relay.poppycoopnet.workers.dev Mushy public")
        return true
    end
    restart_net()
    Config.mode = "join"
    if is_relay(addr) then
        Config.host_ip = addr
    else
        local ip, port = addr:match("^([^:]+):?(%d*)$")
        Config.host_ip = ip or addr
        if port and port ~= "" then Config.port = tonumber(port) end
    end
    if params[2] then Config.name = params[2] end
    if params[3] then Config.room = params[3] end
    save_config()
    local shown = is_relay(Config.host_ip) and Config.host_ip or (Config.host_ip .. ":" .. Config.port)
    reply(out, ("joining %s room '%s' as %s"):format(shown, Config.room, Config.name)); return true
end)
RegisterConsoleCommandHandler("coop_tp", function(full, params, out)
    -- teleport to a friend: coop_tp [name]   (first other player if no name)
    local want = tostring(full or ""):match("^%S+%s+(%S+)")
    local pawn = Game.pawn
    if not valid(pawn) then reply(out, "not in game"); return true end
    for id, pl in pairs(Net.players) do
        local st = pl.state and parse_state(pl.state)
        if st and (not want or (pl.name or ""):lower() == want:lower()) then
            if st.map ~= Game.map then reply(out, (pl.name or "?") .. " is in a different map"); return true end
            pcall(function() pawn:K2_SetActorLocation({ X = st.x - 60, Y = st.y, Z = st.z + 30 }, false, {}, true) end)
            reply(out, "teleported to " .. (pl.name or ("player " .. id))); return true
        end
    end
    reply(out, want and ("no player named " .. want) or "nobody to teleport to")
    return true
end)

local function ghost_args(full)
    local toks = {}
    for w in tostring(full or ""):gmatch("%S+") do toks[#toks + 1] = w end
    table.remove(toks, 1)
    return toks[1], toks[2] and toks[2]:lower()
end
RegisterConsoleCommandHandler("coop_buddy", function(full, _, out)
    local n, c = ghost_args(full)
    if Ghost.buddy and not n then Ghost.keys[#Ghost.keys + 1] = "buddy"; reply(out, "buddy off"); return true end
    Ghost.buddy = nil; start_buddy(n, c); reply(out, "buddy on - walk around and it follows beside you (F7 toggles)"); return true
end)
RegisterConsoleCommandHandler("coop_record", function(_, _, out) Ghost.keys[#Ghost.keys + 1] = "record"; reply(out, "recording toggled (O)"); return true end)
RegisterConsoleCommandHandler("coop_play", function(full, _, out)
    local n, c = ghost_args(full); start_play(n, c); reply(out, "replay started (P toggles)"); return true
end)
local function place_args(toks, i)
    local name, colour, pose = toks[i], toks[i + 1] and toks[i + 1]:lower(), toks[i + 2] and toks[i + 2]:lower()
    return name or "Onyx", colour or "yellow", (pose == "stride" or pose == "run") and pose or "stand"
end
RegisterConsoleCommandHandler("coop_place", function(full, _, out)
    local toks = {}
    for w in tostring(full or ""):gmatch("%S+") do toks[#toks + 1] = w end
    local n, c, pose = place_args(toks, 2)
    local dist = tonumber(toks[5])
    Ghost.place_req[#Ghost.place_req + 1] = { name = n, colour = c, pose = pose, dist = dist and math.max(80, dist) or 200 }
    reply(out, ("placed %s (%s, %s) %d in front of you, facing you"):format(n, c, pose, dist or 200)); return true
end)
RegisterConsoleCommandHandler("coop_place_at", function(full, _, out)
    local toks = {}
    for w in tostring(full or ""):gmatch("%S+") do toks[#toks + 1] = w end
    local x, y, z, yaw = tonumber(toks[2]), tonumber(toks[3]), tonumber(toks[4]), tonumber(toks[5])
    if not (x and y and z) then reply(out, "usage: coop_place_at x y z yaw [name] [colour] [pose]"); return true end
    local n, c, pose = place_args(toks, 6)
    Ghost.place_req[#Ghost.place_req + 1] = { name = n, colour = c, pose = pose, x = x, y = y, z = z, yaw = yaw or 0 }
    reply(out, ("placed %s at %.0f %.0f %.0f"):format(n, x, y, z)); return true
end)
RegisterConsoleCommandHandler("coop_move", function(full, _, out)
    -- coop_move forward right up [turn]   (cm, relative to the way the last placed figure faces)
    local toks = {}
    for w in tostring(full or ""):gmatch("%S+") do toks[#toks + 1] = w end
    local f, r, u, t = tonumber(toks[2]) or 0, tonumber(toks[3]) or 0, tonumber(toks[4]) or 0, tonumber(toks[5]) or 0
    Ghost.move_req = Ghost.move_req or {}
    Ghost.move_req[#Ghost.move_req + 1] = { f = f, r = r, u = u, turn = t }
    reply(out, ("moved last placed figure: forward %g, right %g, up %g, turn %g"):format(f, r, u, t)); return true
end)
RegisterConsoleCommandHandler("coop_place_off", function(_, _, out)
    for id in pairs(Ghost.placed) do Net.players[id] = nil end
    Ghost.placed = {}; reply(out, "placed figures removed"); return true
end)
RegisterConsoleCommandHandler("coop_ghost_off", function(_, _, out) stop_ghosts(); reply(out, "ghosts removed"); return true end)
RegisterConsoleCommandHandler("coop_off", function(_, _, out)
    restart_net(); Config.mode = "off"; save_config(); reply(out, "co-op off"); return true
end)

------------------------------------------------------------------------ init
load_config()
log("v%s loaded from %s | chapter %d | mode=%s name=%s host=%s:%d", VERSION, MOD_DIR, CHAPTER, Config.mode, Config.name, Config.host_ip, Config.port)

-- Expose for sibling modules (doors/puzzles etc. live in separate files)
_G.PoppyCoop = { Coop = Coop, Net = Net, Game = Game, Config = Config, log = log, valid = valid, try = try, CHAPTER = CHAPTER, load_async = load_async,
                 Handlers = Handlers, MOD_DIR = MOD_DIR, Puppets = Puppets, Perf = Perf, game_time = function() return game_time end }
for _, m in ipairs({ "coop_world", "coop_extra" }) do
    local ok, err = pcall(require, m)
    if not ok and not tostring(err):find("not found") then log("module %s: %s", m, tostring(err)) end
end
