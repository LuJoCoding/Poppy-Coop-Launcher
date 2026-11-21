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

local VERSION = "1.5.9"   -- 1.5.6: Chapter 1 speedrun mode, shared checkpoints (Load Game -> furthest), keys and doors fixed; 1.5.5: merge of 1.5.0 (ch3-5 experimental, several games per PC) with chat menu/text boxes/solid friends/commands; 1.4.9: status key F11 (F10 is the console); 1.4.8: level-script lever sync, checkpoint follow, census perf, CH2 hand pose; 1.4.1: scan performance; 1.4.0: Launcher 3, CH2 props/minigames; 1.3.5: Chapter 1 pose/puzzle sync, crash fixes for streamed-out levels
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
        local pc = nil                                      -- fresh, used only right now
        for _, c in ipairs(FindAllOf("PlayerController") or {}) do
            if c:IsValid() and c.Pawn and c.Pawn:IsValid() then pc = c; break end
        end
        if not pc then return nil end
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
    -- after RestartLevel the old controller (no pawn) can still be found first and the GameInstance lookup
    -- returns nothing (seen in Chapter 1): take the controller that really has a pawn
    local ok2, pc2 = pcall(function()
        for _, c in ipairs(FindAllOf("PlayerController") or {}) do
            if c:IsValid() and c.Pawn and c.Pawn:IsValid() then return c end
        end
    end)
    SafeUE.gi = nil                                       -- look the GameInstance up again next time
    if ok2 and pc2 then return pc2 end
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

-- Which game window is this when several run on one PC? 0 = the first / only one.
-- POPPYCOOP_INSTANCE (set by a Nucleus handler or script), else a Nucleus "Instance<N>" folder in our path.
local SLOT = 0
do
    local v = os and os.getenv and tonumber(os.getenv("POPPYCOOP_INSTANCE") or "")
    if v then SLOT = math.max(0, math.floor(v))
    else
        local src = tostring(debug and debug.getinfo and debug.getinfo(1, "S").source or "")
        local n = src:lower():match("[\\/]instance(%d+)[\\/]")
        if n then SLOT = tonumber(n) or 0 end
    end
end

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
    for k, env in pairs({ name = "POPPYCOOP_NAME", room = "POPPYCOOP_ROOM", color = "POPPYCOOP_COLOR", tag = "POPPYCOOP_TAG" }) do
        local v = os and os.getenv and os.getenv(env)
        if v and v ~= "" then Config[k] = v end
    end
    -- Nucleus Co-op runs every game from its own "...\Instance<N>\" folder copy: window 2, 3... get
    -- "Name_2", "Name_3" and the next colour automatically (unless the launcher already set a name)
    if SLOT > 0 and not (os.getenv and os.getenv("POPPYCOOP_NAME")) then
        Config.name = tostring(Config.name):sub(1, 20) .. "_" .. tostring(SLOT + 1)
        if not (os.getenv and os.getenv("POPPYCOOP_COLOR")) then
            local cols = { "yellow", "orange", "pink", "purple", "green", "teal", "blue" }   -- launcher order
            local ci = 1
            for i, c in ipairs(cols) do if c == tostring(Config.color) then ci = i end end
            Config.color = cols[(ci - 1 + SLOT) % #cols + 1]
        end
    end
    Config.name = tostring(Config.name):gsub("[^%w_%-]", "_"):sub(1, 24)
    -- launcher "Speedrun mode": only what a run needs is shared (doors/switches/puzzles, inventory, hands,
    -- checkpoints), everything costly or distracting is off, performance mode on
    -- (the launcher sets the switches when speedrun mode is turned on; what the player then changes there wins,
    -- so only the settings the launcher has no switch for are set here)
    if Config.speedrun == true then
        local SPEEDRUN = { footsteps = false, boost = false, share_checkpoints = true }
        for k, v in pairs(SPEEDRUN) do if Config[k] == nil then Config[k] = v end end
    end
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
-- bug-report recorder: the last ~5 minutes of your own state (every 0.5 s) and every event received, kept in a
-- ring buffer; "/report" in the chat writes it to bugreport.txt (the launcher's problem report includes it)
Net.rec, Net.rec_i = {}, 0
function Net.rec_add(line)
    Net.rec_i = Net.rec_i % 3000 + 1
    Net.rec[Net.rec_i] = line
end

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
-- Chapters 3+ (experimental): the launcher writes chapter=N into config.txt; their exe names aren't known here.
local function config_chapter()
    local f = io.open(MOD_DIR .. "\\config.txt", "r")
    if not f then return nil end
    local n
    for line in f:lines() do n = n or tonumber(line:match("^%s*chapter%s*=%s*(%d+)")) end
    f:close()
    return n
end
local CHAPTER
if file_exists("Poppy_Playtime-Win64-Shipping.exe") then CHAPTER = 1
elseif MOD_DIR:lower():find("playtime_prototype4", 1, true) or file_exists("Playtime_Prototype4-Win64-Shipping.exe") then CHAPTER = 2
else CHAPTER = config_chapter() or 1 end
if os.getenv and tonumber(os.getenv("POPPYCOOP_CHAPTER") or "") then CHAPTER = tonumber(os.getenv("POPPYCOOP_CHAPTER")) end   -- testing
-- experimental chapters: players, teleport, ping, chat only (no chapter-specific code runs)
local EXPERIMENTAL = CHAPTER >= 3
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
    local tag = ((os.getenv and os.getenv("POPPYCOOP_NAME")) or SLOT > 0) and ("_" .. tostring(Config.name):gsub("[^%w_%-]", "_")) or ""
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
    if Net.was_lost then
        Net.was_lost = false
        local P2 = _G.PoppyCoop
        if P2 and P2.popup then pcall(P2.popup, "Reconnected", "join") end
    end
end

local Handlers = { event = {}, join = {}, leave = {}, tick = {}, restart = {}, unload = {}, state = {} }   -- module hooks

-- Freeze hunting (developers, crumbs_on.txt): before each block that calls into the engine, the block's
-- name is written to crumb_<name>.txt (overwritten, flushed). When a game freezes, that file names the
-- exact place. Off for players.
local Crumb = { on = nil, frame = 0, path = nil }
local function crumb(label)
    if Crumb.on == false then return end
    if Crumb.on == nil then
        local f = io.open(MOD_DIR .. "\\crumbs_on.txt", "r")
        Crumb.on = f ~= nil
        if f then f:close() end
        if not Crumb.on then return end
    end
    Crumb.path = Crumb.path or (MOD_DIR .. "\\crumb_" .. tostring(Config.name) .. ".txt")
    local f = io.open(Crumb.path, "w")              -- open/write/close: flush alone left the file empty
    if not f then return end
    f:write(("f%d %s %s\n"):format(Crumb.frame, os.date("%H:%M:%S"), tostring(label)))
    f:close()
end

-- LATE QUEUE. Anything that touches skeletal-mesh animation (PlayAnimation, SetAnimationMode, GetPosition,
-- GetSocketLocation on an animated mesh...) must NOT run inside the player's tick: it waits for the engine's
-- parallel animation tasks while UE4SS holds its lock, and those tasks call ProcessEvent, which needs the
-- same lock -> deadlock, the game freezes (proven with a debugger). Such work is queued here and run from
-- the crosshair widget's Tick (Chapter 1: CrosshairUI_C, on screen during gameplay). Widgets tick in the
-- UI pass after the whole world tick, when all animation tasks of the frame are finished. (HUD draw was
-- tried first: this game never fires it.) Without a crosshair the queue just stays small.
local Late = { jobs = {}, hooked = false, every = {} }
local function late(fn, label)
    -- Chapter 2 has no late hook (and never froze like this): run right away, as before
    if CHAPTER ~= 1 then pcall(fn); return end
    if #Late.jobs >= 64 then table.remove(Late.jobs, 1) end
    Late.jobs[#Late.jobs + 1] = { fn, label }
end
local function late_run()
    -- the crosshair widget can tick in a NEW world (respawn / Load Game) before the player tick has noticed
    -- it: queued jobs hold objects of the old world - drop them, and clear every cache first
    local G0 = _G.PoppyCoop and _G.PoppyCoop.Game        -- (Game is declared further down in this file)
    if G0 and G0.world_check and not G0.world_check() then Late.jobs = {}; return end
    Late.runs = (Late.runs or 0) + 1
    local c0 = os.clock()
    local jobs = Late.jobs
    Late.jobs = {}
    for _, j in ipairs(jobs) do
        crumb("late " .. tostring(j[2]))
        local ok, err = pcall(j[1])
        if not ok then log("late job %s: %s", tostring(j[2]), tostring(err)) end
    end
    for _, h in ipairs(Late.every) do
        crumb("late every " .. tostring(h[2]))
        local ok, err = pcall(h[1])
        if not ok then log("late %s: %s", tostring(h[2]), tostring(err)) end
    end
    crumb("late done")
    local P0 = _G.PoppyCoop
    if P0 and P0.Perf then P0.Perf.sec.late = (P0.Perf.sec.late or 0) + os.clock() - c0; P0.Perf.lua = P0.Perf.lua + os.clock() - c0 end
end
local LATE_HOOK = "/Game/Assets/Widgets/CrosshairUI.CrosshairUI_C:Tick"
local function late_hook()
    if Late.hooked or CHAPTER ~= 1 then return end
    if Late.next_try and os.clock() < Late.next_try then return end
    Late.next_try = os.clock() + 2
    if not StaticFindObject("/Game/Assets/Widgets/CrosshairUI.CrosshairUI_C") then return end   -- not loaded yet
    local ok, err = pcall(RegisterHook, LATE_HOOK, function() late_run() end)
    Late.hooked = ok
    log("late queue (crosshair tick): %s", ok and "on" or ("FAILED " .. tostring(err)))
end

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
        local parts = { payload }
        if payload:sub(1, 5) == "bulk " then
            parts = {}
            for part in (payload:sub(6) .. "\30"):gmatch("([^\30]*)\30") do parts[#parts + 1] = part end
        end
        for _, pl in ipairs(parts) do
            local kind, rest = pl:match("^(%S+)%s?(.*)$")
            Net.rec_add(("%.2f R %s %s"):format(game_time, tostring(id), pl:sub(1, 200)))
            local h = kind and Handlers.event[kind]
            if h then
                crumb("event " .. tostring(kind) .. " " .. tostring(rest):sub(1, 80))
                local ok, err = pcall(h, id, rest)
                if not ok then log("event %s failed: %s", kind, tostring(err)) end
            end
        end
    elseif k == "J" then
        crumb("join " .. line:sub(1, 60))
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

-- The helper (PoppyCoopNet.exe, no source) keeps unacknowledged reliable messages in a small queue per link;
-- when it is full it DROPS everything after that ("reliable queue full" in net_*.log). A (re)join made every
-- module send its whole history at once (hundreds of poses, props, ledger events), which overflowed it and
-- lost doors/levers/items for good. So messages are packed: consecutive messages to the same target go into
-- one "bulk" message (up to BULK_BYTES, parts separated by \30), and at most BULK_PER_POLL go out per poll -
-- the rest waits for the next poll, in order.
Net.BULK_BYTES, Net.BULK_PER_POLL, Net.BULK_SEP = 1400, 3, "\30"     -- (main.lua is at Lua's 200-locals limit)
function Net.pack_outbox()
    local BULK_BYTES, BULK_PER_POLL, BULK_SEP = Net.BULK_BYTES, Net.BULK_PER_POLL, Net.BULK_SEP
    local out, i, n = {}, 1, #Net.outbox
    while i <= n and #out < BULK_PER_POLL do
        local line = Net.outbox[i]
        local head, body = line:match("^(R) (.*)$")
        if not head then head, body = line:match("^(D %d+) (.*)$") end
        if not head or #line > BULK_BYTES or body:find(BULK_SEP, 1, true) then
            out[#out + 1] = line; i = i + 1
        else
            local parts, size = { body }, #body
            i = i + 1
            while i <= n do
                local l2 = Net.outbox[i]
                if l2:sub(1, #head + 1) ~= head .. " " then break end
                local b2 = l2:sub(#head + 2)
                if b2:find(BULK_SEP, 1, true) or size + #b2 + 1 > BULK_BYTES then break end
                parts[#parts + 1] = b2; size = size + #b2 + 1
                i = i + 1
            end
            out[#out + 1] = #parts == 1 and line or (head .. " bulk " .. table.concat(parts, BULK_SEP))
        end
    end
    local rest = {}
    for k = i, n do rest[#rest + 1] = Net.outbox[k] end
    Net.outbox = rest
    if #rest > 2000 then log("network: %d messages waiting to be sent", #rest) end
    return out
end

-- One synchronous round trip with the helper. state_line may be nil.
local function net_poll(state_line)
    if not Net.connected then return end
    local ok, err = pcall(function()
        if state_line then Net.up:write("S ", state_line, "\n") end
        for _, l in ipairs(Net.pack_outbox()) do Net.up:write(l, "\n") end
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
        local P2 = _G.PoppyCoop
        if P2 and P2.popup then pcall(P2.popup, "Connection lost - reconnecting...", "warn") end
        Net.was_lost = true
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
    -- only players whose game is really there count: after a crash the dead game's connection lingers in the
    -- room for ~30 s (same name, no state updates). With it as the "lead", nobody sent the world history to
    -- the player who came back, and everything done before was missing for them.
    for id, pl in pairs(Net.players) do
        local alive = pl.state_time and game_time - pl.state_time < 3
        if id < Net.myid and alive and pl.name ~= Config.name then return false end
    end
    return true
end
function Coop.active() return Net.connected and Net.myid >= 0 end

------------------------------------------------------------------- game side
local Game = { pc = nil, pawn = nil, map = "?", world = nil }

local function refresh_player()
    local pc = SafeUE.player_controller()                -- fresh every time (crash fix)
    Game.why = pc and "safe" or "safe-nil"
    if not pc and valid(Game.tick_pawn) then             -- after RestartLevel the lookups above can fail
        pc = try(function() local c = Game.tick_pawn:GetController(); return c:IsValid() and c or nil end)
        Game.why = pc and "tickpawn" or "tickpawn-nil"
    elseif not pc then Game.why = "safe-nil, no tick pawn (" .. tostring(Game.tick_pawn) .. ")" end
    Game.pc = pc
    if not pc then Game.pawn = nil; return false end
    local pawn = try(function() return pc.Pawn end)
    -- experimental chapters run without the player blueprint's tick: a menu / camera pawn has no movement
    -- component (calling it logs an engine error every frame), so only a real walking character counts
    if EXPERIMENTAL and valid(pawn) and not valid(try(function() return pawn.CharacterMovement end)) then pawn = nil end
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
-- Chapter 2 hands (like Chapter 1): the flying part of an ExtendoHand is its "Hand Rig" - the same handL_rig
-- mesh the figure carries - played by a single-node animation (open, grab...). Sent: the rig's world
-- position + rotation (L=x,y,z,pitch,yaw,roll,scale,...) and the animation asset + position (LA=path,pos*1000).
-- Animation reads happen at the late point (h2_pose_job): reading a skeletal mesh's animation inside an actor
-- tick waited on animation tasks and froze the game (bridges, see coop_extra).
local H2 = { pose = {}, job = false, logged = false }
local function h2_pose_job()
    H2.job = false
    local pawn = Game.pawn
    if not valid(pawn) then return end
    for _, h in ipairs(CH2_HANDS) do
        local v = nil
        pcall(function()
            local a = pawn[h.obj]
            if not a:IsValid() then return end
            local c = a["Hand Rig"]
            local ai = c.AnimScriptInstance
            if not ai or ai:GetAddress() == 0 then return end
            local as = ai.CurrentAsset
            if as and as:GetAddress() ~= 0 then
                local path = as:GetFullName():match("^%S+ (.+)$")
                if path and not path:find("[%s,]") then v = ("%s,%d"):format(path, math.floor(c:GetPosition() * 1000 + 0.5)) end
            end
        end)
        H2.pose[h.tag] = v
        if v and not H2.logged then H2.logged = true; log("hand pose sync: %s", v) end
    end
end
-- the real cable (Extendo_Rope "Rope Points Array": launcher end, corners it wraps around, hand end): only the
-- corners are sent - points near the launcher or the hand are left out
function H2.rope_corners(pawn, tag, hand)
    local r = try(function() local x = pawn["ExtendoRope " .. tag]; return x:IsValid() and x or nil end)
    if not r then return nil end
    local pts = {}
    pcall(function()
        r["Rope Points Array"]:ForEach(function(_, e) local v = e:get(); pts[#pts + 1] = { v.X, v.Y, v.Z } end)
    end)
    if #pts < 3 then return nil end
    local first = pts[1]
    local out = {}
    for i = 2, #pts - 1 do
        local v = pts[i]
        local d1 = (v[1] - first[1]) ^ 2 + (v[2] - first[2]) ^ 2 + (v[3] - first[3]) ^ 2
        local d2 = (v[1] - hand.X) ^ 2 + (v[2] - hand.Y) ^ 2 + (v[3] - hand.Z) ^ 2
        if d1 > 40 * 40 and d2 > 40 * 40 and #out < 8 then out[#out + 1] = ("%.0f,%.0f,%.0f"):format(v[1], v[2], v[3]) end
    end
    return #out > 0 and table.concat(out, ";") or nil
end
local function hand_tokens_ch2(pawn, loc)
    local out = ""
    local any = false
    for _, h in ipairs(CH2_HANDS) do
        local a = try(function() return pawn[h.obj] end)
        if a and valid(a) then
            local rig = try(function() local c = a["Hand Rig"]; return c:IsValid() and c or nil end)
            local hl, hr, sc
            if rig then
                pcall(function() hl, hr, sc = rig:K2_GetComponentLocation(), rig:K2_GetComponentRotation(), rig:K2_GetComponentScale() end)
            end
            -- the ExtendoHand actor stays at the launcher; its "Hand Pivot" component is what flies
            hl = hl or try(function() return a["Hand Pivot"]:K2_GetComponentLocation() end)
                or try(function() return a.Palm:K2_GetComponentLocation() end)
            if hl then
                local dx, dy, dz = hl.X - loc.X, hl.Y - loc.Y, hl.Z - loc.Z
                local d2 = dx * dx + dy * dy + dz * dz
                -- the ExtendoHand actor only exists while the hand is out: send it from the first frame
                if d2 > 20 * 20 and d2 < 4000 * 4000 then
                    if hr and sc then
                        out = out .. (" %s=%.0f,%.0f,%.0f,%d,%d,%d,%d,100,0,0"):format(h.tag, hl.X, hl.Y, hl.Z,
                            math.floor(hr.Pitch + 0.5), math.floor(hr.Yaw + 0.5), math.floor(hr.Roll + 0.5), math.floor(math.abs(sc.X) * 1000 + 0.5))
                        local pose = H2.pose[h.tag]
                        if pose then out = out .. (" %sA=%s"):format(h.tag, pose) end
                        local corners = H2.rope_corners(pawn, h.tag, hl)
                        if corners then out = out .. (" %sP=%s"):format(h.tag, corners) end
                        -- power flowing through the cable (green hand carrying electricity)
                        local el = (tonumber(try(function() return pawn[h.tag .. " Rope Electricity Travel"] end)) or 0)
                            + (tonumber(try(function() return pawn[h.tag .. " In Rope Electricity Travel"] end)) or 0)
                        if el > 0.01 then out = out .. (" %sE=1"):format(h.tag) end
                        any = true
                    else
                        out = out .. (" %s=%.0f,%.0f,%.0f"):format(h.tag, hl.X, hl.Y, hl.Z)
                    end
                end
            end
        end
    end
    if any and not H2.job then H2.job = true; late(h2_pose_job, "hand_pose2") end
    if not any then H2.pose = {} end
    return out
end
-- runs at UE4SS's game-thread point (not inside an actor tick): reads the launched hands' bone transform
-- and grab state for the next state line
local function hand_pose_job()
    HandScan.job = false
    local pose = {}
    for _, e in ipairs(HandScan.list or {}) do
        local ok, v = pcall(function()
            if not e.a:IsValid() then return nil end
            local par = e.a:GetAttachParentActor()
            local name = par and par:IsValid() and par:GetFName():ToString() or ""
            if name:find("Gun", 1, true) then return nil end            -- resting on its launcher
            local sk = e.a.SK_Hand
            local bone = FName("Hand_L")
            local l, r, sc = sk:GetSocketLocation(bone), sk:GetSocketRotation(bone), sk:K2_GetComponentScale()
            local ai = sk.AnimScriptInstance
            local bits, dfp, th = 0, 100, 0
            if ai and ai:GetAddress() ~= 0 then
                bits = (ai["IsActive"] == true and 1 or 0) + (ai["IsTouched"] == true and 2 or 0) + (ai["IsSmacked"] == true and 4 or 0)
                dfp, th = tonumber(ai["Distance From Palm"]) or 100, tonumber(ai["Thickness"]) or 0
            end
            local hold = try(function() return e.a:GetIsGrabbing() end) == true or try(function() return e.a:GetIsHolding() end) == true
                or try(function() return e.a.bIsPulling end) == true
            if hold then bits = bits + 8 end
            return ("%.0f,%.0f,%.0f,%d,%d,%d,%d,%d,%d,%d"):format(l.X, l.Y, l.Z, math.floor(r.Pitch + 0.5), math.floor(r.Yaw + 0.5),
                math.floor(r.Roll + 0.5), math.floor(math.abs(sc.X) * 1000 + 0.5), math.floor(dfp + 0.5), math.floor(th * 10 + 0.5), bits)
        end)
        if ok and v then pose[e.slot] = v end
    end
    HandScan.pose = pose
end
local function hand_tokens(pawn, loc)
    if CHAPTER == 2 then
        local ok, s = pcall(hand_tokens_ch2, pawn, loc)
        return ok and s or ""
    end
    if HandScan.off then return "" end
    -- both hands found (they live as long as the pawn): look again only every 30 s; FindAllOf walks every
    -- engine object (~12 ms) and ran every 3 s
    if game_time - HandScan.at > ((#HandScan.list >= 2 and HandScan.owned) and 30 or 3) then scan_hands(pawn) end
    if HandScan.want and not HandScan.job then        -- bone + grab state of the real hands: read late
        HandScan.job = true
        late(function() hand_pose_job() end, "hand_pose")
    end
    HandScan.want = false
    local best = {}
    local ok, err = pcall(function()
        for _, e in ipairs(HandScan.list) do
            if e.a:IsValid() then
                local hl = e.a:K2_GetActorLocation()
                local dx, dy, dz = hl.X - loc.X, hl.Y - loc.Y, hl.Z - loc.Z
                local d2 = dx * dx + dy * dy + dz * dz
                if not best[e.slot] or (not HandScan.owned and d2 < best[e.slot].d2) then
                    best[e.slot] = { d2 = d2, x = hl.X, y = hl.Y, z = hl.Z, e = e }
                end
            end
        end
    end)
    if not ok then HandScan.off = true; log("grabpack hand sync disabled: %s", tostring(err)); return "" end
    local out = ""
    for slot, tag in pairs({ [0] = "L", [1] = "R" }) do
        local b = best[slot]
        if b and b.d2 < 2500 * 2500 then
            local e = b.e
            -- a resting hand hangs on its launcher (attached to the GunComponent); a launched one is
            -- detached - that catches short shots too, which the old distance test (> 1.7 m) missed
            local launched = nil
            if e then                                   -- only our own two hands exist in this game
                local par = try(function() local a = e.a:GetAttachParentActor(); return a and a:IsValid() and a:GetFName():ToString() or "" end)
                if par then launched = not par:find("Gun", 1, true) end
            end
            if launched == nil then launched = b.d2 > 170 * 170 end
            if launched then
                -- the real hand's pose is read at the safe game-thread point (hand_pose_job) and cached;
                -- reading a skeletal mesh inside this tick waited on its animation task and froze the game
                HandScan.want = true
                local hp = HandScan.pose and HandScan.pose[slot]
                local extra = hp and (" %s=%s"):format(tag, hp)
                out = out .. (extra or (" %s=%.0f,%.0f,%.0f"):format(tag, b.x, b.y, b.z))
            end
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
    -- Chapter 1: the GrabPack and the red hand are found during the chapter (64 no left hand, 128 no right)
    if CHAPTER == 1 then
        if try(function() return pawn["hasLeftHand?"] end) == false then flags = flags | 64 end
        if try(function() return pawn["hasRightHand?"] end) == false then flags = flags | 128 end
    end
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
    -- Chapter 1: never. A synchronous LoadAsset run from UE4SS's ExecuteInGameThread queue (inside a
    -- ProcessEvent) right after a level load is the prime suspect for the game freezes (all threads
    -- waiting); Chapter 1 has every mesh the figures use loaded anyway once the player has the GrabPack.
    if CHAPTER == 1 then return end
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
    -- the toy plastic with a "Tint" colour (both chapters): every colour comes out right with it
    "/Game/Assets/Materials/Environment_MATS/Instanced_Materials/yellowplastic_MATInst.yellowplastic_MATInst",
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
    cands[1] = BASE_CANDIDATES[1]
    local cached = color_cache_read().base or color_cache_read().yellow
    if cached and not bad_name(cached) then cands[#cands + 1] = cached end
    for i = 2, #BASE_CANDIDATES do cands[#cands + 1] = BASE_CANDIDATES[i] end
    for _, path in ipairs(cands) do
        local o = try(StaticFindObject, path)
        if valid(o) then Tint.base = o; break end
        if CHAPTER == 1 then load_async(path) end   -- loads in the background; found on a later try (Ch2 has other paths)
    end
    -- last resort, at most once per session: a loaded material named "...yellow..." (names only, cheap)
    -- (Chapter 2 has "PlayerMat_.." materials made for player figures: best match there)
    if not valid(Tint.base) and not EXPERIMENTAL and Tint.tries >= (CHAPTER == 2 and 2 or 4) and not Tint.scanned then
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
            -- Chapter 1's MI_Yellow also glows yellow ("Emissive Color"), which drowns the colour in the dark
            if ok then pcall(function() mid:SetVectorParameterValue(FName("Emissive Color"), { R = rgb[1] * 0.5, G = rgb[2] * 0.5, B = rgb[3] * 0.5, A = 1.0 }) end) end
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
local F2_CROUCH_DROP = 56          -- see f2_update: crouch animations lift the dummy's feet
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
    -- Chapter 1 (UE5) doesn't ship the mannequin or this hand rig: it uses its own GrabPack figure
    if F2_failed or CHAPTER ~= 2 then return false end
    if F2A.ok then return true end
    -- looking assets up is not free: at most twice a second while they load
    if F2A.next_try and game_time < F2A.next_try then return false end
    F2A.next_try = game_time + 0.5
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

-- rotator math (UE conventions) for turning a flying hand toward where it was shot
local function rot_axes(p, y, r)
    local SP, CP, SY, CY = math.sin(math.rad(p)), math.cos(math.rad(p)), math.sin(math.rad(y)), math.cos(math.rad(y))
    local SR, CR = math.sin(math.rad(r)), math.cos(math.rad(r))
    return { CP * CY, CP * SY, SP }, { SR * SP * CY - CR * SY, SR * SP * SY + CR * CY, -SR * CP },
           { -(CR * SP * CY + SR * SY), CY * SR - CR * SP * SY, CR * CP }
end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function axes_rot(X, Y, Z)
    local pitch = math.deg(math.atan(X[3], math.sqrt(X[1] * X[1] + X[2] * X[2])))
    local yaw = math.deg(math.atan(X[2], X[1]))
    local _, SYA = rot_axes(pitch, yaw, 0)
    local roll = math.deg(math.atan(dot(Z, SYA), dot(Y, SYA)))
    return pitch, yaw, roll
end
-- the hand's rest rotation (palm forward on the launcher) turned from "where the figure faces" to "where
-- the hand flies": shot at the floor, the palm faces the floor - like the real hands
local function aim_rotation(rr, face_yaw, dpitch, dyaw)
    local RX, RY, RZ = rot_axes(rr.p, rr.y, rr.r)
    local FX, FY, FZ = rot_axes(0, face_yaw, 0)
    local DX, DY, DZ = rot_axes(dpitch, dyaw, 0)
    local function turn(w)
        local u = { dot(w, FX), dot(w, FY), dot(w, FZ) }
        return { u[1] * DX[1] + u[2] * DY[1] + u[3] * DZ[1], u[1] * DX[2] + u[2] * DY[2] + u[3] * DZ[2], u[1] * DX[3] + u[2] * DY[3] + u[3] * DZ[3] }
    end
    return axes_rot(turn(RX), turn(RY), turn(RZ))
end

-- per frame: place the figure, pick its animation, fly the hands, recolour the green hand
-- one cylinder per cable segment; the first is the figure's own "cable" actor, more are spawned when the real
-- cable wraps around corners (kept hidden for later)
local Cab = { MAX_SEGS = 9 }
function Cab.seg(a, A, B)
    local lx, ly, lz = B[1] - A[1], B[2] - A[2], B[3] - A[3]
    local len = math.sqrt(lx * lx + ly * ly + lz * lz)
    if len < 3 then a:SetActorHiddenInGame(true); return end
    a:SetActorHiddenInGame(false)
    a:K2_SetActorLocationAndRotation({ X = (A[1] + B[1]) / 2, Y = (A[2] + B[2]) / 2, Z = (A[3] + B[3]) / 2 },
        { Pitch = 90 + math.deg(math.atan(lz, math.sqrt(lx * lx + ly * ly))), Yaw = math.deg(math.atan(ly, lx)), Roll = 0 }, false, {}, true)
    a:SetActorScale3D({ X = 0.025, Y = 0.025, Z = len / 100 })
end
function Cab.cable(p, tag, path, elec)
    local f = p.f2
    local segs = f["segs" .. tag]
    if not segs then
        segs = { f["cable" .. tag] }
        f["segs" .. tag] = segs
    end
    local need = path and (#path - 1) or 0
    if need > Cab.MAX_SEGS then need = Cab.MAX_SEGS end
    for i = #segs + 1, need do                     -- more corners than cylinders: spawn one more
        local cab = f2_spawn(F2A.sma, path[1][1], path[1][2], path[1][3])
        if not cab then break end
        pcall(function()
            local c = cab.StaticMeshComponent
            c:SetMobility(2)
            c:SetStaticMesh(F2A.cable)
            c:SetMaterial(0, f.cablemat or f2_tint(TARGET_RGB.black))
            c:SetCollisionEnabled(0)
            c:SetCastShadow(false)
        end)
        segs[i] = cab
        f["elec" .. tag] = nil              -- re-apply the cable colour below (also to the new segment)
        p.parts[#p.parts + 1] = cab
        p.paths[#p.parts] = try(function() return cab:GetFullName():match("^%S+ (.+)$") end)
    end
    -- powered cable glows green (the material is swapped only when the state changes)
    elec = elec and true or false
    if f["elec" .. tag] ~= elec then
        f["elec" .. tag] = elec
        if elec and not f.cable_on then f.cable_on = f2_tint({ 0.6, 4.0, 0.5 }) end
        if not f.cable_off then f.cable_off = f2_tint(TARGET_RGB.black) end
        local m = elec and f.cable_on or f.cable_off
        for _, a in ipairs(segs) do if valid(a) then pcall(function() a.StaticMeshComponent:SetMaterial(0, m) end) end end
    end
    for i, a in ipairs(segs) do
        if valid(a) then
            pcall(function()
                if i <= need then
                    local B = (i == need) and path[#path] or path[i + 1]
                    Cab.seg(a, path[i], B)
                else a:SetActorHiddenInGame(true) end
            end)
        end
    end
end

function Cab.flashlight(p, st, c, crouch)
    local f = p.f2
    local on = (st.flags & 4) ~= 0 and (st.flags & 16) == 0
    if on and not valid(f.light) and not f.light_failed then
        F2A.spot = F2A.spot or find_asset("/Script/Engine.SpotLight")
        local a = valid(F2A.spot) and f2_spawn(F2A.spot, c.x, c.y, c.z + 60)
        if a then
            local ok = pcall(function()
                local l = a.SpotLightComponent
                l:SetMobility(2)
                l:SetIntensity(4500)
                l:SetAttenuationRadius(2200)
                l:SetInnerConeAngle(12)
                l:SetOuterConeAngle(28)
                l:SetCastShadows(false)
                l:SetLightColor({ R = 1.0, G = 0.95, B = 0.85, A = 1.0 }, true)
            end)
            if ok then
                f.light = a
                p.parts[#p.parts + 1] = a           -- destroyed with the figure
                p.paths[#p.parts] = try(function() return a:GetFullName():match("^%S+ (.+)$") end)
            else f.light_failed = true; pcall(function() a:K2_DestroyActor() end) end
        elseif F2A.spot then f.light_failed = true end
    end
    if not valid(f.light) then return end
    pcall(function()
        f.light:SetActorHiddenInGame(not on)
        if on then
            f.light:K2_SetActorLocationAndRotation({ X = c.x, Y = c.y, Z = c.z + (crouch and 25 or 60) },
                { Pitch = st.pitch or 0, Yaw = st.yaw or c.yaw, Roll = 0 }, false, {}, true)
        end
    end)
end
-- footsteps of a walking/running figure: the player's own footstep sounds (Chapter 2), played at the figure
Cab.STEP_CUES = { walk = "/Game/Assets/SFX/Characters/Player/PlayerWalk/footsteps/concreteWalk_Cue.concreteWalk_Cue",
                    run = "/Game/Assets/SFX/Characters/Player/PlayerWalk/footsteps/concreteRun_Cue.concreteRun_Cue" }
function Cab.footsteps(p, c, spd, quiet, dt)
    if CHAPTER ~= 2 or Config.footsteps == false or Config.footsteps == "false" then return end
    if quiet or spd < 60 then p.step_t = 0; return end
    local run = spd > 330
    local every = run and 0.32 or 0.5
    p.step_t = (p.step_t or 0) + dt
    if p.step_t < every then return end
    p.step_t = 0
    local key = run and "step_run" or "step_walk"
    if not valid(F2A[key]) then F2A[key] = find_asset(Cab.STEP_CUES[run and "run" or "walk"]) end
    local cue = F2A[key]
    local gs = SafeUE.gameplay_statics()
    if not (valid(cue) and gs) then return end
    pcall(function()
        gs:PlaySoundAtLocation(Game.pawn, cue, { X = c.x, Y = c.y, Z = c.z - 85 }, { Pitch = 0, Yaw = 0, Roll = 0 }, 0.7, 1.0, 0.0, nil, nil, nil)
    end)
end
-- boost: an invisible block on the figure's head you can stand on (reach higher places together).
-- Off while the friend is dead/airborne; config boost=false turns it off.
function Cab.boost(p, st, c, crouch, dead)
    if Config.boost == false or Config.boost == "false" then
        -- switched off during the session (/solid off): park the blocks far below
        for _, k in ipairs({ "boost", "solid" }) do
            local a = p.f2[k]
            if valid(a) and not p.f2[k .. "_parked"] then
                p.f2[k .. "_parked"] = true
                pcall(function() a:K2_SetActorLocation({ X = c.x, Y = c.y, Z = c.z - 5000 }, false, {}, true) end)
            end
        end
        return
    end
    p.f2.boost_parked, p.f2.solid_parked = nil, nil
    local f = p.f2
    if not valid(f.boost) and not f.boost_failed then
        F2A.cube = F2A.cube or find_asset("/Engine/BasicShapes/Cube.Cube")
        if not valid(F2A.cube) then return end
        local a = f2_spawn(F2A.sma, c.x, c.y, c.z + 200)
        if not a then f.boost_failed = true; return end
        local ok = pcall(function()
            local m = a.StaticMeshComponent
            m:SetMobility(2)
            m:SetStaticMesh(F2A.cube)
            a:SetActorScale3D({ X = 0.45, Y = 0.45, Z = 0.08 })
            a:SetActorEnableCollision(true)
            m:SetCollisionProfileName(FName("BlockAllDynamic"), true)
            m:SetCollisionEnabled(3)
            a:SetActorHiddenInGame(true)
        end)
        if not ok then f.boost_failed = true; pcall(function() a:K2_DestroyActor() end); return end
        f.boost = a
        p.parts[#p.parts + 1] = a
        p.paths[#p.parts] = try(function() return a:GetFullName():match("^%S+ (.+)$") end)
    end
    if not valid(f.boost) then return end
    local off = dead or (p.air or 0) > 0.5
    pcall(function()
        f.boost:K2_SetActorLocation({ X = c.x, Y = c.y, Z = off and (c.z - 5000) or (c.z + (crouch and 30 or 92)) }, false, {}, true)
    end)
    Cab.solid(p, c, crouch, dead)
end
-- solid body: an invisible upright cylinder the size of the player's capsule (radius 35, 170 tall; crouched 110),
-- so you can't walk through a friend from any side. Off while they are dead.
function Cab.solid(p, c, crouch, dead)
    local f = p.f2
    if not valid(f.solid) and not f.solid_failed then
        F2A.cyl = F2A.cyl or find_asset("/Engine/BasicShapes/Cylinder.Cylinder")
        if not valid(F2A.cyl) then f.solid_failed = true; return end
        local a = f2_spawn(F2A.sma, c.x, c.y, c.z - 5000)
        if not a then f.solid_failed = true; return end
        local ok = pcall(function()
            local m = a.StaticMeshComponent
            m:SetMobility(2)
            m:SetStaticMesh(F2A.cyl)
            a:SetActorEnableCollision(true)
            m:SetCollisionProfileName(FName("BlockAllDynamic"), true)
            m:SetCollisionEnabled(3)
            a:SetActorHiddenInGame(true)
        end)
        if not ok then f.solid_failed = true; pcall(function() a:K2_DestroyActor() end); return end
        f.solid = a
        p.parts[#p.parts + 1] = a
        p.paths[#p.parts] = try(function() return a:GetFullName():match("^%S+ (.+)$") end)
    end
    if not valid(f.solid) then return end
    local h = crouch and 1.1 or 1.7
    if f.solid_h ~= h then
        f.solid_h = h
        pcall(function() f.solid:SetActorScale3D({ X = 0.7, Y = 0.7, Z = h }) end)
    end
    -- bottom 2 cm above the feet (c is the capsule centre, 88 above the feet standing, ~55 crouched)
    local feet = c.z - (crouch and 55 or 88)
    pcall(function()
        f.solid:K2_SetActorLocation({ X = c.x, Y = c.y, Z = dead and (c.z - 5000) or (feet + 2 + h * 50) }, false, {}, true)
    end)
end
_G.PoppyCoop_cab = Cab      -- dev tests
local function f2_update(p, st, c, dt, crouch, dead)
    local f = p.f2
    if not valid(f.body) then return end
    local air = (p.air or 0) > 0.5
    local spd = p.spd or 0
    local emote = p.emote_until and game_time < p.emote_until and not dead and not air and spd < 30 and p.emote
    if emote == "nod" then f2_play(f, math.floor(game_time * 4) % 2 == 0 and "cidle" or "idle", 1)   -- bob = nod / bow
    elseif emote == "cheer" then f2_play(f, "air", 1)                                               -- arms up
    elseif dead then f2_play(f, "down", 1)
    elseif air then f2_play(f, "air", 1)
    elseif crouch then
        if spd > 30 then f2_play(f, "cwalk", math.max(0.6, math.min(1.6, spd / 120))) else f2_play(f, "cidle", 1) end
    elseif spd > 330 then f2_play(f, "run", math.max(0.7, math.min(1.5, spd / 420)))
    elseif spd > 30 then f2_play(f, "walk", math.max(0.5, math.min(1.6, spd / 160)))
    else f2_play(f, "idle", 1) end
    Cab.footsteps(p, c, spd, air or dead or crouch, dt)
    pcall(function()
        -- the dummy's crouch animations lift the feet ~56 cm off the root (measured: ankles at 63-65 instead of
        -- 8) - lower the figure while they play, or a crouching player floats
        local lower = (f.anim == "cidle" or f.anim == "cwalk") and F2_CROUCH_DROP or 0
        f.body:K2_SetActorLocationAndRotation({ X = c.x, Y = c.y, Z = c.z - 88 - lower }, { Pitch = 0, Yaw = c.yaw - 90, Roll = 0 }, false, {}, true)
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
                    -- the game's flying right hand is the handL_rig mirrored on X (rig scale -0.3, 0.3, 0.3; measured).
                    -- We copy the real hand's rotation below, so our mirror has to be on the same axis.
                    pcall(function()
                        local sc = h:GetActorScale3D()
                        local a = math.abs(sc.Z)
                        h:SetActorScale3D({ X = tag == "R" and -a or a, Y = a, Z = a })
                    end)
                    f["free" .. tag] = true
                end
                local hx, hy, hz = rest.x + (tgt.x - rest.x) * e, rest.y + (tgt.y - rest.y) * e, rest.z + (tgt.z - rest.z) * e
                local vx, vy, vz = tgt.x - rest.x, tgt.y - rest.y, tgt.z - rest.z
                local rr = f["rrot" .. tag]
                local ap, ay, ar
                if tgt.rot then ap, ay, ar = tgt.rot[1], tgt.rot[2], tgt.rot[3]       -- the real hand rig's rotation
                else ap, ay, ar = aim_rotation(rr, c.yaw, math.deg(math.atan(vz, math.sqrt(vx * vx + vy * vy))), math.deg(math.atan(vy, vx))) end
                -- the real hand's animation (open / grab / hold): same asset and position on our hand rig
                if tgt.anim and tgt.anim ~= f["pose" .. tag] then
                    f["pose" .. tag] = tgt.anim
                    local path, pos = tgt.anim:match("^(.+),(%d+)$")
                    F2A.handanim = F2A.handanim or {}
                    local asset = path and F2A.handanim[path]
                    if path and not valid(asset) then asset = find_asset(path); F2A.handanim[path] = asset end
                    if valid(asset) then
                        pcall(function()
                            local sk = h.SkeletalMeshComponent
                            if f["panim" .. tag] ~= path then sk:PlayAnimation(asset, false); f["panim" .. tag] = path end
                            sk:SetPosition(tonumber(pos) / 1000, false)
                        end)
                    end
                end
                pcall(function()
                    h:K2_SetActorLocationAndRotation({ X = hx, Y = hy, Z = hz }, { Pitch = ap, Yaw = ay, Roll = ar }, false, {}, true)
                end)
                -- cable: thin black cylinders (100 tall along Z) from the launcher over the corners the real cable
                -- wraps around (sent as LP=...) to the hand
                local lift = 0
                pcall(function() lift = -F2_HAND.L[3] * g:GetActorScale3D().X end)   -- hand origin sits below the tube axis
                local path = { { rest.x, rest.y, rest.z + lift } }
                for _, cp in ipairs(e > 0.9 and tgt.corners or {}) do path[#path + 1] = cp end
                path[#path + 1] = { hx, hy, hz + lift }
                Cab.cable(p, tag, path, tgt.elec)
            elseif f["free" .. tag] then
                f2_hand_attach(p, tag)
                Cab.cable(p, tag, nil)
                if f["panim" .. tag] then       -- back on the launcher: open hand again (reference pose)
                    pcall(function() h.SkeletalMeshComponent:Stop() end)
                    pcall(function() h.SkeletalMeshComponent:SetPosition(0, false) end)
                    f["panim" .. tag], f["pose" .. tag] = nil, nil
                end
                if valid(cab) then pcall(function() cab:SetActorHiddenInGame(true) end) end
            end
        end
    end
    -- flashlight (state flag 4): a real spot light from the figure's head along the player's view (no shadows: cheap)
    Cab.flashlight(p, st, c, crouch)
    Cab.boost(p, st, c, crouch, dead)
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
    for tag, body in s:gmatch(" ([LR])=([%-%d,]+)") do
        local n = {}
        for v in body:gmatch("%-?%d+") do n[#n + 1] = tonumber(v) end
        if #n >= 3 then
            hands = hands or {}
            local h = { x = n[1], y = n[2], z = n[3] }
            if #n >= 10 then                    -- Chapter 1: rotation, size and grab state of the real hand
                h.rot = { math.max(-360, math.min(360, n[4])), math.max(-360, math.min(360, n[5])), math.max(-360, math.min(360, n[6])) }
                h.sc = math.max(0.02, math.min(2, n[7] / 1000))
                h.dist, h.thick, h.bits = math.max(0, math.min(1000, n[8])), math.max(0, math.min(1000, n[9])), n[10] & 15
            end
            h.anim = s:match(" " .. tag .. "A=(%S+)")          -- Chapter 2: hand animation "path,pos*1000"
            h.elec = s:find(" " .. tag .. "E=1", 1, true) ~= nil  -- Chapter 2: power flows through the cable
            local cs = s:match(" " .. tag .. "P=([%-%d,;]+)")   -- Chapter 2: corners the cable wraps around
            if cs then
                h.corners = {}
                for x, y, z in cs:gmatch("(%-?%d+),(%-?%d+),(%-?%d+)") do
                    if #h.corners < 8 then h.corners[#h.corners + 1] = { tonumber(x), tonumber(y), tonumber(z) } end
                end
            end
            hands[tag] = h
        end
    end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw), pitch = tonumber(pitch),
             flags = tonumber(flags), map = map, color = colour, hands = hands,
             cp = tonumber(s:match(" C=(%-?%d+)")) }        -- checkpoint the sender's world is at (coop_world)
end

------------------------------------------------------------ Chapter 1 GrabPack figure
-- Chapter 1 has no mannequin, so its figure keeps the shape body - but carries the real GrabPack:
-- backpack, both launchers and the real hands. The launcher and hand meshes share the first-person
-- GrabPack frame (the hand sits exactly where it sits in your own view), so both are placed with one
-- common transform per side; the right side is the same set mirrored. Hands fly like in Chapter 2.
local G1_MESH = {
    gun = "/Game/Assets/Meshes/hand_launcher/hand_launcher_L_gun.hand_launcher_L_gun",
    hand = "/Game/Assets/Meshes/hand_launcher/hand_launcher_L_hand.hand_launcher_L_hand",
    bpk = "/Game/Assets/Meshes/hand_launcher/hand_launcher_backpack.hand_launcher_backpack",
}
local G1S, G1B = 0.33, 0.40                         -- scale of launcher/hand set and of the backpack
local G1_GUN = { 65.0, 123.6, -15.1 }               -- mesh-local centres in the first-person frame
local G1_TIP = { 65.0, 168.3, -4.0 }                -- front end of the launcher tube, on its axis (the grip pulls the bounds centre down)
local G1_HAND = { 55.6, 199.5, 39.3 }
local G1_BPK = { 0.0, 27.3, -6.9 }
-- in first person the hand floats ~10 cm ahead of the tube (perspective hides it); from outside it
-- belongs on the tube end: move it back, a little outward and down (mesh-local units)
local G1_SHIFT = { 1.4, -26.0, -3.0 }
local G1A = {}
local function g1_ready()
    if CHAPTER ~= 1 then return false end
    if G1A.ok then return true end
    if G1A.next_try and game_time < G1A.next_try then return false end
    G1A.next_try = game_time + 0.5
    local all = true
    for k, path in pairs(G1_MESH) do
        if not valid(G1A[k]) then G1A[k] = find_asset(path) end
        if not valid(G1A[k]) then all = false end
    end
    G1A.ok = all or nil
    return all
end
-- parts of the shape figure that the real GrabPack replaces in Chapter 1
local function g1_replaced(d)
    return d[2] == TEAL or (d[10] == "arm" and d[1] == "b") or d[2] == BROWN or d[10] == "cable"
        or (d[1] == "b" and d[2] == RED and d[10] == nil)                    -- backpack box
end
-- the game's own animated hand (SK_LeftHand + ABP_Hand, mirrored for the right): shown while a hand
-- flies, with the sender's exact transform and grab state. Optional - without it the static hand flies.
local G1_SK = { mesh = "/Game/Player/New_Hands/SK_LeftHand.SK_LeftHand", abp = "/Game/Player/New_Hands/ABP_Hand.ABP_Hand_C",
                ska = "/Script/Engine.SkeletalMeshActor" }
local G1K = {}
-- OFF: everything animation-related called from Lua (SetAnimationMode, GetSocketLocation on an animated
-- hand, PlayAnimation...) waits for the engine's parallel animation tasks while UE4SS holds its lock -
-- and those tasks call ProcessEvent, which needs the same lock: deadlock, the game freezes (proven with
-- a debugger, 2026-11-17). Comes back only from a hook that runs after animation has finished.
local G1_SK_ON = true          -- back on: everything animation-related runs from the late queue
local function g1_sk_ready()
    if not G1_SK_ON then return false end
    if G1K.ok then return true end
    if G1K.next_try and game_time < G1K.next_try then return false end
    G1K.next_try = game_time + 1.0
    local all = true
    for k, path in pairs(G1_SK) do
        if not valid(G1K[k]) then G1K[k] = find_asset(path) end
        if not valid(G1K[k]) then all = false end
    end
    G1K.ok = all or nil
    return all
end
local function g1_sk_spawn(p)
    local g = p.g1
    local world = UEHelpers.GetWorld()
    if not valid(world) then return end
    local n = 0
    for k in pairs(p.parts) do n = math.max(n, k) end
    for _, side in ipairs({ "L", "R" }) do
        local c0 = p.cur or { x = 0, y = 0, z = 0 }
        local a = try(function() return world:SpawnActor(G1K.ska, { X = c0.x, Y = c0.y, Z = c0.z }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        if valid(a) then
            pcall(function() a:SetActorEnableCollision(false) end)
            pcall(function()
                local c = a.SkeletalMeshComponent
                c:SetSkeletalMeshAsset(G1K.mesh)
                c:SetCollisionEnabled(0)
                -- SetAnimInstanceClass fails here (engine error): set the property; the anim instance is
                -- created when the hand is first shown (g1_anim_safe)
                c.AnimClass = G1K.abp
            end)
            -- same colour as the static hand
            pcall(function() a.SkeletalMeshComponent:SetMaterial(0, g["hand" .. side].StaticMeshComponent:GetMaterial(0)) end)
            pcall(function() a:SetActorHiddenInGame(true) end)
            g["skh" .. side] = a
            n = n + 1
            p.parts[n] = a
            p.paths[n] = try(function() return a:GetFullName():match("^%S+ (.+)$") end)
        end
    end
    g.sk = true
end
-- place the animated hand so that its hand bone has the sent world transform: read where the bone sits
-- relative to the component in the current pose, then put the component there
local G1_BONE = nil
local function g1_sk_place(g, side, a, bx, by, bz, rot)
    G1_BONE = G1_BONE or FName("Hand_L")
    local c = a.SkeletalMeshComponent
    local cl, cr = c:K2_GetComponentLocation(), c:K2_GetComponentRotation()
    local bl, br = c:GetSocketLocation(G1_BONE), c:GetSocketRotation(G1_BONE)
    local CX, CY, CZ = rot_axes(cr.Pitch, cr.Yaw, cr.Roll)
    local BX, BY, BZ = rot_axes(br.Pitch, br.Yaw, br.Roll)
    local C, B = { CX, CY, CZ }, { BX, BY, BZ }
    -- bone relative to the component (rotation and offset, component axes)
    local rel = {}
    for j = 1, 3 do rel[j] = {} for k = 1, 3 do rel[j][k] = dot(C[j], B[k]) end end
    local d = { bl.X - cl.X, bl.Y - cl.Y, bl.Z - cl.Z }
    local v = { dot(C[1], d), dot(C[2], d), dot(C[3], d) }
    -- wanted component axes: sent bone axes combined with the inverse relative rotation
    local SX, SY, SZ = rot_axes(rot[1], rot[2], rot[3])
    local S = { SX, SY, SZ }
    local N = {}
    for j = 1, 3 do
        N[j] = { 0, 0, 0 }
        for k = 1, 3 do for i = 1, 3 do N[j][i] = N[j][i] + S[k][i] * rel[j][k] end end
    end
    local np, ny, nr = axes_rot(N[1], N[2], N[3])
    local ox = bx - (N[1][1] * v[1] + N[2][1] * v[2] + N[3][1] * v[3])
    local oy = by - (N[1][2] * v[1] + N[2][2] * v[2] + N[3][2] * v[3])
    local oz = bz - (N[1][3] * v[1] + N[2][3] * v[2] + N[3][3] * v[3])
    a:K2_SetActorLocationAndRotation({ X = ox, Y = oy, Z = oz }, { Pitch = np, Yaw = ny, Roll = nr }, false, {}, true)
end
-- Animation calls (SetAnimationMode, PlayAnimation...) made inside the player's tick, while the engine
-- evaluates animations in parallel, are the prime suspect for two full game freezes (all threads
-- waiting on each other). Run them at UE4SS's game-thread point instead, outside any actor tick.
-- animation work goes to the late queue (see Late)
local function g1_anim_safe(fn, label)
    late(fn, label)
end
-- grab state of the animated hand: only written when it changes
local function g1_sk_anim(g, side, h)
    local key = string.format("%d %d %d", h.dist or 100, h.thick or 0, h.bits or 0)
    if g["skk" .. side] == key then return end
    g["skk" .. side] = key
    local a = g["skh" .. side]
    local hold = ((h.bits or 0) & 8) ~= 0                 -- holding on: closed hand
    pcall(function()
        local ai = a.SkeletalMeshComponent.AnimScriptInstance
        if not ai or ai:GetAddress() == 0 then return end
        ai["Distance From Palm"] = hold and 0 or (h.dist or 100)
        ai["Thickness"] = (h.thick or 0) / 10
        ai["IsActive"] = hold or ((h.bits or 0) & 1) ~= 0
        ai["IsTouched"] = hold or ((h.bits or 0) & 2) ~= 0
        ai["IsSmacked"] = ((h.bits or 0) & 4) ~= 0
    end)
end

local function g1_spawn(p, st)
    local g = {}
    for _, side in ipairs({ "L", "R" }) do
        local m = side == "L" and 1 or -1
        g["gun" .. side] = spawn_mesh(G1A.gun, st.x, st.y, st.z, G1S * m, G1S, G1S)
        local h = spawn_mesh(G1A.hand, st.x, st.y, st.z, G1S * m, G1S, G1S)
        if h then paint(h, side == "L" and BLUE or RED) end
        g["hand" .. side] = h
        local cab = spawn_mesh(Assets.body, st.x, st.y, st.z, 0.025, 0.025, 0.001)
        if cab then paint(cab, "black") end
        g["cable" .. side] = cab
    end
    g.bpk = spawn_mesh(G1A.bpk, st.x, st.y, st.z, G1B, G1B, G1B)
    local n = #FIGURE                       -- after the figure's own slots (some of them stay empty)
    for k in pairs(p.parts) do n = math.max(n, k) end
    for _, a in pairs(g) do
        n = n + 1
        p.parts[n] = a
        p.paths[n] = try(function() return a:GetFullName():match("^%S+ (.+)$") end)
    end
    p.g1 = g
end
-- figure-local point (x forward, y right, z up from the capsule centre) -> world
local function g1_world(c, x, y, z)
    local cy, sy = math.cos(math.rad(c.yaw)), math.sin(math.rad(c.yaw))
    return c.x + x * cy - y * sy, c.y + x * sy + y * cy, c.z + z
end
local function g1_show(a, show)
    if valid(a) then pcall(function() a:SetActorHiddenInGame(not show) end) end
end
local function g1_update(p, st, c, crouch)
    local g = p.g1
    -- only what the player really has: no GrabPack yet / no red hand yet
    local dead = (st.flags & 16) ~= 0                             -- lying figure: the pack would float
    local has = { L = not dead and (st.flags & 64) == 0, R = not dead and (st.flags & 128) == 0 }
    local vis = (has.L and 1 or 0) + (has.R and 2 or 0)
    if vis ~= g.vis then
        g.vis = vis
        for _, side in ipairs({ "L", "R" }) do
            g1_show(g["gun" .. side], has.L or has.R)          -- the pack carries both launchers
            g1_show(g["hand" .. side], has[side])
            g1_show(g["cable" .. side], has[side])
        end
        g1_show(g.bpk, has.L or has.R)
    end
    local ang = math.rad((p.aim or 0) + (p.air or 0) * 12)        -- arms follow the look pitch
    local dz = crouch and -30 or 0
    local function aimed(x, z)                                    -- rotate around the shoulder (z = 32)
        local dx, dzz = x, z - 32
        return dx * math.cos(ang) - dzz * math.sin(ang), 32 + dx * math.sin(ang) + dzz * math.cos(ang)
    end
    local rot = { Pitch = 0, Yaw = c.yaw - 90, Roll = -math.deg(ang) }
    for _, side in ipairs({ "L", "R" }) do
        local m = side == "L" and 1 or -1
        -- frame origin so that the launcher's centre lands at the arm's end (x 38, y -+26, z 32)
        local fx, fz = aimed(38 - G1_GUN[2] * G1S, 32 - G1_GUN[3] * G1S)
        local fy = -26 * m + G1_GUN[1] * G1S * m
        local ox, oy, oz = g1_world(c, fx, fy, fz + dz)
        local gun, hand, cab = g["gun" .. side], g["hand" .. side], g["cable" .. side]
        if valid(gun) then pcall(function() gun:K2_SetActorLocationAndRotation({ X = ox, Y = oy, Z = oz }, rot, false, {}, true) end) end
        -- where the hand rests and where the launcher tube ends, in world space
        local X, Y, Z = rot_axes(rot.Pitch, rot.Yaw, rot.Roll)
        local function w(v) return ox + X[1] * v[1] * G1S * m + Y[1] * v[2] * G1S + Z[1] * v[3] * G1S,
                                 oy + X[2] * v[1] * G1S * m + Y[2] * v[2] * G1S + Z[2] * v[3] * G1S,
                                 oz + X[3] * v[1] * G1S * m + Y[3] * v[2] * G1S + Z[3] * v[3] * G1S end
        local rx, ry, rz = w({ G1_HAND[1] + G1_SHIFT[1], G1_HAND[2] + G1_SHIFT[2], G1_HAND[3] + G1_SHIFT[3] })
        local sx, sy, sz = w(G1_SHIFT)                            -- the hand actor's origin at rest
        local tx, ty, tz = w(G1_TIP)
        local e, tgt = p.ext[side], p.hand[side]
        if valid(hand) then
            local skh = g["skh" .. side]
            local real = e > 0.03 and tgt and tgt.rot and valid(skh)
            if real ~= (g["skon" .. side] or false) then          -- swap static <-> animated hand
                g["skon" .. side] = real
                g1_show(skh, real)
                g1_show(hand, has[side] and not real)
                if real then
                    -- (re)start the hand animation now that it is visible: started while hidden at spawn
                    -- it doesn't run, and the grab pose then never shows
                    local comp = skh.SkeletalMeshComponent
                    g1_anim_safe(function() comp:SetAnimationMode(0) end, "SetAnimationMode")
                    g["skk" .. side] = nil
                end
            end
            if real then
                local hx, hy, hz = rx + (tgt.x - rx) * e, ry + (tgt.y - ry) * e, rz + (tgt.z - rz) * e
                local sc = tgt.sc or 0.15
                local trot = tgt.rot                                  -- placed outside the actor tick
                g1_anim_safe(function() if valid(skh) then g1_sk_place(g, side, skh, hx, hy, hz, trot) end end, "sk_place")
                if g["sksc" .. side] ~= sc then
                    g["sksc" .. side] = sc
                    pcall(function() skh:SetActorScale3D({ X = sc, Y = side == "R" and -sc or sc, Z = sc }) end)
                end
                local tcopy = { dist = tgt.dist, thick = tgt.thick, bits = tgt.bits }
                g1_anim_safe(function() if valid(skh) then g1_sk_anim(g, side, tcopy) end end, "sk_anim")
                if valid(cab) then
                    local lx, ly, lz = hx - tx, hy - ty, hz - tz
                    local len = math.sqrt(lx * lx + ly * ly + lz * lz)
                    pcall(function()
                        cab:K2_SetActorLocationAndRotation({ X = (tx + hx) / 2, Y = (ty + hy) / 2, Z = (tz + hz) / 2 },
                            { Pitch = 90 + math.deg(math.atan(lz, math.sqrt(lx * lx + ly * ly))), Yaw = math.deg(math.atan(ly, lx)), Roll = 0 }, false, {}, true)
                        cab:SetActorScale3D({ X = 0.025, Y = 0.025, Z = math.max(0.001, len / 100) })
                    end)
                end
            elseif e > 0.03 and tgt then
                local hx, hy, hz = rx + (tgt.x - rx) * e, ry + (tgt.y - ry) * e, rz + (tgt.z - rz) * e
                local vx, vy, vz = tgt.x - rx, tgt.y - ry, tgt.z - rz
                local ap, ay, ar = aim_rotation({ p = rot.Pitch, y = rot.Yaw, r = rot.Roll }, c.yaw,
                    math.deg(math.atan(vz, math.sqrt(vx * vx + vy * vy))), math.deg(math.atan(vy, vx)))
                local X2, Y2, Z2 = rot_axes(ap, ay, ar)
                local o2x = hx - (X2[1] * G1_HAND[1] * G1S * m + Y2[1] * G1_HAND[2] * G1S + Z2[1] * G1_HAND[3] * G1S)
                local o2y = hy - (X2[2] * G1_HAND[1] * G1S * m + Y2[2] * G1_HAND[2] * G1S + Z2[2] * G1_HAND[3] * G1S)
                local o2z = hz - (X2[3] * G1_HAND[1] * G1S * m + Y2[3] * G1_HAND[2] * G1S + Z2[3] * G1_HAND[3] * G1S)
                pcall(function() hand:K2_SetActorLocationAndRotation({ X = o2x, Y = o2y, Z = o2z }, { Pitch = ap, Yaw = ay, Roll = ar }, false, {}, true) end)
                if valid(cab) then
                    local lx, ly, lz = hx - tx, hy - ty, hz - tz
                    local len = math.sqrt(lx * lx + ly * ly + lz * lz)
                    pcall(function()
                        cab:K2_SetActorLocationAndRotation({ X = (tx + hx) / 2, Y = (ty + hy) / 2, Z = (tz + hz) / 2 },
                            { Pitch = 90 + math.deg(math.atan(lz, math.sqrt(lx * lx + ly * ly))), Yaw = math.deg(math.atan(ly, lx)), Roll = 0 }, false, {}, true)
                        cab:SetActorScale3D({ X = 0.025, Y = 0.025, Z = math.max(0.001, len / 100) })
                    end)
                end
            else
                pcall(function() hand:K2_SetActorLocationAndRotation({ X = sx, Y = sy, Z = sz }, rot, false, {}, true) end)
                if valid(cab) then pcall(function() cab:SetActorScale3D({ X = 0.025, Y = 0.025, Z = 0.001 }) end) end
            end
        end
    end
    -- backpack on the back
    if valid(g.bpk) then
        local bx, by, bz = g1_world(c, (p.m1 and -15 or -26) - G1_BPK[2] * G1B, 0, (p.m1 and 28 or 24) - G1_BPK[3] * G1B + dz)   -- the mannequin is slimmer
        pcall(function() g.bpk:K2_SetActorLocationAndRotation({ X = bx, Y = by, Z = bz }, { Pitch = 0, Yaw = c.yaw - 90, Roll = 0 }, false, {}, true) end)
    end
end

------------------------------------------------------------ Chapter 1 mannequin
-- The player is a faceless mannequin with a round head (the figure Chapter 2 ships, which Chapter 1
-- doesn't have). Chapter 1 builds it from the engine's sphere and cylinder: rounded chest and pelvis,
-- jointed arms and legs (knees and elbows solved with two-bone IK), walking, crouching, jumping and
-- lying down when dead. The arms hold the real GrabPack launchers (g1_*) or swing when there is none.
-- Points are figure-local: x forward, y right, z up from the capsule centre (the floor is z = -88).
local M1_PARTS = {   -- name, mesh ("s" sphere / "c" cylinder), thickness X, Y (cm)
    { "head", "s" }, { "neck", "c", 9, 9 }, { "chest", "s" }, { "waist", "c", 18, 26 }, { "pelvis", "s" },
    { "thighL", "c", 14, 14 }, { "thighR", "c", 14, 14 }, { "shinL", "c", 11, 11 }, { "shinR", "c", 11, 11 },
    { "kneeL", "s" }, { "kneeR", "s" }, { "footL", "s" }, { "footR", "s" },
    { "uarmL", "c", 10, 10 }, { "uarmR", "c", 10, 10 }, { "farmL", "c", 9, 9 }, { "farmR", "c", 9, 9 },
    { "elbowL", "s" }, { "elbowR", "s" }, { "fistL", "s" }, { "fistR", "s" }, { "shoulderL", "s" }, { "shoulderR", "s" },
}
local M1_LEG, M1_UARM, M1_FARM = 39, 27, 25          -- thigh = shin length; upper arm; forearm
local M1_GRIP = { 33, 30 }                           -- the launcher grip (x, z) the fists hold
local function m1_enabled() return CHAPTER == 1 and valid(Assets.head) and valid(Assets.body) end

local function m1_spawn(p, st, key)
    p.m1 = {}
    for i, d in ipairs(M1_PARTS) do
        local a = spawn_mesh(d[2] == "s" and Assets.head or Assets.body, st.x, st.y, st.z, 0.1, 0.1, 0.1)
        p.keys[i] = key
        if a and not paint(a, key) then p.unpainted = true end
        p.parts[i] = a
        p.paths[i] = a and try(function() return a:GetFullName():match("^%S+ (.+)$") end)
        p.m1[d[1]] = i
    end
end

-- two-bone IK in the side plane: from root (x, z) towards target, bend = +1 knee forward / -1 elbow down
local function m1_ik(rx, rz, tx, tz, l1, l2, bend)
    local dx, dz = tx - rx, tz - rz
    local d = math.sqrt(dx * dx + dz * dz)
    d = math.max(1, math.min(d, l1 + l2 - 0.5))
    local ux, uz = dx / math.max(1e-6, math.sqrt(dx * dx + dz * dz)), dz / math.max(1e-6, math.sqrt(dx * dx + dz * dz))
    local a = math.acos(math.max(-1, math.min(1, (l1 * l1 + d * d - l2 * l2) / (2 * l1 * d)))) * bend
    local jx, jz = rx + l1 * (ux * math.cos(a) - uz * math.sin(a)), rz + l1 * (ux * math.sin(a) + uz * math.cos(a))
    return jx, jz, rx + ux * d, rz + uz * d
end

-- SetActorScale3D only when the size really changes (most parts never change it): each engine call
-- costs ~0.05-0.1 ms, and the mannequin has 23 parts
local function m1_scale(p, name, a, x, y, z)
    p.m1s = p.m1s or {}
    local o = p.m1s[name]
    if o and math.abs(o[1] - x) < 0.002 and math.abs(o[2] - y) < 0.002 and math.abs(o[3] - z) < 0.002 then return end
    p.m1s[name] = { x, y, z }
    pcall(function() a:SetActorScale3D({ X = x, Y = y, Z = z }) end)
end
local function m1_update(p, st, c, crouch, dead, swing, bob, amount)
    -- nothing moved (standing still, same look pitch): skip all engine calls this frame
    local key = string.format("%.1f %.1f %.1f %.1f %.2f %.2f %.2f %.1f %s %s %d %s", c.x, c.y, c.z, c.yaw, swing, bob,
        p.air or 0, p.aim or 0, tostring(crouch), tostring(dead), st.flags, tostring(p.g1 ~= nil))
    if key == p.m1key then return false end
    p.m1key = key
    local cy, sy = math.cos(math.rad(c.yaw)), math.sin(math.rad(c.yaw))
    local function T(x, z)                                       -- dead: lying on the back
        if dead then return -(z + 88), -80 + x * 0.3 end
        return x, z
    end
    local function A(name) return part(p, p.m1[name]) end
    local function put(name, x, y, z, sx, sy2, sz, pitch)
        local a = A(name); if not a then return end
        local wx, wz = T(x, z)
        pcall(function()
            a:K2_SetActorLocationAndRotation({ X = c.x + wx * cy - y * sy, Y = c.y + wx * sy + y * cy, Z = c.z + wz },
                { Pitch = (pitch or 0) + (dead and -90 or 0), Yaw = c.yaw, Roll = 0 }, false, {}, true)
        end)
        m1_scale(p, name, a, sx / 100, sy2 / 100, sz / 100)
    end
    local function seg(name, ax, az, bx, bz, y)                  -- cylinder from a to b
        local d = M1_PARTS[p.m1[name]]
        local x1, z1 = T(ax, az); local x2, z2 = T(bx, bz)
        local dx, dz = x2 - x1, z2 - z1
        local len = math.sqrt(dx * dx + dz * dz)
        local a = A(name); if not a then return end
        local mx, mz = (x1 + x2) / 2, (z1 + z2) / 2
        pcall(function()
            a:K2_SetActorLocationAndRotation({ X = c.x + mx * cy - y * sy, Y = c.y + mx * sy + y * cy, Z = c.z + mz },
                { Pitch = math.deg(math.atan(-dx, dz)), Yaw = c.yaw, Roll = 0 }, false, {}, true)
        end)
        m1_scale(p, name, a, d[3] / 100, d[4] / 100, math.max(0.01, len / 100))
    end
    local up = (crouch and -30 or 0) + bob                       -- upper body offset
    -- torso
    put("head", 0, 0, 72 + up, 30, 30, 30)
    seg("neck", 0, 51 + up, 0, 60 + up, 0)
    put("chest", 0, 0, 34 + up, 22, 40, 36)
    seg("waist", 0, 8 + up * 0.6, 0, 20 + up * 0.8, 0)
    put("pelvis", 0, 0, (crouch and -26 or 0) + bob * 0.5, 22, 34, 20)
    -- legs
    local hipz = (crouch and -32 or -6) + bob * 0.5
    for _, s in ipairs({ { "L", -9, 1 }, { "R", 9, -1 } }) do
        local side, y, sg = s[1], s[2], s[3]
        local th = math.rad(swing * sg + p.air * (sg > 0 and 28 or -14))
        local reach = 2 * M1_LEG - (crouch and 0 or 0) - p.air * 18
        local tx, tz = reach * math.sin(th), hipz - reach * math.cos(th)
        local lift = math.max(0, math.cos(p.phase or 0) * sg) * 7 * amount
        if crouch then tx, tz = 6, -84 end
        tz = math.max(-84, tz) + lift * (crouch and 0 or 1)
        local kx, kz, ax, az = m1_ik(0, hipz, tx, tz, M1_LEG, M1_LEG, 1)
        seg("thigh" .. side, 0, hipz, kx, kz, y)
        seg("shin" .. side, kx, kz, ax, az, y)
        put("knee" .. side, kx, y, kz, 13, 13, 13)
        put("foot" .. side, ax + 6, y, az - 3, 26, 11, 8)
    end
    -- arms: on the GrabPack's launchers (same frame as g1_update), or hanging and swinging
    local grab = p.g1 and ((st.flags & 64) == 0 or (st.flags & 128) == 0)
    local ang = math.rad((p.aim or 0) + (p.air or 0) * 12)
    for _, s in ipairs({ { "L", -1 }, { "R", 1 } }) do
        local side, sg = s[1], s[2]
        local shx, shz, shy = 0, 46 + up, 23 * sg
        local tx, tz
        if grab then                                                 -- the launcher's grip
            local dx, dz = M1_GRIP[1], M1_GRIP[2] - 32
            tx, tz = dx * math.cos(ang) - dz * math.sin(ang), 32 + dx * math.sin(ang) + dz * math.cos(ang) + (crouch and -30 or 0)
        else
            local th = math.rad(-swing * (side == "L" and 1 or -1) * 0.8)
            tx, tz = shx + 48 * math.sin(th) + 4, shz - 48 * math.cos(th)
        end
        local ex, ez, wx, wz = m1_ik(shx, shz, tx, tz, M1_UARM, M1_FARM, -1)
        local wy = grab and 26 * sg or 25 * sg
        put("shoulder" .. side, shx, shy, shz, 13, 13, 13)
        seg("uarm" .. side, shx, shz, ex, ez, (shy + wy) / 2)
        seg("farm" .. side, ex, ez, wx, wz, wy)
        put("elbow" .. side, ex, (shy + wy) / 2, ez, 10, 10, 10)
        put("fist" .. side, wx, wy, wz, 11, 10, 11)
    end
end

local function update_puppets(dt)
    -- figures spawned before the paint was loaded: paint them as soon as it is (one pass, no rescans)
    for _, p in pairs(Puppets) do
        if p.unpainted and tint_base() then
            local left = false
            for i, a in pairs(p.parts) do
                if a and p.keys and p.keys[i] and not paint(a, p.keys[i]) then left = true end
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
                crumb("spawn puppet " .. tostring(id))
                resolve_assets()
                p = { cur = { x = st.x, y = st.y, z = st.z, yaw = st.yaw }, color = st.color }
                p.parts = {}
                local meshes = { c = Assets.body, s = Assets.head, b = Assets.cube or Assets.body }
                local grab = g1_ready()
                local mann = m1_enabled()
                if mann then
                    p.keys, p.paths = {}, {}
                    m1_spawn(p, st, (st.color and BODY_COLOURS[st.color]) and st.color or YEL)
                end
                for i, d in ipairs(mann and {} or FIGURE) do
                    local a = nil
                    if not (grab and g1_replaced(d)) then a = spawn_mesh(meshes[d[1]], st.x, st.y, st.z + d[5], d[6], d[7], d[8]) end
                    p.keys = p.keys or {}
                    local key = d[2]
                    if key == YEL and st.color and BODY_COLOURS[st.color] then key = st.color end
                    p.keys[i] = key
                    if a and not paint(a, key) then p.unpainted = true end
                    p.parts[i] = a
                    p.paths = p.paths or {}
                    p.paths[i] = a and try(function() return a:GetFullName():match("^%S+ (.+)$") end)
                end
                p.paths = p.paths or {}
                if grab then pcall(g1_spawn, p, st) end
                p.tag = spawn_tag(pl.name or ("P" .. id), st.x, st.y, st.z + 120)
                Puppets[id] = p
                log("spawned puppet for %s (%s%s%s)", pl.name or id, valid(p.parts[3]) and "ok" or "FAILED", grab and ", real GrabPack" or "", mann and ", mannequin" or "")
            end
            if not p then goto next_player end      -- figure assets still loading
            p.tgt = st
            local c = p.cur
            local dx, dy, dz = st.x - c.x, st.y - c.y, st.z - c.z
            -- vertical speed from consecutive updates; while airborne, predict ahead so the figure's
            -- jump reaches the real height instead of being flattened by the smoothing
            if p.st_t ~= pl.state_time then
                if p.st_t and pl.state_time and pl.state_time > p.st_t then
                    local gap = pl.state_time - p.st_t
                    p.vz = (st.z - p.st_z) / gap
                    -- horizontal velocity too (smoothed): the figure is predicted a little ahead instead of
                    -- trailing ~70 ms behind and stuttering when updates arrive unevenly
                    local vx, vy = (st.x - p.st_x) / gap, (st.y - p.st_y) / gap
                    if vx * vx + vy * vy > 1500 * 1500 then vx, vy = 0, 0 end      -- teleport, not walking
                    if vx * vx + vy * vy < 40 * 40 then p.vx, p.vy = 0, 0       -- stopped: no prediction (no overshoot)
                    else
                        p.vx = (p.vx or 0) + (vx - (p.vx or 0)) * 0.5
                        p.vy = (p.vy or 0) + (vy - (p.vy or 0)) * 0.5
                    end
                end
                p.st_t, p.st_z, p.st_x, p.st_y = pl.state_time, st.z, st.x, st.y
            end
            local tz = st.z
            if (st.flags & 8) ~= 0 and p.vz and pl.state_time then
                tz = st.z + p.vz * math.min(0.08, math.max(0, game_time - pl.state_time))
            end
            if p.vx and pl.state_time then
                local ahead = math.min(0.07, math.max(0, game_time - pl.state_time))
                dx, dy = st.x + p.vx * ahead - c.x, st.y + p.vy * ahead - c.y
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
                    local hc = p.hand[tag]
                    hc.rot, hc.sc, hc.dist, hc.thick, hc.bits = h.rot, h.sc, h.dist, h.thick, h.bits   -- real hand pose (Chapter 1)
                    hc.anim, hc.corners, hc.elec = h.anim, h.corners, h.elec                           -- (Chapter 2)
                end
                p.ext[tag] = p.ext[tag] + ((h and 1 or 0) - p.ext[tag]) * math.min(1, dt * (h and 16 or 9))
            end
            if p.f2 then
                f2_update(p, st, c, dt, crouch, dead)
                goto figure_done
            end
            if p.m1 then
                crumb("m1 " .. tostring(id))
                if not p.g1 and g1_ready() then pcall(g1_spawn, p, st) end    -- GrabPack meshes loaded late
                if p.g1 and not p.g1.sk and not p.g1.sk_pending and g1_sk_ready() then
                    p.g1.sk_pending = true                    -- built outside the actor tick (g1_anim_safe)
                    g1_anim_safe(function() if Puppets[id] == p and not Game.loading then g1_sk_spawn(p) end end, "sk_spawn")
                end
                crumb("m1_update " .. tostring(id))
                local ok, moved = pcall(m1_update, p, st, c, crouch, dead, swing, bob, amount)
                crumb("g1_update " .. tostring(id))
                local flying = p.ext.L > 0.002 or p.ext.R > 0.002 or p.g1fly
                p.g1fly = p.ext.L > 0.002 or p.ext.R > 0.002      -- one more pass after the hands are back
                if p.g1 and (moved ~= false or flying) then pcall(g1_update, p, st, c, crouch) end
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
            if p.g1 then pcall(g1_update, p, st, c, crouch) end
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
                -- far away: show the distance ("LuJo - 34 m"); the text only changes in 5 m steps
                local d = math.sqrt((my.X - c.x) ^ 2 + (my.Y - c.y) ^ 2 + (my.Z - c.z) ^ 2) / 100
                local label = (pl and pl.name or ("P" .. id)) .. (d >= 15 and (" - %d m"):format(math.floor(d / 5 + 0.5) * 5) or "")
                if p.say and game_time < (p.say_until or 0) then label = label .. ": " .. p.say end
                if label ~= p.tag_text and FText then
                    p.tag_text = label
                    pcall(function() p.tag.TextRender:K2_SetText(FText(label)) end)
                end
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
local TpReq = false        -- true, or a player name (console: coop_tp <name>)
local TpLast = nil
local Tp = nil            -- running teleport: { id, name, phase = "load"|"guard", t0, t1, z, tries }
local TP_LOAD_WAIT = 10   -- s: longest wait for the friend's area to load before teleporting anyway
local TP_GUARD = 5        -- s: after the teleport, watch for a fall through a missing floor
local TP_FALL = 600       -- cm below the friend = falling out of the map
-- Following a player who is at a later checkpoint (Chapter 2): the game respawns us at their checkpoint
-- first (its own RestartLevel path: that part of the world - chase over, game won, doors - is then in the
-- right state), then the normal teleport runs. { name, phase = "restart"|"loading", t }
local Follow = nil
local FOLLOW_SETTLE = 3   -- s after the respawn before teleporting to the friend
local FOLLOW_TIMEOUT = 25 -- s: the restart never happened -> give up

local function tp_say(msg)
    log("%s", msg)
    local P2 = _G.PoppyCoop
    if P2 and P2.popup then pcall(P2.popup, msg) end
end

local function tp_target(id)
    local pl = Net.players[id]
    local st = pl and pl.state and parse_state(pl.state)
    if st and st.map == Game.map and (st.flags & 16) == 0 then return st, pl end
end

local function tp_place(st)
    local pawn = Game.pawn
    if not valid(pawn) then return end
    pcall(function() pawn:K2_SetActorLocation({ X = st.x - 60, Y = st.y, Z = st.z + 30 }, false, {}, true) end)
    pcall(function() pawn.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 } end)
end

-- Start a teleport: pick the friend, then tp_tick loads their area first and teleports when it's there.
local function teleport_to_friend(want)
    if not valid(Game.pawn) then return end
    local ids = {}
    for id, pl in pairs(Net.players) do
        local name_ok = type(want) ~= "string" or (pl.name or ""):lower() == want:lower()
        if id ~= BUDDY_ID and id ~= PLAY_ID and name_ok and tp_target(id) then ids[#ids + 1] = id end
    end
    if #ids == 0 then
        tp_say(type(want) == "string" and ("No player named " .. want .. " to teleport to")
            or "Nobody to teleport to (others are dead, loading or in another map)")
        return
    end
    table.sort(ids)
    local pick = ids[1]
    if TpLast then for _, id in ipairs(ids) do if id > TpLast then pick = id; break end end end
    TpLast = pick
    local name = Net.players[pick].name or ("player " .. pick)
    local P2 = _G.PoppyCoop
    local st = tp_target(pick)
    if CHAPTER == 2 and not Follow and st and st.cp and P2 and P2.cp_info and P2.respawn_at_cp then
        local _, mine = P2.cp_info()
        if st.cp > mine then
            Follow = { name = name, phase = "restart", t = game_time }
            tp_say(("Loading %s's checkpoint (%d)..."):format(name, st.cp))
            local ok, r = pcall(P2.respawn_at_cp, st.cp)
            if ok and r then return end
            log("follow: respawn failed (%s), teleporting directly", tostring(r))
            Follow = nil
        end
    end
    Tp = { id = pick, name = name, phase = "load", t0 = game_time, tries = 0 }
    tp_say("Loading " .. name .. "'s area...")
end

local function follow_tick()
    if not Follow then return end
    if Follow.phase == "restart" then
        if game_time - Follow.t > FOLLOW_TIMEOUT then log("follow: no respawn happened"); Follow = nil end
        return
    end
    if not valid(Game.pawn) or Game.loading then Follow.t = nil; return end
    Follow.t = Follow.t or game_time
    if game_time - Follow.t < FOLLOW_SETTLE then return end
    local name = Follow.name
    Follow = nil
    teleport_to_friend(name)
end
table.insert(Handlers.unload, function() if Follow then Follow.phase, Follow.t = "loading", nil end end)
-- coop_world: a friend just finished a chase we are still in -> follow them (same as F6)
_G.PoppyCoop_follow = function(id)
    local pl = Net.players[id]
    if pl and pl.name and not Follow and not Tp then teleport_to_friend(pl.name) end
end

local function tp_tick()
    if not Tp then return end
    local st = tp_target(Tp.id)
    if not st or not valid(Game.pawn) then tp_say("Teleport cancelled"); Tp = nil; return end
    local P2 = _G.PoppyCoop
    if Tp.phase == "load" then
        local ready, pending, which = true, 0, ""
        if P2 and P2.level_prep then
            local ok, r, n, w = pcall(P2.level_prep, Tp.id)
            if ok then ready, pending, which = r, n, w else log("teleport: level_prep error %s", tostring(r)) end
        end
        if not ready and game_time - Tp.t0 < TP_LOAD_WAIT then return end
        if not ready then log("teleport: %d area(s) still loading, teleporting anyway: %s", pending, tostring(which)) end
        tp_place(st)
        Tp.phase, Tp.t1, Tp.z = "guard", game_time, st.z
        if Tp.tries == 0 then tp_say("Teleported to " .. Tp.name) end
        return
    end
    -- guard: falling far below the friend means the floor wasn't there yet - put us back on it
    local z = try(function() return Game.pawn:K2_GetActorLocation().Z end)
    if z and z < Tp.z - TP_FALL and Tp.tries < 3 then
        Tp.tries = Tp.tries + 1
        log("teleport: fell through (z %.0f vs %.0f), placing again (%d)", z, Tp.z, Tp.tries)
        tp_place(st)
        Tp.phase, Tp.t0 = "load", game_time - TP_LOAD_WAIT + 1.5   -- short re-check, then place again
        return
    end
    if game_time - Tp.t1 > TP_GUARD then Tp = nil end
end
-- Ping (default T): marks the spot you look at for everyone - a red "! name" for 6 s and a message with the
-- distance. Line trace from the camera (UE4SS fills the HitResult out-parameter table).
local Ping = { req = false, list = {}, TIME = 6, RANGE = 6000 }   -- list: { a = text actor, t = remove time, x, y, z }; RANGE in cm
function Ping.ping_popup(msg, kind, name)
    local P2 = _G.PoppyCoop
    if P2 and P2.popup then pcall(P2.popup, msg, kind, name) end
end
function Ping.ping_spawn(name, x, y, z)
    local a = spawn_tag("! " .. name, x, y, z + 30)
    if not a then return end
    pcall(function()
        local t = a.TextRender
        t:SetWorldSize(60)
        t:SetTextRenderColor({ R = 255, G = 60, B = 50, A = 255 })
    end)
    Ping.list[#Ping.list + 1] = { a = a, t = game_time + Ping.TIME, x = x, y = y, z = z + 30 }
end
function Ping.ping_target()
    local pawn = Game.pawn
    local pc = valid(pawn) and try(function() return pawn:GetController() end)
    local cm = pc and try(function() return pc.PlayerCameraManager end)
    if not valid(cm) then return nil end
    local loc, rot = cm:GetCameraLocation(), cm:GetCameraRotation()
    local mml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local f = mml:GetForwardVector(rot)
    local a = { X = loc.X + f.X * 40, Y = loc.Y + f.Y * 40, Z = loc.Z + f.Z * 40 }
    local b = { X = loc.X + f.X * Ping.RANGE, Y = loc.Y + f.Y * Ping.RANGE, Z = loc.Z + f.Z * Ping.RANGE }
    local hit = {}
    local ok = try(function() return ksl:LineTraceSingle(pawn, a, b, 0, false, { pawn }, 0, hit, true,
        { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0) end)
    local p = ok == true and hit.ImpactPoint or b
    return p.X, p.Y, p.Z
end
function Ping.do_ping()
    if not valid(Game.pawn) then return end
    local x, y, z = Ping.ping_target()
    if not x then return end
    Ping.ping_spawn(tostring(Config.name or "you"), x, y, z)
    if Coop.active() then Coop.send_event("ping", ("%.0f %.0f %.0f %s"):format(x, y, z, Game.map)) end
end
function Ping.pings_tick()
    if #Ping.list == 0 then return end
    local my = valid(Game.pawn) and try(function() return Game.pawn:K2_GetActorLocation() end)
    for i = #Ping.list, 1, -1 do
        local e = Ping.list[i]
        if game_time > e.t or not valid(e.a) then
            if valid(e.a) then pcall(function() e.a:K2_DestroyActor() end) end
            table.remove(Ping.list, i)
        elseif my then
            local yaw = math.deg(math.atan(my.Y - e.y, my.X - e.x))
            pcall(function() e.a:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false) end)
        end
    end
end
table.insert(Handlers.unload, function() Ping.list = {} end)   -- the engine destroys the actors with the level
_G.PoppyCoop_ping = function() Ping.req = true end          -- console/dev
-- chat (default Y): opens the chat menu (coop_extra UI): 1-8 send a quick phrase, or type a text + Enter.
-- Event "chat": "<n>" = quick phrase n, "t:<text>" = typed text. Everyone gets it in the message feed and it
-- floats above the sender's figure for a few seconds. Without the UI, Y cycles the phrases (sent 1.5 s after
-- the last press) like before.
Ping.PHRASES = { "Come here!", "Wait for me!", "Help!", "Follow me!", "Go ahead, I follow", "Over here!", "Thanks!", "Sorry!" }
function Ping.clean(t) return (tostring(t or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 120)) end
function Ping.chat_press()
    local P2 = _G.PoppyCoop
    if P2 and P2.chat_toggle and P2.UI and P2.UI.state ~= "off" then P2.chat_toggle(); return end
    Ping.chat_pick = ((Ping.chat_pick or 0) % #Ping.PHRASES) + 1
    Ping.chat_at = game_time + 1.5
    Ping.ping_popup(("Say: %s  (Y = next)"):format(Ping.PHRASES[Ping.chat_pick]), "me")
end
-- in-game settings and actions as chat commands ("/solid off", "/tp LuJo", "/help"); session only - the
-- launcher writes config.txt again on the next start
Ping.CMDS = {
    solid = { key = "boost", desc = "friends are solid / stand on them" },
    footsteps = { key = "footsteps", desc = "friends' footsteps" },
    follow = { key = "auto_follow", desc = "follow out of chases" },
    respawn = { key = "respawn_at_friend", desc = "respawn at a friend" },
    fps60 = { key = "fps60", desc = "limit to 60 fps" },
}
local function cfg_on(v) return not (v == false or v == "false") end
function Ping.command(text)
    local cmd, arg = text:match("^/(%S+)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local function say(m) Ping.ping_popup(m, "me") end
    if cmd == "help" or cmd == "" then
        say("/tp [name]  /stats  /report  /solid  /footsteps  /follow  /respawn  /spectate  /grabfriend  /fps60  (on/off)")
        return
    end
    if cmd == "tp" then TpReq = arg ~= "" and arg or true; return end
    if cmd == "stats" or cmd == "status" then Game.status_req = true; return end
    if cmd == "report" then
        local f = io.open(MOD_DIR .. "\\bugreport.txt", "w")
        if not f then say("Couldn't write bugreport.txt"); return end
        f:write(("PoppyCoop %s bug report, map %s, room players %d\n"):format(VERSION, tostring(Game.map), Net.npeers or 0))
        for k = 1, #Net.rec do
            local l = Net.rec[(Net.rec_i + k - 1) % #Net.rec + 1]
            if l then f:write(l, "\n") end
        end
        f:close()
        say("bugreport.txt written - the launcher's \"Show game log\" puts it in the report zip")
        return
    end
    local c = Ping.CMDS[cmd]
    if not c then say("Unknown command - /help lists them"); return end
    local cur = cfg_on(Config[c.key])
    if c.key == "respawn_at_friend" or c.key == "fps60" then cur = Config[c.key] == true or Config[c.key] == "true" end
    local new
    if arg == "on" then new = true elseif arg == "off" then new = false else new = not cur end
    Config[c.key] = new
    if c.key == "fps60" then
        pcall(function()
            local pc = SafeUE.player_controller()
            local ks = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            if pc and ks then ks:ExecuteConsoleCommand(pc:GetWorld(), new and "t.MaxFPS 60" or "t.MaxFPS 0", pc) end
        end)
    end
    say(("%s: %s (this session)"):format(c.desc, new and "on" or "off"))
end
-- spectator: while you are dead, the camera watches the nearest friend from behind (until the game respawns
-- you - its restart sets the view back to your new player). config spectate=false / "/spectate off" turns it off.
Ping.CMDS.spectate = { key = "spectate", desc = "watch a friend while dead" }
function Ping.spectate_end()
    local sp = Ping.spec
    Ping.spec = nil
    if sp and valid(sp.cam) then pcall(function() sp.cam:K2_DestroyActor() end) end
end
function Ping.spectate_tick()
    if Config.spectate == false or Config.spectate == "false" then return end
    if not Game.dead then Ping.spectate_end(); return end
    local sp = Ping.spec
    if not sp then sp = { t0 = game_time }; Ping.spec = sp end
    if game_time - sp.t0 < 1.5 then return end            -- let the death animation play first
    local my = valid(Game.pawn) and try(function() return Game.pawn:K2_GetActorLocation() end)
    local best, bd
    for id, pl in pairs(Net.players) do
        local st = id < 900 and pl.state and parse_state(pl.state)
        if st and st.map == Game.map and (st.flags & 16) == 0 then
            local d = my and ((st.x - my.X) ^ 2 + (st.y - my.Y) ^ 2) or 0
            if not bd or d < bd then best, bd = st, d end
        end
    end
    if not best then return end
    local pc = try(function() return Game.pawn:GetController() end) or SafeUE.player_controller()
    if not valid(pc) then return end
    if not valid(sp.cam) then
        local cls = StaticFindObject("/Script/Engine.CameraActor")
        local world = UEHelpers.GetWorld()
        if not (valid(cls) and valid(world)) then return end
        sp.cam = try(function() return world:SpawnActor(cls, { X = best.x, Y = best.y, Z = best.z + 150 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        if not valid(sp.cam) then return end
        pcall(function() pc:SetViewTargetWithBlend(sp.cam, 0.6, 0, 0, false) end)
        Ping.ping_popup("watching your friend until you respawn", "me")
    end
    -- 2.6 m behind and 1.2 m above the friend, looking at their head
    local yaw = math.rad(best.yaw or 0)
    local cx, cy, cz = best.x - math.cos(yaw) * 260, best.y - math.sin(yaw) * 260, best.z + 120
    local dx, dy, dz = best.x - cx, best.y - cy, (best.z + 40) - cz
    local rot = { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
    pcall(function() sp.cam:K2_SetActorLocationAndRotation({ X = cx, Y = cy, Z = cz }, rot, false, {}, true) end)
end
-- grab a friend (Chapter 2): when your launched hand reaches a friend's figure, you are pulled to them like
-- to a swing handle. Config grab_friend=false / "/grabfriend off" turns it off.
Ping.CMDS.grabfriend = { key = "grab_friend", desc = "pull yourself to a friend with the hand" }
function Ping.grab_tick()
    if CHAPTER ~= 2 or Config.grab_friend == false or Config.grab_friend == "false" then return end
    if game_time < (Ping.grab_next or 0) then return end
    local pawn = Game.pawn
    for _, h in ipairs(CH2_HANDS) do
        local a = try(function() return pawn[h.obj] end)
        local rig = a and valid(a) and try(function() local c = a["Hand Rig"]; return c:IsValid() and c or nil end)
        local hl = rig and try(function() return rig:K2_GetComponentLocation() end)
        if hl then
            for _, p in pairs(Puppets) do
                local c = p.cur
                if c and (hl.X - c.x) ^ 2 + (hl.Y - c.y) ^ 2 + (hl.Z - c.z) ^ 2 < 90 * 90 then
                    local me = try(function() return pawn:K2_GetActorLocation() end)
                    if me then
                        local dx, dy, dz = c.x - me.X, c.y - me.Y, c.z - me.Z
                        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                        if d > 150 then
                            local sp = math.min(1400, 400 + d * 1.2)
                            pcall(function() pawn:LaunchCharacter({ X = dx / d * sp, Y = dy / d * sp, Z = dz / d * sp + 350 }, true, true) end)
                            Ping.grab_next = game_time + 1.5
                            return
                        end
                    end
                end
            end
        end
    end
end
-- n: quick phrase number, or text: typed message
function Ping.say(n, text)
    if not n and type(text) == "string" and text:sub(1, 1) == "/" then return Ping.command(text) end
    local msg = n and Ping.PHRASES[n] or Ping.clean(text)
    if not msg or msg == "" then return end
    if Coop.active() then Coop.send_event("chat", n and tostring(n) or ("t:" .. msg)) end
    Ping.ping_popup(msg, "me", "You")
end
function Ping.chat_send()
    local i = Ping.chat_pick
    Ping.chat_pick = nil
    if i then Ping.say(i) end
end
Coop.on("chat", function(from, rest)
    rest = tostring(rest or "")
    local i = tonumber(rest)
    local msg = i and Ping.PHRASES[i] or (rest:sub(1, 2) == "t:" and Ping.clean(rest:sub(3))) or nil
    if not msg or msg == "" then return end
    local pl = Net.players[from]
    Ping.ping_popup(msg, "chat", pl and pl.name or "?")
    local p = Puppets[from]
    if p then
        p.say, p.say_until = (#msg > 40 and (msg:sub(1, 38) .. "...") or msg), game_time + 6
        -- emote with the quick phrases: thanks / sorry = a nod, come / help / over here = arms up
        local e = ({ [1] = "cheer", [3] = "cheer", [6] = "cheer", [7] = "nod", [8] = "nod", [5] = "nod" })[i or 0]
        if e then p.emote, p.emote_until = e, game_time + 1.2 end
    end
end)
Coop.on("ping", function(from, rest)
    local x, y, z, map = rest:match("^(%-?%d+) (%-?%d+) (%-?%d+) (%S+)")
    if not x or map ~= Game.map or not valid(Game.pawn) then return end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    local pl = Net.players[from]
    local name = pl and pl.name or "?"
    Ping.ping_spawn(name, x, y, z)
    local my = try(function() return Game.pawn:K2_GetActorLocation() end)
    local d = my and math.sqrt((my.X - x) ^ 2 + (my.Y - y) ^ 2 + (my.Z - z) ^ 2) / 100
    Ping.ping_popup(d and ("pinged a spot %.0f m away"):format(d) or "pinged a spot", "ping", name)
end)

-- Keys come from ue4ss\Mods\PoppyCoop\keybinds.txt (written with the defaults on first run).
-- Names are UE4SS key names: F1..F12, A..Z, ONE..NINE, NUM_ZERO..NUM_NINE, INS, HOME, END, PAGE_UP ...
local KB = { teleport = "F6", buddy = "F7", record = "O", play = "P", ping = "T", status = "F11", chat = "Y" }   -- F10 is the UE4SS console key
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
            for _, k in ipairs({ "teleport", "buddy", "record", "play", "ping", "status", "chat" }) do f:write(k, "=", KB[k], "\n") end
            f:close()
        end
    end
end
if KB.status == "F10" then KB.status = "F11" end   -- 1.4.9: F10 opens the UE4SS console, never use it twice
local function bind(name, fn)
    pcall(function() RegisterKeyBind(Key[KB[name]], function()
        local P2 = _G.PoppyCoop
        if P2 and P2.chat_is_open and P2.chat_is_open() then return end    -- typing in the chat box
        fn()
    end) end)
end
bind("teleport", function() TpReq = true end)
bind("ping", function() Ping.req = true end)
bind("status", function() Game.status_req = true end)
bind("chat", function() Game.chat_req = true end)
bind("buddy", function() Ghost.keys[#Ghost.keys + 1] = "buddy" end)
bind("record", function() Ghost.keys[#Ghost.keys + 1] = "record" end)
bind("play", function() Ghost.keys[#Ghost.keys + 1] = "play" end)
log("keys: teleport=%s buddy=%s record=%s play=%s ping=%s status=%s chat=%s", KB.teleport, KB.buddy, KB.record, KB.play, KB.ping, KB.status, KB.chat)

----------------------------------------------------------------------- tick
local send_accum, last_sent, last_sent_t = 0, nil, 0

-- perf report (every 15 s) only for developers: create ue4ss\Mods\PoppyCoop\perf_on.txt
local PERF_LOG = (function() local f = io.open(MOD_DIR .. "\\perf_on.txt", "r"); if f then f:close(); return true end return false end)()
local Perf = { frames = 0, real = 0, lua = 0, hooks = 0, by = {}, sec = {} }
-- status key (default F11; F10 is the console): fps, mod cost, ping, players, version, checkpoint as an on-screen message
function Ping.status()
    local P2 = _G.PoppyCoop
    if not (P2 and P2.popup) then return end
    local fps = Perf.real > 0.5 and Perf.frames / Perf.real or 0
    local ms = Perf.frames > 0 and Perf.lua / Perf.frames * 1000 or 0
    local n = 0
    for id in pairs(Net.players) do if id < 900 then n = n + 1 end end
    local cp = P2.cp_info and select(2, P2.cp_info()) or -1
    local t = math.floor(game_time)
    local lines = {
        ("%.0f fps  |  mod %.1f ms  |  ping %s"):format(fps, ms, (Net.rtt and Net.rtt >= 0) and (Net.rtt .. " ms") or "-"),
        ("%d:%02d:%02d played  |  %d death%s%s"):format(t // 3600, t // 60 % 60, t % 60, Game.deaths or 0, (Game.deaths or 0) == 1 and "" or "s",
            cp >= 0 and ("  |  checkpoint " .. cp) or ""),
        n == 0 and "No other players in the room" or ("%d other player%s:"):format(n, n == 1 and "" or "s"),
    }
    -- where everyone is: distance and direction like a clock (12 = straight ahead)
    local my = valid(Game.pawn) and try(function() return Game.pawn:K2_GetActorLocation() end)
    local view = valid(Game.pawn) and try(function() return Game.pawn:GetController():GetControlRotation().Yaw end)
    for id, pl in pairs(Net.players) do
        local st = id < 900 and pl.state and parse_state(pl.state)
        if st and my and view and #lines < 9 then
            local dx, dy = st.x - my.X, st.y - my.Y
            local d = math.sqrt(dx * dx + dy * dy + (st.z - my.Z) ^ 2) / 100
            local rel = (math.deg(math.atan(dy, dx)) - view) % 360
            local clock = math.floor(rel / 30 + 0.5) % 12
            if clock == 0 then clock = 12 end
            local updown = (st.z - my.Z) > 300 and ", above" or ((st.z - my.Z) < -300 and ", below" or "")
            lines[#lines + 1] = ("   %s - %.0f m at %d o'clock%s%s"):format(pl.name or "?", d, clock, updown, st.map ~= Game.map and " (other map)" or "")
        end
    end
    -- session stats: deaths of everyone, last checkpoint splits
    local S = P2.Stats
    if S then
        local d = { ("You %d"):format(Game.deaths or 0) }
        for name, k in pairs(S.deaths) do d[#d + 1] = ("%s %d"):format(name, k) end
        lines[#lines + 1] = "Deaths:  " .. table.concat(d, "  |  ")
        if #S.splits > 0 then
            local sp = {}
            for i = math.max(1, #S.splits - 2), #S.splits do
                local e = S.splits[i]
                sp[#sp + 1] = ("CP %d  %d:%02d:%02d"):format(e.n, e.t // 3600, e.t // 60 % 60, e.t % 60)
            end
            lines[#lines + 1] = "Splits:  " .. table.concat(sp, "  |  ")
        end
    end
    if P2.ui_status then pcall(P2.ui_status, ("PoppyCoop v%s  -  room %s"):format(VERSION, tostring(Config.room or "-")), lines); return end
    for _, l in ipairs(lines) do pcall(P2.popup, l) end
end
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
    Crumb.frame = Crumb.frame + 1
    if not Late.hooked then late_hook() end
    crumb("refresh_player")
    local have = refresh_player()
    if have and ghosts then ghost_tick(dt) end
    send_accum = send_accum + dt
    if send_accum >= 1 / Config.send_hz then
        send_accum = 0
        crumb("local_state")
        local st = have and try(local_state) or nil
        -- don't resend identical state more than once a second
        if st and st == last_sent and game_time - last_sent_t < 1 then st = nil end
        if st then last_sent, last_sent_t = st, game_time end
        if st and game_time - (Net.rec_st or 0) > 0.5 then Net.rec_st = game_time; Net.rec_add(("%.2f S me %s"):format(game_time, st:sub(1, 200))) end
        crumb("net_poll")
        net_poll(st)
    end
    local c0 = os.clock()
    crumb("update_puppets")
    if have then update_puppets(dt) end
    crumb("after update_puppets")
    Perf.sec.figures = (Perf.sec.figures or 0) + os.clock() - c0
    if Game.respawn_tp_at and have and game_time > Game.respawn_tp_at then
        Game.respawn_tp_at = nil
        if next(Net.players) and not Tp then log("respawned: going to a friend (respawn_at_friend)"); TpReq = true end
    end
    if TpReq then local w = TpReq; TpReq = false; if have then pcall(teleport_to_friend, w) end end
    if Game.status_req then Game.status_req = false; pcall(Ping.status) end
    if Game.chat_req then Game.chat_req = false; pcall(Ping.chat_press) end
    if Ping.chat_pick and game_time > Ping.chat_at then pcall(Ping.chat_send) end
    if Ping.req then Ping.req = false; if have then local ok, err = pcall(Ping.do_ping); if not ok then log("ping: %s", tostring(err)) end end end
    if have then pcall(Ping.pings_tick) end
    if Game.dead or Ping.spec then pcall(Ping.spectate_tick) end
    if have and next(Puppets) then pcall(Ping.grab_tick) end
    if Follow and have then local ok, err = pcall(follow_tick); if not ok then log("follow error: %s", tostring(err)); Follow = nil end end
    if Tp and have then local ok, err = pcall(tp_tick); if not ok then log("teleport error: %s", tostring(err)); Tp = nil end end
    for i, h in ipairs(Handlers.tick) do
        crumb("module tick " .. i)
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
        local tick_fn = "/Game/Player/PlayerBP.PlayerBP_C:ReceiveTick"
        if EXPERIMENTAL then
            -- another player blueprint: hook its own tick if it has one, else a ~60 Hz game-thread loop
            local pawn = try(function() local pc = SafeUE.player_controller(); return pc and pc.Pawn end)
            local cls = valid(pawn) and try(function() return pawn:GetClass():GetFullName() end) or ""
            local path = cls:match("^%S+%s+(/Game/%S+)$")
            local fn = path and try(StaticFindObject, path .. ":ReceiveTick")
            if valid(fn) then tick_fn = path .. ":ReceiveTick"
            else
                if not valid(pawn) then error("no player yet") end
                local busy = false
                LoopAsync(16, function()
                    if busy then return false end
                    busy = true
                    ExecuteInGameThread(function()
                        busy = false
                        local now = realtime()
                        local dt = now - last
                        last = now
                        if dt <= 0 or dt > 0.5 then dt = 0.016 end
                        local c0 = os.clock()
                        local ok2, e2 = pcall(tick, dt)
                        if not ok2 then log("tick error: %s", tostring(e2)) end
                        Perf.lua = Perf.lua + (os.clock() - c0)
                        Perf.frames = Perf.frames + 1
                    end)
                    return false
                end)
                log("experimental chapter %d: no player tick (%s) - using a 60 Hz loop", CHAPTER, tostring(path))
                return
            end
            log("experimental chapter %d: tick hooked to %s", CHAPTER, tick_fn)
        end
        RegisterHook(tick_fn, function(ctx)
            -- the ticking pawn itself: a lookup that can't fail (only valid during this call)
            Game.tick_pawn = ctx and try(function() return ctx:get() end) or nil
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
            Game.tick_pawn = nil
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
    for k in pairs(G1A) do G1A[k] = nil end
    for k in pairs(G1K) do G1K[k] = nil end
    for k in pairs(AssetRequested) do AssetRequested[k] = nil end   -- ...so they may need loading again
    Tint.base, Tint.mids, Tint.tries, Tint.next_try = nil, {}, 0, 0
    for _, h in ipairs(Handlers.unload) do pcall(h) end
    log("level loading: cleared cached objects")
end
-- same check as the player tick, for code that runs outside it (late queue): false = the world changed
Game.world_check = function()
    local w = SafeUE.world()
    local wa = w and try(function() return tostring(w:GetAddress()) end)
    if wa and Game.world_addr and wa ~= Game.world_addr then
        world_unloading(); Game.loading = false; Game.world_addr = wa
        return false
    end
    return true
end
-- NOTE: RegisterLoadMapPreHook crashes this game on startup with UE4SS 3.0.1, so it is NOT used.
-- Instead we notice the new world when the new player spawns (nothing ticks during a level load).

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    -- fresh lookup of the current world (never through a cached object)
    local w = try(function() local wo = SafeUE.world(); return wo and tostring(wo:GetAddress()) end)
    if w and Game.world_addr and w ~= Game.world_addr then world_unloading() end
    if w then Game.world_addr = w end
    -- optional (config respawn_at_friend=true, launcher switch): after dying, go to a friend once respawned
    if Game.dead then Game.deaths = (Game.deaths or 0) + 1 end
    -- launcher "Limit to 60 fps" (config fps60=true)
    if Config.fps60 == true or Config.fps60 == "true" then
        pcall(function()
            local pc = SafeUE.player_controller()
            local ks = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            if pc and ks then ks:ExecuteConsoleCommand(pc:GetWorld(), "t.MaxFPS 60", pc) end
        end)
    end
    -- launcher "Performance mode" (config low_gfx=true): lower shadows / effects / post processing
    if Config.low_gfx == true or Config.low_gfx == "true" then
        pcall(function()
            local pc = SafeUE.player_controller()
            local ks = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            if pc and ks then
                for _, c in ipairs({ "sg.ShadowQuality 1", "sg.EffectsQuality 1", "sg.PostProcessQuality 1", "sg.FoliageQuality 1", "r.MotionBlurQuality 0" }) do
                    ks:ExecuteConsoleCommand(pc:GetWorld(), c, pc)
                end
            end
        end)
    end
    if Game.dead and (Config.respawn_at_friend == true or Config.respawn_at_friend == "true") then Game.respawn_tp_at = game_time + 4 end
    Game.dead = false
    Ping.spectate_end()
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
    if valid(FindFirstOf("PlayerBP_C")) or (EXPERIMENTAL and SafeUE.player_controller()) then hook_tick() end
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
    -- teleport to a friend: coop_tp [name]   (next other player if no name); loads their area first
    local want = tostring(full or ""):match("^%S+%s+(%S+)")
    if not valid(Game.pawn) then reply(out, "not in game"); return true end
    TpReq = want or true
    reply(out, "teleport requested")
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

------------------------------------------------------------------------ version check
-- Everyone in a room needs the same mod version (events/state lines change between versions). Each player
-- tells every newcomer its version; a different one - or none within 15 s (before 1.4.8) - gets a message.
local VerCheck = {}          -- id -> { at = join time, got = version }
local function ver_popup(msg)
    log("%s", msg)
    local P2 = _G.PoppyCoop
    if P2 and P2.popup then pcall(P2.popup, msg, "warn") end
end
-- remember who you played with in which room (the launcher's friends page / "Played with: ..." reads it).
-- "<ROOM>\t<name>#<tag>" - the tag is the player's friend-code number (launcher, config tag=), told on join;
-- players with an older mod have none ("<ROOM>\t<name>").
function Net.remember_player(name, tag)
    name = tostring(name or ""):gsub("[^%w_%-]", "")
    local room = tostring(Config.room or ""):upper():gsub("[^%w]", "")
    if name == "" or room == "" then return end
    local who = name .. ((tag and tostring(tag):match("^%d%d%d%d%d$")) and ("#" .. tag) or "")
    local fn = MOD_DIR .. "\\recent_players.txt"
    local lines, seen = {}, room .. "\t" .. who
    local untagged = room .. "\t" .. name
    local f = io.open(fn, "r")
    if f then for l in f:lines() do if l ~= seen and l ~= untagged and l:find("\t", 1, true) then lines[#lines + 1] = l end end; f:close() end
    lines[#lines + 1] = seen
    while #lines > 60 do table.remove(lines, 1) end
    f = io.open(fn, "w")
    if f then f:write(table.concat(lines, "\n"), "\n"); f:close() end
end
table.insert(Handlers.join, function(id, name)
    if id >= 900 then return end
    Net.remember_player(name, nil)
    local my = tostring(Config.tag or ""):match("^%d%d%d%d%d$")
    if my then Coop.send_to(id, "tag", my) end
end)
Coop.on("tag", function(from, t)
    t = tostring(t or ""):match("^(%d%d%d%d%d)$")
    local pl = Net.players[from]
    if not t or not pl or from >= 900 then return end
    pl.tag = t
    Net.remember_player(pl.name, t)
end)
table.insert(Handlers.join, function(id, name)
    Coop.send_to(id, "ver", VERSION)
    VerCheck[id] = { at = game_time, name = name }
end)
table.insert(Handlers.leave, function(id) VerCheck[id] = nil end)
Coop.on("ver", function(from, v)
    v = tostring(v or ""):match("^[%w%.]+") or "?"
    local c = VerCheck[from] or {}
    c.got = v
    VerCheck[from] = c
    if v ~= VERSION then
        local pl = Net.players[from]
        ver_popup(("%s has mod v%s, you have v%s - update so both use the same launcher version!"):format(pl and pl.name or "A player", v, VERSION))
    end
end)
table.insert(Handlers.tick, function()
    for id, c in pairs(VerCheck) do
        if not c.got and not c.told and game_time - (c.at or game_time) > 15 and id ~= BUDDY_ID and id ~= PLAY_ID then
            c.told = true
            ver_popup(("%s has an older mod version (before 1.4.8) - update so both use the same launcher version!"):format(c.name or "A player"))
        end
    end
end)

------------------------------------------------------------------------ init
load_config()
log("v%s loaded from %s | chapter %d%s | window %d | mode=%s name=%s host=%s:%d", VERSION, MOD_DIR, CHAPTER, EXPERIMENTAL and " (experimental)" or "", SLOT + 1, Config.mode, Config.name, Config.host_ip, Config.port)

-- Expose for sibling modules (doors/puzzles etc. live in separate files)
_G.PoppyCoop = { crumb = crumb, late = late, Late = Late, Coop = Coop, Net = Net, Game = Game, Config = Config, log = log, valid = valid, try = try, CHAPTER = CHAPTER, load_async = load_async,
                 Handlers = Handlers, MOD_DIR = MOD_DIR, Puppets = Puppets, Perf = Perf, Tint = Tint, G1A = G1A, SafeUE = SafeUE, G1_SHIFT = G1_SHIFT, M1_GRIP = M1_GRIP, G1_TIP = G1_TIP, game_time = function() return game_time end,
                 EXPERIMENTAL = EXPERIMENTAL, SLOT = SLOT }
_G.PoppyCoop.chat_send = Ping.say
-- experimental chapters: world sync (doors, items, levels...) only when the launcher's "Try world sync" is on
local EXP_WORLD = Config.exp_world == true or Config.exp_world == "true"
for _, m in ipairs((EXPERIMENTAL and not EXP_WORLD) and { "coop_extra" } or { "coop_world", "coop_extra" }) do
    local ok, err = pcall(require, m)
    if not ok and not tostring(err):find("not found") then log("module %s: %s", m, tostring(err)) end
end
