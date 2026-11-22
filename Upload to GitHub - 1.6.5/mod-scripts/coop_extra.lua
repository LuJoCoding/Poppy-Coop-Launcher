-- PoppyCoop extras: in-game popups, physics-object sync and Huggy sync.
--
-- POPUPS   Messages in a feed of boxes at the left edge, a status panel (F11) and a chat menu (chat key),
--          built from plain UMG widgets; fallback: floating TextRenderActor text in front of the camera.
--
-- MOTION   One system for anything that moves on its own: physics props the GrabPack can pull
--          and Huggy. Each game watches those actors; when one starts moving locally, that game
--          "drives" it and sends its transform inside the normal player-state line (unreliable,
--          20 Hz, no extra messages). Other games then move their copy to match (physics switched
--          off while a remote player drives it, so the two simulations can't fight).
--          If two games drive the same actor at once, the one whose player is closer wins -
--          so the person pushing the box, or the person Huggy is chasing, is in charge.
--          Actors are named by their level path (identical on every PC) and get a short number
--          per sender ("mvid <n> <path>" sent once, reliably).
local P = _G.PoppyCoop
if not P then return end
local Coop, Net, Game, log, valid, try, Handlers = P.Coop, P.Net, P.Game, P.log, P.valid, P.try, P.Handlers
local UEHelpers = require("UEHelpers")
local now = P.game_time

-- Physics-prop and monster syncing take control of game objects on the other player's machine. That was
-- experimental and could stop a scripted chase or crash, so it is OFF unless config.txt asks for it:
--   sync_physics=true / sync_huggy=true
local Cfg = (P and P.Config) or {}
local ENABLE_POPUPS = Cfg.popups ~= false and Cfg.popups ~= "false"
-- Chapter 1: boxes, crates, toy blocks, chairs... are part of the puzzles and get pulled around a lot, so
-- physics sync is on there unless config.txt says sync_physics=false
-- (was on by default in Chapter 1 for a while: the games froze right after a player joined - suspected:
-- moving physics bodies while Chaos simulates them. Back to opt-in until that is solved.)
local ENABLE_PHYSICS = Cfg.sync_physics == true or Cfg.sync_physics == "true"
    or ((P.CHAPTER == 1 or P.CHAPTER == 2) and Cfg.sync_physics ~= false and Cfg.sync_physics ~= "false")   -- writes run late in CH1 (see motion_apply)
local ENABLE_HUGGY = Cfg.sync_huggy == true or Cfg.sync_huggy == "true"

local function fullpath(o)
    local n = try(function() return o:GetFullName() end)
    return n and n:match("^%S+ (.+)$")
end
local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function pname(id) local p = Net.players[id]; return p and p.name or ("Player " .. tostring(id)) end
-- "VHSSecurity" -> "VHS Security", "Blue_VHS_Tape" -> "Blue VHS Tape"
local function pretty(s)
    s = tostring(s or ""):gsub("_", " ")
    s = s:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

------------------------------------------------------------------ popups / chat UI
-- Messages appear in a feed of dark boxes at the left edge of the screen (coloured bar + sender name), the
-- status (F11) in a panel at the top right, and the chat key opens a chat menu: 1-8 send a quick message,
-- or type a text and press Enter (Esc closes). Built from plain UMG widgets (UserWidget + WidgetTree
-- constructed here). If that fails, the old floating text in front of the camera is used.
local Popup = { list = {}, actors = {}, cls = nil, off = false }
local popups_tick        -- defined below; exported for offline use (trailer ghosts)
local POPUP_TIME, POPUP_MAX = 4.5, 3
local UI = { state = "new", feed = {}, FEED_MAX = 6, FEED_TIME = 7, CHAT_TIME = 11, FADE = 0.6, seq = 0,
    chat = { open = false } }
P.UI = UI
-- accent colours per kind of message
UI.KIND = {
    info = { 1.00, 0.80, 0.20 }, chat = { 0.35, 0.80, 1.00 }, warn = { 1.00, 0.35, 0.30 }, ping = { 1.00, 0.30, 0.25 },
    cp = { 0.40, 0.90, 0.45 }, join = { 0.40, 0.90, 0.45 }, leave = { 0.60, 0.60, 0.65 }, me = { 0.75, 0.75, 0.80 },
}
UI.PHRASES = { "Come here!", "Wait for me!", "Help!", "Follow me!", "Go ahead, I follow", "Over here!", "Thanks!", "Sorry!" }
P.CHAT_PHRASES = UI.PHRASES

local function popup_fallback(msg)
    table.insert(Popup.list, 1, { text = msg, t = now() })
    while #Popup.list > POPUP_MAX do table.remove(Popup.list) end
    Popup.dirty = true
end

-- msg: text; kind: key of UI.KIND (default info); name: sender shown in front in the accent colour
local function popup(msg, kind, name)
    if not ENABLE_POPUPS then return end
    log("popup: %s%s", name and (name .. ": ") or "", msg)
    if UI.state == "off" then
        popup_fallback(name and (name .. ": " .. msg) or msg)
        return
    end
    table.insert(UI.feed, { text = tostring(msg), kind = UI.KIND[kind] and kind or "info", name = name, t = now(), new = true })
    while #UI.feed > UI.FEED_MAX do table.remove(UI.feed, 1) end
    UI.dirty = true
end
P.popup = popup
P.popups_tick = function() return popups_tick() end
P.chat_is_open = function() return UI.chat.open end

-- widget helpers -----------------------------------------------------------
function UI.cls(n)
    UI.classes = UI.classes or {}
    local c = UI.classes[n]
    if not (c and valid(c)) then c = StaticFindObject("/Script/UMG." .. n); UI.classes[n] = c end
    return c
end
function UI.new(cls)
    UI.seq = UI.seq + 1
    return StaticConstructObject(UI.cls(cls), UI.tree, FName(("PoppyCoopUI_%s_%d"):format(cls, UI.seq)))
end
local function lin(c, a) return { R = c[1], G = c[2], B = c[3], A = a or 1 } end
function UI.text(s, size, col, bold)
    local t = UI.new("TextBlock")
    t:SetText(FText(s or ""))
    -- (SetFont with a table fails in UE4SS 3.0.1; the widget isn't built yet, so writing the struct in place is
    -- enough - it is applied when the widget goes to the viewport)
    pcall(function() t.Font.Size = size or 15 end)
    if bold then pcall(function() t.Font.TypefaceFontName = FName("Bold") end) end
    pcall(function() t:SetShadowOffset({ X = 1, Y = 1 }); t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.8 }) end)
    -- colour also written in place (SetColorAndOpacity with a table leaves it transparent in UE4SS 3.0.1)
    col = col or { 1, 1, 1 }
    pcall(function()
        local c = t.ColorAndOpacity.SpecifiedColor
        c.R, c.G, c.B, c.A = col[1], col[2], col[3], 1
    end)
    return t
end
function UI.box(content, pad, alpha)
    local b = UI.new("Border")
    b:SetBrushColor({ R = 0.01, G = 0.01, B = 0.02, A = alpha or 0.85 })
    pad = pad or { 12, 6, 14, 6 }
    b:SetPadding({ Left = pad[1], Top = pad[2], Right = pad[3], Bottom = pad[4] })
    if content then b:SetContent(content) end
    return b
end
function UI.bar(col)
    local b = UI.new("Border")
    b:SetBrushColor(lin(col, 1))
    b:SetPadding({ Left = 2, Top = 0, Right = 2, Bottom = 0 })
    return b
end
-- canvas slot: anchor (ax, ay) of the screen, alignment (px, py) of the widget, offset in slate units
function UI.place(w, ax, ay, px, py, x, y)
    local s = UI.canvas:AddChildToCanvas(w)
    local a = s.LayoutData.Anchors          -- in place: SetAnchors with a table is ignored
    a.Minimum.X, a.Minimum.Y, a.Maximum.X, a.Maximum.Y = ax, ay, ax, ay
    s:SetAlignment({ X = px, Y = py })
    s:SetPosition({ X = x, Y = y })
    s:SetAutoSize(true)
    return s
end
function UI.vadd(vbox, w, top)
    local s = vbox:AddChildToVerticalBox(w)
    pcall(function() s:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = 0 }) end)
    pcall(function() s:SetHorizontalAlignment(1) end)     -- left
    return s
end
function UI.hadd(hbox, w, left)
    local s = hbox:AddChildToHorizontalBox(w)
    pcall(function() s:SetPadding({ Left = left or 0, Top = 0, Right = 0, Bottom = 0 }) end)
    pcall(function() s:SetVerticalAlignment(0) end)       -- fill (bar as tall as the text box)
    return s
end
function UI.vis(w, on) pcall(function() w:SetVisibility(on and 4 or 1) end) end   -- 4 = SelfHitTestInvisible, 1 = Collapsed

-- build the whole overlay once per world (the viewport drops widgets on level change)
function UI.build()
    local pc = Game.pc
    if not valid(pc) then return false end
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local w = wbl:Create(pc, UI.cls("UserWidget"), pc)
    if not valid(w) then error("no widget") end
    UI.tree = StaticConstructObject(UI.cls("WidgetTree"), w, FName("PoppyCoopUITree"))
    w.WidgetTree = UI.tree
    UI.canvas = UI.new("CanvasPanel")
    UI.tree.RootWidget = UI.canvas
    UI.vis(UI.canvas, true)
    -- feed: left edge, a bit above the middle
    UI.feedbox = UI.new("VerticalBox")
    UI.place(UI.feedbox, 0, 0.30, 0, 0, 24, 0)
    UI.rows = {}
    for i = 1, UI.FEED_MAX do
        local row = UI.new("HorizontalBox")
        local bar = UI.bar(UI.KIND.info)
        local inner = UI.new("HorizontalBox")
        local name = UI.text("", 15, { 1.0, 0.86, 0.45 }, true)
        local msg = UI.text("", 15, { 0.95, 0.95, 0.95 })
        pcall(function() msg.WrapTextAt = 460 end)     -- property (no setter in 4.27)
        UI.hadd(inner, name, 0)
        UI.hadd(inner, msg, 0)
        local box = UI.box(inner)
        UI.hadd(row, bar, 0)
        UI.hadd(row, box, 0)
        UI.vadd(UI.feedbox, row, i == 1 and 0 or 5)
        UI.vis(row, false)
        UI.rows[i] = { row = row, bar = bar, name = name, msg = msg }
    end
    -- status panel: top right
    UI.statbox = UI.new("VerticalBox")
    UI.stat_title = UI.text("PoppyCoop", 17, UI.KIND.info, true)
    UI.vadd(UI.statbox, UI.stat_title, 0)
    UI.stat_lines = {}
    for i = 1, 11 do
        local t = UI.text("", 14, { 0.92, 0.92, 0.92 })
        UI.vadd(UI.statbox, t, i == 1 and 6 or 2)
        UI.stat_lines[i] = t
    end
    UI.stat = UI.box(UI.statbox, { 16, 10, 18, 12 }, 0.82)
    UI.place(UI.stat, 1, 0, 1, 0, -24, 24)
    UI.vis(UI.stat, false)
    -- chat menu: left, below the feed
    local cv = UI.new("VerticalBox")
    UI.vadd(cv, UI.text("CHAT", 18, UI.KIND.chat, true), 0)
    for i, ph in ipairs(UI.PHRASES) do
        local h = UI.new("HorizontalBox")
        UI.hadd(h, UI.text(tostring(i), 15, UI.KIND.chat, true), 0)
        UI.hadd(h, UI.text(ph, 15, { 0.95, 0.95, 0.95 }), 12)
        UI.vadd(cv, h, i == 1 and 8 or 3)
    end
    UI.input = UI.new("EditableTextBox")
    pcall(function() UI.input:SetHintText(FText("Type a message...")) end)
    if P.CHAPTER == 2 then pcall(function() UI.input.WidgetStyle.Font.Size = 15 end) end   -- in place (UE5 style differs)
    -- typed text: the default is dark (almost the panel colour) - light, written in place before AddToViewport.
    -- UE4 (Chapter 2) colours it with ForegroundColor, UE5 (Chapter 1) with TextStyle.ColorAndOpacity.
    local function light(c) c.R, c.G, c.B, c.A = 0.96, 0.96, 0.96, 1 end
    local st = UI.input.WidgetStyle
    if P.CHAPTER == 2 then
        pcall(function() light(st.ForegroundColor.SpecifiedColor) end)
    else
        pcall(function() light(st.TextStyle.ColorAndOpacity.SpecifiedColor) end)
        pcall(function() light(st.ForegroundColor.SpecifiedColor) end)
    end
    pcall(function() local b = st.BackgroundColor.SpecifiedColor; b.R, b.G, b.B, b.A = 0.12, 0.12, 0.15, 1 end)
    local inbox = UI.new("SizeBox")
    pcall(function() inbox:SetWidthOverride(380) end)
    inbox:SetContent(UI.input)
    UI.vadd(cv, inbox, 10)
    UI.vadd(cv, UI.text("1-8 quick message  |  Enter send  |  Esc close  |  /help", 12, { 0.65, 0.65, 0.7 }), 6)
    UI.chatpanel = UI.box(cv, { 16, 12, 18, 12 }, 0.86)
    UI.place(UI.chatpanel, 0, 0.52, 0, 0, 24, 0)
    UI.vis(UI.chatpanel, false)
    UI.vis(w, true)
    w:AddToViewport(60)
    UI.widget, UI.wbl = w, wbl
    UI.world = try(function() return UEHelpers.GetWorld():GetAddress() end)
    UI.dirty = true
    return true
end

-- forget every widget we made (they belong to a world that is going away); UI.ensure builds new ones
function UI.drop()
    UI.widget, UI.canvas, UI.chatpanel, UI.feedbox, UI.input, UI.tree = nil, nil, nil, nil, nil, nil
    UI.stat, UI.statbox, UI.stat_lines, UI.stat_title = nil, nil, nil, nil
    UI.rows, UI.world, UI.dirty = {}, nil, true
    if UI.chat then UI.chat.open = false end
end
table.insert(Handlers.unload, function() UI.drop() end)

function UI.ensure()
    if UI.state == "off" then return false end
    local world = UEHelpers.GetWorld()
    local waddr = valid(world) and try(function() return world:GetAddress() end)
    -- the world changed (respawn / Load Game): the old widgets died with it. Never touch them again - even
    -- IsValid() on a freed widget crashes the game (UE4SS +0x67881f). Compare the world FIRST.
    if UI.widget and UI.world ~= waddr then UI.drop() end
    if UI.widget and valid(UI.widget) and try(function() return UI.widget:IsInViewport() end) then return true end
    if not valid(Game.pc) then return false end
    if UI.next_try and now() < UI.next_try then return false end
    UI.next_try = now() + 2
    if UI.chat.open then UI.chat.open = false end
    local ok, err = pcall(UI.build)
    if ok and err then
        if UI.state == "new" then log("chat/message UI ready") end
        UI.state = "on"
        return true
    end
    UI.fails = (UI.fails or 0) + 1
    log("UI build failed (%d): %s", UI.fails, tostring(err))
    if UI.fails >= 3 then
        UI.state = "off"
        log("UI off - using floating text")
        for _, e in ipairs(UI.feed) do popup_fallback(e.name and (e.name .. ": " .. e.text) or e.text) end
    end
    return false
end

function UI.feed_tick(t)
    for i = #UI.feed, 1, -1 do
        local e = UI.feed[i]
        if t - e.t > (e.kind == "chat" and UI.CHAT_TIME or UI.FEED_TIME) then table.remove(UI.feed, i); UI.dirty = true end
    end
    for i = 1, UI.FEED_MAX do
        local r, e = UI.rows[i], UI.feed[i]
        if UI.dirty then
            UI.vis(r.row, e ~= nil)
            if e then
                local col = UI.KIND[e.kind]
                pcall(function() r.bar:SetBrushColor(lin(col, 1)) end)
                pcall(function() r.name:SetText(FText(e.name and (e.name .. "  ") or "")) end)
                pcall(function() r.msg:SetText(FText(e.text)) end)
            end
        end
        if e then
            local left = (e.kind == "chat" and UI.CHAT_TIME or UI.FEED_TIME) - (t - e.t)
            local op = math.max(0, math.min(1, left / UI.FADE, (t - e.t) / 0.15))
            if r.op ~= op then r.op = op; pcall(function() r.row:SetRenderOpacity(op) end) end
        end
    end
    UI.dirty = false
end

-- status panel (F11): title + lines, shown for 8 s; pressing again hides it
function P.ui_status(title, lines)
    if UI.state == "off" or not UI.ensure() then
        popup(title)
        for _, l in ipairs(lines) do popup(l) end
        return
    end
    if UI.stat_until and now() < UI.stat_until then UI.stat_until = 0; UI.vis(UI.stat, false); return end
    pcall(function() UI.stat_title:SetText(FText(title)) end)
    for i, t in ipairs(UI.stat_lines) do
        UI.vis(t, lines[i] ~= nil)
        if lines[i] then pcall(function() t:SetText(FText(lines[i])) end) end
    end
    UI.vis(UI.stat, true)
    UI.stat_until = now() + 8
end

-- chat menu --------------------------------------------------------------------
function UI.input_mode(ui)
    local pc, wbl = Game.pc, UI.wbl
    if not (valid(pc) and wbl) then return end
    -- (Chapter 1 runs on UE5, where both functions have an extra bFlushInput parameter)
    local ue5 = P.CHAPTER == 1
    if ui then
        if ue5 then pcall(function() wbl:SetInputMode_UIOnlyEx(pc, UI.input, 0, false) end)
        else pcall(function() wbl:SetInputMode_UIOnlyEx(pc, UI.input, 0) end) end
        pcall(function() UI.input:SetKeyboardFocus() end)
    else
        if ue5 then pcall(function() wbl:SetInputMode_GameOnly(pc, false) end)
        else pcall(function() wbl:SetInputMode_GameOnly(pc) end) end
    end
end
function UI.chat_text()
    local s = try(function() return UI.input:GetText():ToString() end)
    return type(s) == "string" and s or ""
end
function UI.chat_set_open(on)
    local c = UI.chat
    if on == c.open then return end
    if on and not UI.ensure() then return end
    c.open = on
    UI.vis(UI.chatpanel, on)
    pcall(function() UI.input:SetText(FText("")) end)
    c.opened_at = now()
    UI.input_mode(on)
end
-- send what was picked/typed (P.chat_send is set by main.lua: sends the event and shows "you: ...")
function UI.chat_tick()
    local c = UI.chat
    if not c.open then return end
    if not (UI.widget and valid(UI.widget)) then c.open = false; return end
    local s = UI.chat_text()
    -- the key that opened the menu may land in the box as a letter
    if now() - c.opened_at < 0.25 and #s <= 1 and not s:match("%d") then
        if s ~= "" then pcall(function() UI.input:SetText(FText("")) end) end
        return
    end
    local d = tonumber(s:match("^([1-8])$") or "")
    if d then
        UI.chat_set_open(false)
        if P.chat_send then pcall(P.chat_send, d, nil) end
        return
    end
    if c.enter then
        c.enter = false
        s = s:gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
        UI.chat_set_open(false)
        if s ~= "" and P.chat_send then pcall(P.chat_send, nil, s:sub(1, 120)) end
    elseif c.esc then
        UI.chat_set_open(false)
    end
    c.enter, c.esc = false, false
end
-- keys: chat key toggles (main.lua), Enter / Escape are bound here
P.chat_toggle = function() UI.chat.want = true end
pcall(function() RegisterKeyBind(Key.RETURN, function() if UI.chat.open then UI.chat.enter = true end end) end)
pcall(function() RegisterKeyBind(Key.ESCAPE, function() if UI.chat.open then UI.chat.esc = true end end) end)

local function popup_actor(i)
    local a = Popup.actors[i]
    if a and valid(a) then return a end
    if Popup.off then return nil end
    Popup.cls = Popup.cls or try(StaticFindObject, "/Script/Engine.TextRenderActor")
    local world = UEHelpers.GetWorld()
    if not valid(Popup.cls) or not valid(world) then return nil end
    a = try(function() return world:SpawnActor(Popup.cls, { X = 0, Y = 0, Z = -100000 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not valid(a) then Popup.off = true; log("popups unavailable (could not create text)"); return nil end
    pcall(function()
        local t = a.TextRender
        t:SetHorizontalAlignment(1)
        t:SetWorldSize(1.05)
        t:SetTextRenderColor({ R = 255, G = 214, B = 40, A = 255 })
        a:SetActorEnableCollision(false)
    end)
    Popup.actors[i] = a
    return a
end

local function popups_tick_fallback()
    if Popup.off then return end
    local t = now()
    for i = #Popup.list, 1, -1 do if t - Popup.list[i].t > POPUP_TIME then table.remove(Popup.list, i); Popup.dirty = true end end
    local pcm = Game.pc and try(function() return Game.pc.PlayerCameraManager end)
    local loc = valid(pcm) and try(function() return pcm:GetCameraLocation() end)
    local rot = loc and try(function() return pcm:GetCameraRotation() end)
    for i = 1, POPUP_MAX do
        local e = Popup.list[i]
        local a = (e or Popup.actors[i]) and popup_actor(i)
        if a then
            pcall(function()
                if Popup.dirty then
                    if FText then a.TextRender:K2_SetText(FText(e and e.text or "")) end
                    a:SetActorHiddenInGame(e == nil)
                end
                if e and loc and rot then
                    -- 30 cm in front of the eye, stacked downward from the top of the view
                    local cp, sp = math.cos(math.rad(rot.Pitch)), math.sin(math.rad(rot.Pitch))
                    local cy, sy = math.cos(math.rad(rot.Yaw)), math.sin(math.rad(rot.Yaw))
                    local fx, fy, fz = cp * cy, cp * sy, sp                  -- forward
                    local ux, uy, uz = -sp * cy, -sp * sy, cp                -- up
                    local d, up = 30, 9.5 - (i - 1) * 1.6
                    a:K2_SetActorLocationAndRotation({ X = loc.X + fx * d + ux * up, Y = loc.Y + fy * d + uy * up, Z = loc.Z + fz * d + uz * up },
                        { Pitch = -rot.Pitch, Yaw = rot.Yaw + 180, Roll = 0 }, false, {}, true)
                end
            end)
        end
    end
    Popup.dirty = false
end

popups_tick = function()
    if UI.state == "off" then return popups_tick_fallback() end
    local t = now()
    if UI.chat.want then
        UI.chat.want = false
        UI.chat_set_open(not UI.chat.open)
    end
    if #UI.feed == 0 and not UI.chat.open and not (UI.stat_until and UI.stat_until > 0) and not UI.dirty then return end
    if not UI.ensure() then return end
    UI.feed_tick(t)
    UI.chat_tick()
    if UI.stat_until and UI.stat_until > 0 and t > UI.stat_until then UI.stat_until = 0; UI.vis(UI.stat, false) end
end

-- what to pop up for: wrap the existing event handlers so the sync logic itself is untouched
local function wrap(kind, after)
    local orig = Handlers.event[kind]
    Handlers.event[kind] = function(from, rest)
        if orig then orig(from, rest) end
        local ok, err = pcall(after, from, rest)
        if not ok then log("popup %s: %s", kind, tostring(err)) end
    end
end
wrap("pfn", function(from, rest)
    local fn, args = rest:match("^([^|]+)|?(.*)$")
    if fn ~= "Add Stored Item In Inventory" then return end
    local raw = (args or ""):match("DisplayName[^=]*=([^,%s]+)")
    local item = raw and unesc(unesc(raw)):match("^s:(.*)$")
    popup(("%s picked up %s"):format(pname(from), item and pretty(item) or "an item"))
end)
wrap("cfn", function(from, rest)
    -- Chapter 2: "PlayerInventoryComponent Collect3DInventoryItem|o:/Game/.../LudwigPoppyKey_Inventory_3DItem.LudwigPoppyKey_Inventory_3DItem_C"
    local fn, args = rest:match("^%S+ ([^|]+)|?(.*)$")
    if fn ~= "Collect3DInventoryItem" then return end
    local cls = unesc(unesc(args or "")):match("%.([%w_]+)$") or ""
    local item = cls:gsub("_C$", ""):gsub("_Inventory_3DItem$", ""):gsub("_3DItem$", ""):gsub("_Inventory$", "")
    popup(("%s picked up %s"):format(pname(from), item ~= "" and pretty(item) or "an item"))
end)
wrap("hand", function(from, which)
    popup(("%s got the %s hand"):format(pname(from), which == "R" and "red" or "blue"))
end)
wrap("rhand", function(from, n)
    popup(("%s got the %s hand"):format(pname(from), tostring(n) == "1" and "green" or ("new (" .. tostring(n) .. ")")))
end)
-- cutscenes: when a level sequence starts in your game, your friends get "X is watching a cutscene" (so they
-- know to wait). Native hook on the sequence player, registered once.
do
    local last = -100
    local ok, err = pcall(function()
        RegisterHook("/Script/MovieScene.MovieSceneSequencePlayer:Play", function(self)
            if now() - last < 15 or not Coop.active() then return end
            last = now()
            local name = try(function() return self:get():GetOuter():GetFName():ToString() end) or "?"
            Coop.send_event("cutscene", tostring(name):gsub("[^%w_%-]", ""):sub(1, 60))
        end)
    end)
    if not ok then log("cutscene hook: %s", tostring(err)) end
end
Handlers.event.cutscene = function(from)
    popup("is watching a cutscene - wait for them?", "info", pname(from))
end

-- session stats (F11 panel): deaths per player, checkpoint split times
P.Stats = P.Stats or { deaths = {}, splits = {} }
wrap("died", function(from)
    local n = pname(from)
    P.Stats.deaths[n] = (P.Stats.deaths[n] or 0) + 1
    popup("died!", "warn", n)
end)
local last_cp = -100
wrap("act", function(from, rest)
    if rest:find("Checkpoint", 1, true) and (rest:find(" Trigger Checkpoint", 1, true) or rest:find(" Save New Checkpoint", 1, true)) and now() - last_cp > 20 then
        last_cp = now()
        popup("reached a checkpoint", "cp", pname(from))
    end
end)
table.insert(Handlers.join, function(id, name) popup("joined the game", "join", name or pname(id)) end)
table.insert(Handlers.leave, function(id) popup("left the game", "leave", pname(id)) end)

------------------------------------------------------------------ motion sync
local Motion = {
    off = false, errors = 0,
    tracked = {},        -- path -> { a=actor, kind="phys"|"huggy", last={...}, moved_at, driving, remote }
    scan_at = -100,
    my_ids = {}, my_next = 0,   -- path -> n (what I send)
    their = {},          -- [player id] = { [n] = path }
}
local SEND_MAX = 8
P.Motion = Motion      -- diagnostics
-- characters synced like Huggy (Chapter 1: Huggy Wuggy; Chapter 2: Mommy Long Legs, Bunzo Bunny, PJ Pug-a-Pillar)
local MONSTERS = { "huggy", "mommy", "longlegs", "bunzo", "pugapillar", "pug_a_pillar", "pjpug", "kissy" }

local function mfail(where, err)
    Motion.errors = Motion.errors + 1
    log("motion sync %s: %s", where, tostring(err))
    if Motion.errors >= 5 then Motion.off = true; log("motion sync switched off after repeated errors") end
end

-- Is this component simulating physics? Read the BodyInstance flag; calling IsSimulatingPhysics()
-- fails on Chapter 1 (UE5 wants a bone name) and every engine error leaks Lua C stack.
local function simulating(comp)
    if not valid(comp) then return false end
    local ok, v = pcall(function() return comp.BodyInstance.bSimulatePhysics end)
    return ok and v == true
end

local PHYS_CLASSES_CH1 = { "bb_arch_small3_Blueprint_C", "bb_cube7_Blueprint_C", "bb_rect11_Blueprint_C", "bb_tri2_Blueprint_C",
    "box_a6_Blueprint_C", "box_b2_Blueprint_C", "box_c2_Blueprint_C", "BP_BrokenHandBox_C", "BP_Sign_EmployeesOnly_C", "BP_Stool_C",
    "BP_ToyPart_C", "BP_Trashcan_C", "broom_Blueprint_C", "computer2_Blueprint_C", "crate_a7_Blueprint_C", "entrance_chair_Blueprint_C",
    "huggie_box4_Blueprint_C", "officechair12_Blueprint_C", "pillow_a14_Blueprint_C", "sidetable3_Blueprint_C",
    "toybox_a30_Blueprint_C", "toybox_b3_Blueprint_C" }
-- where props came to rest after someone moved them: re-applied after reloads and sent to late joiners
Motion.final = Motion.final or {}
local prop_alive              -- defined below (safe validity check by path)
local function apply_final(t, v)
    P.late(function()
        if not prop_alive(t) then return end
        t.a:K2_SetActorLocationAndRotation({ X = v[1], Y = v[2], Z = v[3] }, { Pitch = v[4], Yaw = v[5], Roll = v[6] }, false, {}, true)
        t.cur = { X = v[1], Y = v[2], Z = v[3], P = v[4], Yw = v[5], R = v[6] }
    end, "prop final")
end
-- a prop whose physics WE switched off (another player is moving it) still counts as a physics prop -
-- dropping it from the list would leave it frozen with physics off for good
local function held(a)
    local path = fullpath(a)
    local t = path and Motion.tracked[path]
    return t ~= nil and t.remote_on == true
end
-- Chapter 2: every physics-simulated prop can be pulled with the GrabPack (barrels, buckets, boxes, bins,
-- toy blocks...) - most are plain StaticMeshActors without a grab component. Scanning all ~5000 static mesh
-- actors at once costs ~45 ms, so they are checked a few hundred per frame (see motion_scan_step), the list
-- is fetched once a minute. The BP prop classes below are cheap to find directly.
local PHYS_CLASSES_CH2 = { "bb_cube7_Blueprint_C", "bb_rect11_Blueprint_C", "toybox_a30_Blueprint_C", "huggie_box4_Blueprint_C",
    "owen_the_oven_BP_C", "BP_Barrel2_C", "pillow_a14_Blueprint_C", "bunzobox_conveyor_BP_C", "BP_folded_folding_chair_C" }
local function oaddr(o) local ok, v = pcall(function() return o:GetAddress() end); return ok and v or nil end
-- streamed-out levels free their actors: never IsValid() a cached object (UE4SS crash) - look it up by path
prop_alive = function(t)
    if not t.path then return t.a ~= nil end
    local a = StaticFindObject(t.path)
    Motion.dbg = Motion.dbg or {}
    if not (a and a:IsValid()) then Motion.dbg.gone = (Motion.dbg.gone or 0) + 1; return false end
    local ad = oaddr(a)
    if t.addr and ad ~= t.addr then Motion.dbg.addr = (Motion.dbg.addr or 0) + 1; Motion.dbg.addr_ex = tostring(t.addr) .. "/" .. tostring(ad); return false end
    t.a = a
    return true
end
local function track_prop(a, path, kind)
    local t = Motion.tracked[path]
    if t then t.a = a; t.addr = oaddr(a); return t end
    t = { a = a, kind = kind or "phys", path = path, addr = oaddr(a) }
    Motion.tracked[path] = t
    local v = Motion.final[path]                  -- newly loaded: put it where it was left
    if v then apply_final(t, v) end
    return t
end
-- a prop another player moves that this game hasn't scanned (yet): look it up by its path
local function resolve_prop(path)
    if not path or not path:find(":PersistentLevel.", 1, true) then return nil end
    local a = StaticFindObject(path)
    if not (a and a:IsValid()) then return nil end
    return track_prop(a, path, "phys")
end
local function motion_scan_step()
    if P.CHAPTER ~= 2 or not ENABLE_PHYSICS then return end
    -- the census's plain StaticMeshActors, checked in the frame the census finished (an actor list must not
    -- be kept across frames: a garbage collection frees actors). Each actor is checked once (by address):
    -- the full ~5000 after a map load (hidden by loading), later only the few hundred of a new area.
    local C = P.Census
    if not (C and C.fresh) or Motion.smgen == C.gen then return end
    Motion.smgen = C.gen
    -- every 5 minutes everything is checked again (a prop can start simulating later)
    if not Motion.smchk or now() - (Motion.smchk_at or -1000) > 300 then Motion.smchk, Motion.smchk_at = {}, now() end
    local chk, now_chk, n = Motion.smchk, {}, 0
    for _, a in ipairs((C.by or {}).StaticMeshActor or {}) do
        pcall(function()
            local ad = a:GetAddress()
            local r = chk[ad]
            if r == nil then
                n = n + 1
                r = a:K2_GetRootComponent().BodyInstance.bSimulatePhysics == true
                if r then
                    local path = fullpath(a)
                    if path and path:find(":PersistentLevel.", 1, true) then track_prop(a, path, "phys") end
                end
            end
            now_chk[ad] = r
        end)
    end
    Motion.smchk = now_chk
    Motion.dbg = Motion.dbg or {}
    Motion.dbg.fetch_n, Motion.dbg.fetch_at = n, now()
end
local census   -- one pass over all actors, by class (defined after POSE_CLASSES)
local function scan_motion()
    Motion.scan_at = now()
    local seen = {}
    local function add(a, kind)
        local path = valid(a) and fullpath(a)
        if not path or seen[path] then return end
        seen[path] = true
        track_prop(a, path, kind)
    end
    if ENABLE_PHYSICS then
        -- Chapter 1's movable props (also the ones only pushed, without a grab component)
        local by = census()
        for _, cls in ipairs(P.CHAPTER == 1 and PHYS_CLASSES_CH1 or PHYS_CLASSES_CH2) do
            for _, a in ipairs(by[cls] or {}) do
                if valid(a) and (simulating(try(function() return a:K2_GetRootComponent() end)) or held(a)) then add(a, "phys") end
            end
        end
        -- props the GrabPack can grab/pull and that are simulated by physics (Chapter 1's grab component;
        -- Chapter 2 has none - FindAllOf of a missing class still walks every object)
        -- (checked 1.4.8: all 92 grab components of Chapter 1 belong to PHYS_CLASSES_CH1 - this FindAllOf (6-10 ms)
        -- found nothing new; kept as a debug option: config grab_scan=true)
        for _, c in ipairs(P.CHAPTER == 1 and (Cfg.grab_scan == true or Cfg.grab_scan == "true") and try(function() return FindAllOf("GrabpackGrabComponent") end) or {}) do
            local a = valid(c) and try(function() return c:GetOwner() end)
            if valid(a) then
                local sim = simulating(a.RootComponent)
                if sim or held(a) then add(a, "phys") end
            end
        end
    end
    if ENABLE_HUGGY then
        for _, a in ipairs(try(function() return FindAllOf("Character") end) or {}) do
            local cls = valid(a) and try(function() return a:GetClass():GetFName():ToString() end) or ""
            local l = cls:lower()
            for _, w in ipairs(MONSTERS) do
                if l:find(w, 1, true) then add(a, "huggy"); break end
            end
        end
    end
    -- Chapter 2 tracks props found incrementally: those are dropped when they stop existing (prop_alive)
    if P.CHAPTER ~= 2 then
        for path, t in pairs(Motion.tracked) do if not seen[path] then Motion.tracked[path] = nil end end
    end
end

local function my_player_loc()
    local p = Game.pawn
    return p and try(function() return p:K2_GetActorLocation() end)
end
local function dist(a, b) local x, y, z = a.X - b.X, a.Y - b.Y, a.Z - b.Z; return math.sqrt(x * x + y * y + z * z) end

-- remote control on/off: physics props stop simulating, Huggy stops walking by itself
local function set_remote(t, on)
    if t.remote_on == on then return end
    t.remote_on = on
    pcall(function()
        if t.kind == "phys" then t.a.RootComponent:SetSimulatePhysics(not on)
        else
            local cm = t.a.CharacterMovement
            if on then
                t.saved_mode = try(function() return cm.MovementMode end) or 1
                cm:SetMovementMode(0, 0)                                      -- MOVE_None: stop its own walking
            else
                cm:SetMovementMode(t.saved_mode or 1, 0)
            end
        end
    end)
end

-- outgoing: tokens for the actors this game is currently moving
table.insert(Handlers.state, function()
    if Motion.off or not Coop.active() then return "" end
    local out, n = {}, 0
    local me = my_player_loc()
    for path, t in pairs(Motion.tracked) do
        if t.driving and t.cur and n < SEND_MAX then
            local id = Motion.my_ids[path]
            if not id then
                Motion.my_next = Motion.my_next + 1
                id = Motion.my_next
                Motion.my_ids[path] = id
                Coop.send_event("mvid", id .. " " .. path)
            end
            local c = t.cur
            local d = me and dist(me, c) or 99999
            out[#out + 1] = (" M%d=%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f"):format(id, c.X, c.Y, c.Z, c.P, c.Yw, c.R, math.min(d, 99999))
            n = n + 1
        end
    end
    return table.concat(out)
end)
Coop.on("mvid", function(from, rest)
    local n, path = rest:match("^(%d+) (.+)$")
    if not n then return end
    Motion.their[from] = Motion.their[from] or {}
    Motion.their[from][tonumber(n)] = path
end)
table.insert(Handlers.join, function(id)       -- a late joiner needs our numbering too
    for path, n in pairs(Motion.my_ids) do Coop.send_to(id, "mvid", n .. " " .. path) end
end)
table.insert(Handlers.leave, function(id) Motion.their[id] = nil end)
Coop.on("mvfin", function(from, rest)
    if P.old_progress and P.old_progress(from) then return end      -- (after New Game: see coop_world P.Fresh)
    local a, b, c, d, e, f, path = rest:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.+)$")
    if not path or not path:find(":PersistentLevel.", 1, true) then return end
    local v = { tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(e), tonumber(f) }
    for i = 1, 6 do if not v[i] or v[i] ~= v[i] or math.abs(v[i]) > 2000000 then return end end
    Motion.final[path] = v
    local t = Motion.tracked[path] or resolve_prop(path)
    Motion.fin_rx = (Motion.fin_rx or 0) + 1
    if t and not t.driving then apply_final(t, v) end
end)
table.insert(Handlers.join, function(id)       -- late joiners: where everything was left
    for path, v in pairs(Motion.final) do
        Coop.send_to(id, "mvfin", ("%.1f %.1f %.1f %.1f %.1f %.1f %s"):format(v[1], v[2], v[3], v[4], v[5], v[6], path))
    end
end)

local motion_apply           -- defined below (runs from the late queue in Chapter 1)
local function motion_tick(dt)
    if Motion.off or not Coop.active() then return end
    if not ENABLE_PHYSICS and not ENABLE_HUGGY then return end
    if P.Census.fresh and Motion.gen ~= P.Census.gen then          -- a new census (levels changed / every 30-60 s)
        Motion.gen = P.Census.gen
        local c0 = os.clock()
        local ok, err = pcall(scan_motion)
        if not ok then mfail("scan", err) end
        local S = P.Perf and P.Perf.sec
        if S then S.x_mscan = (S.x_mscan or 0) + os.clock() - c0 end
        if os.clock() - c0 > 0.005 then log("slow: motion scan %.1f ms (%d tracked)", (os.clock() - c0) * 1000, (function() local n = 0 for _ in pairs(Motion.tracked) do n = n + 1 end return n end)()) end
    end
    local ok0, err0 = pcall(motion_scan_step)
    if not ok0 then mfail("scan step", err0) end
    local t_now = now()
    local me = my_player_loc()
    -- 1) read every tracked actor; decide whether this game is driving it
    for path, t in pairs(Motion.tracked) do
        -- props out of reach are read less often (every engine call costs): > 4 m 10x, > 8 m 4x, > 25 m once
        -- a second; a prop that moves or is being driven is read every frame
        local far = false
        if me and t.cur and not t.driving and not (t.remote and t_now - t.remote.t < 0.7) then
            local d = dist(me, t.cur)
            far = (d > 2500 and t_now - (t.read_at or 0) < 1) or (d > 800 and t_now - (t.read_at or 0) < 0.25)
                or (d > 400 and t_now - (t.read_at or 0) < 0.1)
        end
        local ok, err = (far and true) or pcall(function()
            t.read_at = t_now
            if not prop_alive(t) then Motion.tracked[path] = nil; return end
            local l, r = t.a:K2_GetActorLocation(), t.a:K2_GetActorRotation()
            local c = { X = l.X, Y = l.Y, Z = l.Z, P = r.Pitch, Yw = r.Yaw, R = r.Roll }
            local remote = t.remote and t_now - t.remote.t < 0.7
            if not remote then
                if t.remote_on and not t.releasing then
                    -- remote control ended: hand back to physics, but whatever it does in the next moments
                    -- (settling, sliding) is not "this player moving it" - else it echoes back and forth.
                    -- The physics switch itself runs from the late queue.
                    t.releasing = true
                    P.late(function() t.releasing = nil; if prop_alive(t) then set_remote(t, false) end end, "prop release")
                    t.quiet_until = t_now + 2.0
                end
                local last = t.cur
                if last and t.quiet_until and t_now < t.quiet_until then
                    last = nil
                elseif last then
                    local moved = math.abs(c.X - last.X) + math.abs(c.Y - last.Y) + math.abs(c.Z - last.Z) > 1.5
                        or math.abs(((c.Yw - last.Yw + 540) % 360) - 180) > 1 or math.abs(c.P - last.P) > 1
                    if moved then t.moved_at = t_now end
                end
                -- keep sending for a second after it stops, so everyone ends on the same resting spot
                local was = t.driving
                t.driving = t.moved_at ~= nil and t_now - t.moved_at < 1.0
                if was and not t.driving and t.kind == "phys" then        -- came to rest: remember + tell everyone
                    local v = { c.X, c.Y, c.Z, c.P, c.Yw, c.R }
                    Motion.final[path] = v
                    Coop.send_event("mvfin", ("%.1f %.1f %.1f %.1f %.1f %.1f %s"):format(v[1], v[2], v[3], v[4], v[5], v[6], path))
                end
            else
                t.driving = false
            end
            t.cur = c
        end)
        if not ok then mfail("read", err) end
    end
    -- 2) apply what other players are driving
    for id, pl in pairs(Net.players) do
        local map = Motion.their[id]
        local st = pl.state
        if map and st and pl.state_time and t_now - pl.state_time < 0.7 then
            for n, x, y, z, p, yw, r, d in st:gmatch(" M(%d+)=(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%d+)") do
                local path = map[tonumber(n)]
                local t = path and (Motion.tracked[path] or resolve_prop(path))
                if t then
                    local theirs = tonumber(d)
                    local mine = me and t.cur and dist(me, t.cur) or 99999
                    -- both moving it: the player closer to it keeps control (ties -> lower id)
                    local keep_mine = t.driving and (mine < theirs or (mine == theirs and (Net.myid or 0) < id))
                    if not keep_mine then
                        t.remote = { t = pl.state_time, X = tonumber(x), Y = tonumber(y), Z = tonumber(z), P = tonumber(p), Yw = tonumber(yw), R = tonumber(r), from = id }
                        t.driving = false
                    end
                end
            end
        end
    end
    Motion.dt = dt
    if P.CHAPTER ~= 1 then motion_apply() end      -- Chapter 2: no late queue, apply right here as before
end
-- 3) move remotely-driven actors smoothly toward the latest received transform - from the late queue
-- (writes to physics bodies happen after the frame's simulation/animation tasks, never inside a tick)
-- Rotations are blended as quaternions: blending pitch/yaw/roll one by one turned a tumbling prop the long way
-- round (roll 179 -> -179 went through 0) and Unreal's Euler flips (pitch past 90) made it spin wildly.
local Q = {}
function Q.from(p, y, r)            -- Unreal FRotator (degrees) -> quaternion (FRotator::Quaternion)
    local d = math.pi / 360
    local sp, cp = math.sin(p * d), math.cos(p * d)
    local sy, cy = math.sin(y * d), math.cos(y * d)
    local sr, cr = math.sin(r * d), math.cos(r * d)
    return { x = cr * sp * sy - sr * cp * cy, y = -cr * sp * cy - sr * cp * sy,
             z = cr * cp * sy - sr * sp * cy, w = cr * cp * cy + sr * sp * sy }
end
function Q.to(q)                    -- quaternion -> FRotator (FQuat::Rotator)
    local x, y, z, w = q.x, q.y, q.z, q.w
    local sing = z * x - w * y
    local yaw = math.deg(math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
    local pitch, roll
    if sing < -0.4999995 then
        pitch = -90; roll = ((-yaw - 2 * math.deg(math.atan(x, w)) + 180) % 360) - 180
    elseif sing > 0.4999995 then
        pitch = 90; roll = ((yaw - 2 * math.deg(math.atan(x, w)) + 180) % 360) - 180
    else
        pitch = math.deg(math.asin(2 * sing))
        roll = math.deg(math.atan(-2 * (w * x + y * z), 1 - 2 * (x * x + y * y)))
    end
    return pitch, yaw, roll
end
function Q.slerp(a, b, t)           -- shortest way
    local dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    local bx, by, bz, bw = b.x, b.y, b.z, b.w
    if dot < 0 then dot = -dot; bx, by, bz, bw = -bx, -by, -bz, -bw end
    local s0, s1
    if dot > 0.9995 then s0, s1 = 1 - t, t
    else
        local th = math.acos(dot)
        local sn = math.sin(th)
        s0, s1 = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn
    end
    local q = { x = s0 * a.x + s1 * bx, y = s0 * a.y + s1 * by, z = s0 * a.z + s1 * bz, w = s0 * a.w + s1 * bw }
    local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    if l > 0 then q.x, q.y, q.z, q.w = q.x / l, q.y / l, q.z / l, q.w / l end
    return q
end
P.Q = Q   -- (tests)

motion_apply = function()
    if Motion.off or not Coop.active() or Game.loading then return end
    local t_now, dt = now(), Motion.dt or 0.016
    for path, t in pairs(Motion.tracked) do
        local rm = t.remote
        if rm and t_now - rm.t < 0.7 and t.cur then
            local ok, err = pcall(function()
                if not prop_alive(t) then Motion.tracked[path] = nil; return end
                set_remote(t, true)
                local c, k = t.cur, math.min(1, dt * 12)
                local far = math.abs(rm.X - c.X) + math.abs(rm.Y - c.Y) + math.abs(rm.Z - c.Z) > 400
                if far then k = 1 end
                local nx = { X = c.X + (rm.X - c.X) * k, Y = c.Y + (rm.Y - c.Y) * k, Z = c.Z + (rm.Z - c.Z) * k }
                local np, nyw, nro = Q.to(Q.slerp(Q.from(c.P, c.Yw, c.R), Q.from(rm.P, rm.Yw, rm.R), k))
                local nr = { Pitch = np, Yaw = nyw, Roll = nro }
                t.a:K2_SetActorLocationAndRotation(nx, nr, false, {}, true)
                t.cur = { X = nx.X, Y = nx.Y, Z = nx.Z, P = nr.Pitch, Yw = nr.Yaw, R = nr.Roll }
            end)
            if not ok then mfail("apply", err) end
        end
    end
end

------------------------------------------------------------------ discovery dump
-- Once per session, ~40 s into a level: write the player's functions/properties and the kinds of actors
-- present (hands, monsters, physics, pickups...) to classdump_ch<N>.txt. Read-only; used to support
-- each chapter's own mechanics. One pass, every call guarded.
local Dump = { done = false, at = nil }
local DUMP_WORDS = { "hand", "grab", "death", "dead", "kill", "die", "monster", "mommy", "bunzo", "huggy", "kissy", "pug",
    "physic", "pickup", "item", "key", "door", "puzzle", "power", "battery", "elevator", "checkpoint", "inventory", "train", "game" }
local function dump_classes()
    Dump.done = true
    local lines = { ("PoppyCoop class dump - chapter %s - %s"):format(tostring(P.CHAPTER), os.date("%Y-%m-%d %H:%M:%S")) }
    local pawn = Game.pawn
    local pcls = pawn and try(function() return pawn:GetClass() end)
    if valid(pcls) then
        lines[#lines + 1] = "== player class " .. tostring(fullpath(pcls))
        local fns, props = {}, {}
        pcall(function() pcls:ForEachFunction(function(f) fns[#fns + 1] = f:GetFName():ToString() end) end)
        pcall(function() pcls:ForEachProperty(function(pr)
            props[#props + 1] = pr:GetFName():ToString() .. " : " .. pr:GetClass():GetFName():ToString()
        end) end)
        table.sort(fns); table.sort(props)
        lines[#lines + 1] = "-- functions (" .. #fns .. ")"
        for _, f in ipairs(fns) do lines[#lines + 1] = "  " .. f end
        lines[#lines + 1] = "-- properties (" .. #props .. ")"
        for _, pr in ipairs(props) do lines[#lines + 1] = "  " .. pr end
        -- components
        pcall(function()
            local comps = pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
            lines[#lines + 1] = "-- components"
            for i = 1, #comps do
                local c = comps[i]:get()
                if c:IsValid() then lines[#lines + 1] = "  " .. c:GetFName():ToString() .. " : " .. tostring(fullpath(c:GetClass())) end
            end
        end)
    end
    local counts = {}
    for _, a in ipairs(try(function() return FindAllOf("Actor") end) or {}) do
        local cn = valid(a) and try(function() return fullpath(a:GetClass()) end)
        if cn then
            local l = cn:lower()
            for _, w in ipairs(DUMP_WORDS) do
                if l:find(w, 1, true) then counts[cn] = (counts[cn] or 0) + 1; break end
            end
        end
    end
    local names = {}
    for cn in pairs(counts) do names[#names + 1] = cn end
    table.sort(names)
    lines[#lines + 1] = "== interesting actor classes in the world (" .. #names .. ")"
    for _, cn in ipairs(names) do lines[#lines + 1] = ("  %4d  %s"):format(counts[cn], cn) end
    -- every character / pawn type (monsters, NPCs)
    local chars = {}
    for _, a in ipairs(try(function() return FindAllOf("Pawn") end) or {}) do
        local cn = valid(a) and try(function() return fullpath(a:GetClass()) end)
        if cn then chars[cn] = (chars[cn] or 0) + 1 end
    end
    local cl = {}
    for cn in pairs(chars) do cl[#cl + 1] = cn end
    table.sort(cl)
    lines[#lines + 1] = "== pawns / characters (" .. #cl .. ")"
    for _, cn in ipairs(cl) do lines[#lines + 1] = ("  %4d  %s"):format(chars[cn], cn) end
    -- physics-simulated objects (first 40)
    local phys, n = {}, 0
    for _, a in ipairs(try(function() return FindAllOf("StaticMeshActor") end) or {}) do
        if n >= 40 then break end
        local sim = valid(a) and simulating(try(function() return a.StaticMeshComponent end))
        if sim then n = n + 1; phys[#phys + 1] = "  " .. tostring(fullpath(a)) end
    end
    for _, c in ipairs(try(function() return FindAllOf("GrabpackGrabComponent") end) or {}) do
        local a = valid(c) and try(function() return c:GetOwner() end)
        if valid(a) then phys[#phys + 1] = "  (grabbable) " .. tostring(fullpath(a)) end
    end
    lines[#lines + 1] = "== physics objects (" .. #phys .. ")"
    for _, l in ipairs(phys) do lines[#lines + 1] = l end
    local f = io.open(P.MOD_DIR .. "\\classdump_ch" .. tostring(P.CHAPTER) .. ".txt", "w")
    if f then f:write(table.concat(lines, "\n"), "\n"); f:close() end
    log("wrote class dump (%d lines)", #lines)
end

------------------------------------------------------------------ pose sync (Chapter 2)
-- Moving parts of interactive objects (door leaves, floor hatches, levers, crane handles, catwalks,
-- vent covers, cut-outs, gates...) are synced by their actual transform: while a part moves in one
-- game, its relative location/rotation is streamed and the other games follow it smoothly. The last
-- pose of every part is remembered and re-applied after a level reload or for late joiners, so an
-- opened door stays open for everyone, in the direction and at the angle it was really opened.
local POSE_CLASSES = {
    DoorBP_C = { "Right Door Pivot", "Left Door Pivot" },
    -- Chapter 1 doors swing around these pivots
    DoubleDoors_C = { "LeftDoorSwingPoint", "RightDoorSwingPoint" }, SingleDoors_BP_C = { "LeftDoorSwingPoint" },
    factorygrate_BP_C = true,
    -- Chapter 1: bridges in the factory pulled into place with the GrabPack
    TwoWayBridge_BP_C = true, MachineBridgeOneWay_BP_C = true,
    BP_FloorDoor_C = true, BP_PullLever_C = true, GarageLever_C = true, BP_Hub_CraneHandle_C = true,
    BP_CraneHandle_C = true, catwalk_pivot_C = true, BP_SlidingGate_C = true, PullOffVent_Office_C = true,
    PullOffVent_C = true, BP_PullOffSpiderWeb_C = true, Huggy_Grabpack_cutout_BP_C = true,
    Mommy_Text_Cutout_BP_C = true, Kissy_Train_Cutout_ButtonBP_C = true, Mommy_Train_CutoutBP_C = true,
    BP_MoveableCart_C = "actor", BP_MoveableCrane_C = "actor", ["BP_Crane-ableDino_C"] = "actor",
    BP_BreakableWoodenWall_C = true, BP_SpiderWall_Large_C = true, BP_SpiderWall_Single_C = true,
    vent_door_BP_C = true, CloseDoorVentDoor_C = true, giftshopdoor_BP_C = true, TwoStateMoveable_C = true,
    boogiebot_cutout_BP_C = true, Bunzo_CutoutBP_C = true, candycat_cutout_BP_C = true, catbee_cutout_BP_C = true,
    Dino_Cart_CutoutBP_C = true, pj_cutout_BP_C = true, Sunflower_Cutout_ButtonBP_C = true,
    ChooChooTrainPull_C = true,          -- the train handle pulled with the GrabPack
    -- not here: the furnace doors (BP_FurnaceDoor*) move themselves every tick (open / slam shut in the Mommy
    -- chase); streaming their pose fought that animation - they flickered open/closed and Mommy got through.
    -- not here: gates/doors driven by power (LargeGate_Moveable, EventRaiseLowerDoors...) - their power
    -- signal is replayed, so they animate by themselves in every game; streaming them too would jitter
}
local Pose = { parts = {}, byKey = {}, final = {}, scan_at = -100, read_at = 0, sent = {}, off = false, errors = 0, alive_cache = {} }
P.Pose = Pose      -- diagnostics
local POSE_EPS_ROT, POSE_EPS_LOC = 0.4, 0.4
local function pfail(where, err)
    Pose.errors = Pose.errors + 1
    log("pose sync %s: %s", where, tostring(err))
    if Pose.errors >= 8 then Pose.off = true; log("pose sync switched off after repeated errors") end
end
local function pkey_esc(s) return (s:gsub(" ", "%%20")) end
local function level_placed(path) return path and path:find(":PersistentLevel.", 1, true) and not path:match("_21474%d%d%d%d%d$") end

local function read_pose(c, actor)
    if actor then
        local l, r = c:K2_GetActorLocation(), c:K2_GetActorRotation()
        return { r.Pitch, r.Yaw, r.Roll, l.X, l.Y, l.Z }
    end
    local r, l = c.RelativeRotation, c.RelativeLocation
    return { r.Pitch, r.Yaw, r.Roll, l.X, l.Y, l.Z }
end
local function pose_diff(a, b)
    if not a or not b then return true end
    for i = 1, 3 do if math.abs(((a[i] - b[i] + 540) % 360) - 180) > POSE_EPS_ROT then return true end end
    for i = 4, 6 do if math.abs(a[i] - b[i]) > POSE_EPS_LOC then return true end end
    return false
end
local function write_pose(e, v)
    local c = e.comp
    if e.actor then
        c:K2_SetActorLocationAndRotation({ X = v[4], Y = v[5], Z = v[6] }, { Pitch = v[1], Yaw = v[2], Roll = v[3] }, false, {}, true)
        e.last = v
        return
    end
    if e.sim == nil then e.sim = simulating(c) end
    if e.sim then pcall(function() c:SetSimulatePhysics(false) end); e.sim = false end
    c:K2_SetRelativeLocationAndRotation({ X = v[4], Y = v[5], Z = v[6] }, { Pitch = v[1], Yaw = v[2], Roll = v[3] }, false, {}, true)
    e.last = v
end

-- Parts live in streaming levels that can be unloaded at any time (e.g. the other player's area).
-- A cached engine object must never be touched after that (IsValid on a freed object crashes UE4SS),
-- so before each use the part's actor is looked up fresh by its path and compared by address.
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end); return ok and a or nil end
local function alive(e)
    local t = now()
    local c = Pose.alive_cache[e.apath]
    if c and c.t == t then return c.ok end
    local a = StaticFindObject(e.apath)
    local exists = a ~= nil and a:IsValid()
    local ok = exists and addr(a) == e.aaddr
    -- the level came back (new object at the same path): rescan soon so its final pose is re-applied
    if exists and not ok then P.Census.want = true end
    Pose.alive_cache[e.apath] = { t = t, ok = ok }
    return ok
end

-- Every FindAllOf("SomeClass") walks the engine's whole object list (~10-30 ms), even for a class that
-- doesn't exist in this chapter. Scanning ~50 prop/part classes that way froze the game for 200-300 ms every
-- few seconds. One FindAllOf("Actor") plus each actor's class name costs ~15 ms (Chapter 1) and finds them all.
-- Subclasses are matched through the class's parents (looked up once per class name and remembered).
local CENSUS_WANT = {}
for k in pairs(POSE_CLASSES) do CENSUS_WANT[k] = true end
for _, k in ipairs(PHYS_CLASSES_CH1) do CENSUS_WANT[k] = true end
for _, k in ipairs(PHYS_CLASSES_CH2) do CENSUS_WANT[k] = true end
if P.CHAPTER == 2 then CENSUS_WANT.StaticMeshActor = true end   -- physics props without a class of their own
-- hard mode (config hard_mode=true, launcher "Harder enemies"): enemies (every Character that isn't a player)
-- get faster with more players in the room: +15 % per extra player, at most +45 %.
local HARD = Cfg.hard_mode == true or Cfg.hard_mode == "true"
if HARD then CENSUS_WANT.Character = true end
local HardDone = {}      -- actor address -> true (speed already raised)
local CensusKind = {}   -- class name -> wanted class it counts as, or false
-- The census runs when the set of loaded levels changes (new areas = new props/parts/classes) and otherwise
-- only every 30 s (Chapter 1) / 60 s (Chapter 2), always within ONE frame: the actor list must not be kept
-- across frames (a garbage collection in between frees actors, touching them crashes UE4SS). Each actor's
-- class is remembered by its address, so a census is FindAllOf("Actor") (~12-16 ms) plus a table lookup per
-- actor; only actors not seen before have their class read (the expensive part, ~5 us each).
local CENSUS_EVERY = 60
local CENSUS_MIN_GAP = 5                -- streaming comes in bursts: at most one census per 5 s
local Census = { by = {}, classes = {}, gen = 0, at = -100, levels = -1, lv_at = -100, want = true }
P.Census = Census
P.CensusDone = P.CensusDone or {}       -- functions(classes) run when a census finished (coop_world hooks classes)
local CensusAddr = {}                    -- actor address -> class name (cleared on map change)
local function census_kind(cls)
    local sc = cls
    for _ = 1, 12 do
        if not (sc and sc:IsValid()) then break end
        local n = sc:GetFName():ToString()
        if CENSUS_WANT[n] then return n end
        if n == "Actor" or n == "Object" then break end
        sc = sc:GetSuperStruct()
    end
    return false
end
local function census_levels()
    local f = P.level_count
    return f and f() or -1
end
local function census_step()
    Census.fresh = false                 -- the last census's actor lists are only usable in the frame it ran
    local t = now()
    if t - Census.lv_at > 1 then
        Census.lv_at = t
        local n = census_levels()
        if n ~= Census.levels then Census.levels, Census.want = n, true end
    end
    if not ((Census.want and t - Census.at > CENSUS_MIN_GAP) or t - Census.at > CENSUS_EVERY) then return end
    Census.want, Census.at = false, t
    local list = try(function() return FindAllOf("Actor") end) or {}
    local by, classes, seen_now = {}, {}, {}
    for i = 1, #list do
        local a = list[i]
        pcall(function()
            local ad = a:GetAddress()
            local cn = CensusAddr[ad]
            if not cn then
                local cls = a:GetClass()
                cn = cls:GetFName():ToString()
                CensusAddr[ad] = cn
                if CensusKind[cn] == nil then CensusKind[cn] = census_kind(cls) end
            end
            seen_now[ad] = cn
            if not classes[cn] then classes[cn] = { cls = a:GetClass(), a = a } end   -- fresh: a level reload makes a new class
            local w = CensusKind[cn]
            if w then
                local l = by[w]
                if not l then l = {}; by[w] = l end
                l[#l + 1] = a
            end
        end)
    end
    CensusAddr = seen_now                -- forget actors that are gone (their address may be reused)
    Census.by, Census.classes, Census.gen, Census.at, Census.fresh = by, classes, Census.gen + 1, now(), true
    for _, f in ipairs(P.CensusDone) do pcall(f, classes) end
end
P.census_step = census_step
if HARD then
    table.insert(P.CensusDone, function()
        local n = 1
        for id in pairs(Net.players) do if id < 900 then n = n + 1 end end
        if n < 2 then return end
        local f = 1 + 0.15 * math.min(3, n - 1)
        for _, a in ipairs((Census.by or {}).Character or {}) do
            local ad = try(function() return a:GetAddress() end)
            if ad and not HardDone[ad] then
                HardDone[ad] = true
                local cn = try(function() return a:GetClass():GetFName():ToString() end) or ""
                if not cn:find("PlayerBP", 1, true) then
                    pcall(function()
                        local cm = a.CharacterMovement
                        cm.MaxWalkSpeed = cm.MaxWalkSpeed * f
                    end)
                    log("hard mode: %s x%.2f", cn, f)
                end
            end
        end
    end)
    table.insert(Handlers.unload, function() HardDone = {} end)
end
census = function() return Census.by end
table.insert(Handlers.unload, function()
    Census.by, Census.classes, Census.want, Census.levels = {}, {}, true, -1
    CensusAddr = {}
end)

local function pose_scan()
    Pose.scan_at = now()
    local parts, byKey = {}, {}
    local by = census()
    for cls, spec in pairs(POSE_CLASSES) do
        for _, a in ipairs(by[cls] or {}) do
            local path = valid(a) and fullpath(a)
            if level_placed(path) then
                local comps = {}
                if spec == "actor" then
                    comps[#comps + 1] = { name = "@actor", c = a, actor = true }
                elseif type(spec) == "table" then
                    for _, prop in ipairs(spec) do
                        local c = try(function() return a[prop] end)
                        if valid(c) then comps[#comps + 1] = { name = prop, c = c } end
                    end
                else
                    local root = try(function() return a:K2_GetRootComponent() end)
                    pcall(function()
                        local list = a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent"))
                        for i = 1, #list do
                            local c = list[i]:get()
                            if valid(c) and not (valid(root) and c:GetAddress() == root:GetAddress()) then
                                local n = c:GetFName():ToString()
                                local cn = c:GetClass():GetFName():ToString()
                                -- only things that can visibly move: meshes and plain scene pivots
                                if cn:find("Mesh") or cn == "SceneComponent" then comps[#comps + 1] = { name = n, c = c } end
                            end
                        end
                    end)
                end
                local al = try(function() return a:K2_GetActorLocation() end)
                local aaddr = addr(a)
                for _, it in ipairs(comps) do
                    local key = pkey_esc(path .. "|" .. it.name)
                    local old = Pose.byKey[key]
                    local caddr = addr(it.c)
                    local e = { key = key, comp = it.c, actor = it.actor, apath = path, aaddr = aaddr, caddr = caddr }
                    -- reuse the old entry only if it is the very same object (compared by address, never touched)
                    if old and old.caddr and old.caddr == caddr and old.aaddr == aaddr then e = old else
                        local ok, v = pcall(read_pose, it.c, it.actor)
                        e.last = ok and v or nil
                    end
                    if al then e.pos = { al.X, al.Y, al.Z } end
                    parts[#parts + 1] = e
                    byKey[key] = e
                end
            end
        end
    end
    Pose.parts, Pose.byKey = parts, byKey
end

local function pose_send(e, v, final)
    Coop.send_event("pose", ("%s %.2f %.2f %.2f %.1f %.1f %.1f %d"):format(e.key, v[1], v[2], v[3], v[4], v[5], v[6], final and 1 or 0))
end

local function pose_tick(dt)
    if Pose.off or not Coop.active() then return end
    local t = now()
    if P.Census.fresh and Pose.gen ~= P.Census.gen then       -- new census: levels changed (new areas) or every 30-60 s
        Pose.gen = P.Census.gen
        local c0 = os.clock()
        local ok, err = pcall(pose_scan)
        if not ok then pfail("scan", err) end
        local S = P.Perf and P.Perf.sec
        if S then S.x_pscan = (S.x_pscan or 0) + os.clock() - c0 end
        if os.clock() - c0 > 0.005 then log("slow: pose scan %.1f ms (%d parts)", (os.clock() - c0) * 1000, #Pose.parts) end
    end
    -- remote targets: ease towards them every frame
    for _, e in ipairs(Pose.parts) do
        if e.target and e.remote_until and t < e.remote_until and alive(e) then
            local cur, tg = e.last or e.target, e.target
            local k = math.min(1, dt * 15)
            local v = {}
            for i = 1, 3 do v[i] = cur[i] + ((((tg[i] - cur[i] + 540) % 360) - 180) * k) end
            for i = 4, 6 do v[i] = cur[i] + (tg[i] - cur[i]) * k end
            local ok, err = pcall(write_pose, e, v)
            if not ok then pfail("apply", err) end
        end
    end
    if t - Pose.read_at < 0.1 then return end
    Pose.read_at = t
    -- only parts near this player can be moved by this player; far ones are just re-checked rarely
    local me = Game.pawn and try(function() return Game.pawn:K2_GetActorLocation() end)
    local slow = t - (Pose.slow_at or 0) > 2
    if slow then Pose.slow_at = t end
    for _, e in ipairs(Pose.parts) do
        local near = true
        if me and e.pos and not e.actor then
            local dx, dy, dz = e.pos[1] - me.X, e.pos[2] - me.Y, e.pos[3] - me.Z
            near = dx * dx + dy * dy + dz * dz < 2500 * 2500
        end
        if (near or slow or e.moving) and not (e.remote_until and t < e.remote_until) and alive(e) then
            local ok, v = pcall(read_pose, e.comp, e.actor)
            if ok then
                if pose_diff(v, e.last) then
                    e.last, e.moved_at, e.moving = v, t, true
                    if t - (e.sent_at or 0) > 0.08 then e.sent_at = t; pose_send(e, v, false) end
                elseif e.moving and t - (e.moved_at or 0) > 0.6 then
                    e.moving = false
                    Pose.final[e.key] = v
                    pose_send(e, v, true)                         -- came to rest: the final pose
                elseif not e.moving then
                    -- after a level reload a part is back at its start pose: put it where it was left
                    local fv = Pose.final[e.key]
                    if fv and pose_diff(v, fv) and t - (e.applied_at or 0) > 2 then
                        e.applied_at = t
                        e.target, e.remote_until = fv, t + 0.8
                    end
                end
            end
        end
    end
end

Coop.on("pose", function(from, rest)
    if P.old_progress and P.old_progress(from) then return end
    local key, a, b, c, x, y, z, fin = rest:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%d)")
    if not key then return end
    local v = { tonumber(a), tonumber(b), tonumber(c), tonumber(x), tonumber(y), tonumber(z) }
    -- public rooms: ignore garbage (nan / absurd values)
    for i = 1, 6 do if not v[i] or v[i] ~= v[i] or math.abs(v[i]) > 2000000 then return end end
    local e = Pose.byKey[key]
    if e and not e.actor and e.last then
        -- a part moves within its object: a relative offset of more than 30 m is not a real pose
        for i = 4, 6 do if math.abs(v[i] - e.last[i]) > 3000 then return end end
    end
    if fin == "1" then Pose.final[key] = v end
    if not e then return end                       -- not loaded here: the final pose is applied when it is
    e.target, e.remote_until, e.moving = v, now() + (fin == "1" and 1.5 or 0.8), false
end)
-- late joiners get every final pose
table.insert(Handlers.join, function(id)
    for key, v in pairs(Pose.final) do
        Coop.send_to(id, "pose", ("%s %.2f %.2f %.2f %.1f %.1f %.1f 1"):format(key, v[1], v[2], v[3], v[4], v[5], v[6]))
    end
end)
table.insert(Handlers.unload, function() Pose.parts, Pose.byKey, Pose.scan_at, Pose.alive_cache = {}, {}, -100, {} end)

------------------------------------------------------------------ animation sync (Chapter 1 bridges)
-- Some pullable things are animated skeletal meshes: pulling plays an animation (the catwalks in the
-- Make-A-Friend factory). Their transforms never change, so pose sync can't see them. Instead the
-- animation asset and its position are synced (live while it plays, and the final position).
local ANIM_SYNC = { TwoWayBridge_BP_C = { "SkeletalMesh_Bridge" }, MachineBridgeOneWay_BP_C = { "SkeletalMesh" } }
local Anim = { parts = {}, byKey = {}, final = {}, scan_at = -100, read_at = 0 }
for k in pairs(ANIM_SYNC) do CENSUS_WANT[k] = true end
P.Anim = Anim      -- diagnostics
local function anim_read(c)
    local si = c.AnimScriptInstance
    local asset = si and si:GetAddress() ~= 0 and si.CurrentAsset
    local ap = (asset and asset:GetAddress() ~= 0) and fullpath(asset) or ""
    return { ap, c:GetPosition() }
end
local function anim_scan()
    Anim.scan_at = now()
    local parts, byKey = {}, {}
    for cls, props in pairs(ANIM_SYNC) do
        for _, a in ipairs(census()[cls] or {}) do
            local path = valid(a) and fullpath(a)
            if level_placed(path) then
                for _, prop in ipairs(props) do
                    local c = try(function() return a[prop] end)
                    if valid(c) then
                        local key = pkey_esc(path .. "|" .. prop)
                        local e = Anim.byKey[key]
                        local caddr = addr(c)
                        if not (e and e.caddr == caddr) then
                            e = { key = key, comp = c, apath = path, aaddr = addr(a), caddr = caddr }
                            local ok, v = pcall(anim_read, c)
                            e.last = ok and v or nil
                        end
                        parts[#parts + 1] = e
                        byKey[key] = e
                    end
                end
            end
        end
    end
    Anim.parts, Anim.byKey = parts, byKey
end
local function anim_apply(e, asset, pos)
    local c = e.comp
    if not e.last or e.last[1] ~= asset then
        local obj = StaticFindObject(asset)
        if not (obj and obj:IsValid()) then return end
        c:PlayAnimation(obj, false)
    end
    c:SetPosition(pos, false)
    -- no Stop(): stopping the bridge animation froze both games once; it plays on to its end like the sender's
    e.last = { asset, pos }
    e.remote_until = now() + 0.6
end
local function anim_tick()
    if Pose.off or not Coop.active() then return end
    local t = now()
    if P.Census.fresh and Anim.gen ~= P.Census.gen then
        Anim.gen = P.Census.gen
        local ok, err = pcall(anim_scan)
        if not ok then pfail("anim scan", err) end
    end
    if t - Anim.read_at < 0.15 then return end
    Anim.read_at = t
    for _, e in ipairs(Anim.parts) do
        if not (e.remote_until and t < e.remote_until) and alive(e) then
            local ok, v = pcall(anim_read, e.comp)
            if ok and v[1] ~= "" then
                local last = e.last
                if not last or last[1] ~= v[1] or math.abs(last[2] - v[2]) > 0.01 then
                    e.last, e.moved_at, e.moving = v, t, true
                    Coop.send_event("apose", ("%s 0 %.4f %s"):format(e.key, v[2], v[1]))
                elseif e.moving and t - (e.moved_at or 0) > 0.6 then
                    e.moving = false
                    Anim.final[e.key] = v
                    Coop.send_event("apose", ("%s 1 %.4f %s"):format(e.key, v[2], v[1]))
                elseif not e.moving then
                    local fv = Anim.final[e.key]          -- after a reload: back to where it was left
                    if fv and (fv[1] ~= v[1] or math.abs(fv[2] - v[2]) > 0.01) then
                        e.remote_until = t + 0.6
                        pcall(anim_apply, e, fv[1], fv[2])
                    end
                end
            end
        end
    end
end
Coop.on("apose", function(from, rest)
    if P.old_progress and P.old_progress(from) then return end
    local key, fin, pos, asset = rest:match("^(%S+) (%d) (%S+) (%S+)$")
    pos = tonumber(pos)
    if not key or not pos or pos ~= pos or pos < 0 or pos > 1000 or not asset:find("^/Game/") then return end
    if fin == "1" then Anim.final[key] = { asset, pos } end
    local e = Anim.byKey[key]
    if e and alive(e) then
        -- animation calls only from the late queue (main.lua Late: after the frame's animation tasks)
        P.late(function()
            if not alive(e) then return end
            local ok, err = pcall(anim_apply, e, asset, pos)
            if not ok then pfail("anim apply", err) end
        end, "anim apply")
        e.moving = false
    end
end)
table.insert(Handlers.join, function(id)
    for key, v in pairs(Anim.final) do Coop.send_to(id, "apose", ("%s 1 %.4f %s"):format(key, v[2], v[1])) end
end)
table.insert(Handlers.unload, function() Anim.parts, Anim.byKey, Anim.scan_at = {}, {}, -100 end)
-- physics props moved by other players: late queue only
if P.Late then table.insert(P.Late.every, { function() motion_apply() end, "motion_apply" }) end
-- reading/applying bridge animation: late queue only (never inside an actor tick)
if P.CHAPTER == 1 and P.Late then
    table.insert(P.Late.every, { function()
        if not Coop.active() or not Game.pawn or Game.loading then return end
        local ok, err = pcall(anim_tick)
        if not ok then pfail("anim", err) end
    end, "anim_tick" })
end

------------------------------------------------------------------ minigame sync (Chapter 2)
-- Shared progress in the game-station games: whoever wins the game wins it for everyone (the room opens
-- for all, nobody has to replay it). Everyone plays their own pattern; rounds/mistakes are not shared
-- (SuccessfulRound only runs part of the round logic when called from outside - tested, left out).
-- Whack-a-Wuggy is played TOGETHER: every hit ("Add Hit") counts in every game, so both players' hits add up
-- to the 40 needed. (Statues is an escape - each player has to get out themselves - so it is not shared.)
local MINIGAMES = {
    { cls = "GameshowController_C", win = "WinTheGame", wonVar = "GameWon" },                       -- Musical Memory
    -- (no direct win: "Win!"/"Complete Game" called from outside reset the game - tested. Shared hits make
    -- every game reach the 40 hits itself and win on its own.)
    { cls = "Whack-A-Mole_Controller_C", wonVar = "Won Game", share = { "Add Hit" } },               -- Whack-a-Wuggy
}
P.MINIGAMES = MINIGAMES
for _, g in ipairs(MINIGAMES) do CENSUS_WANT[g.cls] = true end
local MG = { hooked = {}, applying = false, scan_at = -100, sent = 0, applied = 0 }
P.MG = MG
local function mg_send(i, kind, obj)
    if MG.applying or not Coop.active() then return end
    local g = MINIGAMES[i]
    local path = fullpath(obj)
    if not (g and path and level_placed(path)) then return end
    local val = 0
    if kind == "round" then val = tonumber(try(function() return obj[g.roundVar] end)) or 0 end
    MG.sent = MG.sent + 1
    Coop.send_event("mg", ("%d %s %d %s"):format(i, kind, val, path))
    log("minigame: shared %s (%s %d)", kind, g.cls, val)
end
local function mg_share_cb(i, j)
    return function(ctx)
        if MG.applying or not Coop.active() then return end
        local o = try(function() return ctx:get() end)
        local path = o and fullpath(o)
        if path and level_placed(path) then Coop.send_event("mgs", ("%d %d %s"):format(i, j, path)); MG.sent = MG.sent + 1 end
    end
end
local function mg_win_cb(i)
    return function(ctx) local o = try(function() return ctx:get() end); if o then mg_send(i, "win", o) end end
end
-- Hooks are registered once per function. One registered right after a load can fail ("UFunction::Func:
-- 0x0", not linked yet): only a hook that really worked is marked done, the others are retried in 5 s.
local ENABLE_MINIGAMES = Cfg.sync_minigames ~= false and Cfg.sync_minigames ~= "false"   -- launcher setting
local function mg_hook(from_census)
    if P.CHAPTER ~= 2 or not ENABLE_MINIGAMES then return end
    MG.retry_at = nil
    MG.scan_at = now()
    MG.ok = MG.ok or {}
    for i, g in ipairs(MINIGAMES) do
        if not MG.hooked[g.cls] then
            MG.cp = MG.cp or {}
            local cp = MG.cp[g.cls]
            if not cp and from_census then
                local a = (census()[g.cls] or {})[1]
                local cls = valid(a) and try(function() return a:GetClass() end)
                cp = cls and fullpath(cls)
                MG.cp[g.cls] = cp
            end
            if cp then
                local all = true
                local wanted = {}
                if g.win then wanted[#wanted + 1] = { g.win, mg_win_cb(i) } end
                for j, fn in ipairs(g.share or {}) do wanted[#wanted + 1] = { fn, mg_share_cb(i, j) } end
                for _, w in ipairs(wanted) do
                    local key = cp .. ":" .. w[1]
                    if not MG.ok[key] then
                        local ok = pcall(RegisterHook, key, w[2])
                        if ok then MG.ok[key] = true else all = false end
                    end
                end
                if all then MG.hooked[g.cls] = true else MG.retry_at = now() + 5 end
                log("minigame sync for %s: %s", g.cls, all and "on" or "retrying")
            end
        end
    end
end
-- a shared step of a minigame (e.g. a Whack-a-Wuggy hit) done by another player: do it here too
Coop.on("mgs", function(from, rest)
    local i, j, path = rest:match("^(%d+) (%d+) (%S+)$")
    local g = i and MINIGAMES[tonumber(i)]
    local fn = g and g.share and g.share[tonumber(j)]
    if not (fn and level_placed(path)) then return end
    local a = StaticFindObject(path)
    if not (a and a:IsValid()) then return end
    if try(function() return a[g.wonVar] end) == true then return end
    MG.applying = true
    pcall(function() a[fn](a) end)
    MG.applying = false
    MG.applied = MG.applied + 1
end)
Coop.on("mg", function(from, rest)
    local i, kind, val, path = rest:match("^(%d+) (%a+) (%-?%d+) (%S+)$")
    i, val = tonumber(i), tonumber(val)
    local g = i and MINIGAMES[i]
    if not (g and (kind == "round" or kind == "win") and level_placed(path)) then return end
    local a = StaticFindObject(path)
    if not (a and a:IsValid()) then return end
    if try(function() return a[g.wonVar] end) == true then return end          -- already won here
    if kind == "round" then
        local r = tonumber(try(function() return a[g.roundVar] end))
        if r ~= val then return end                                         -- not on that round (any more)
    end
    MG.applying = true
    local ok, err = pcall(function() a[kind == "win" and g.win or g.round](a) end)
    MG.applying = false
    MG.applied = MG.applied + 1
    log("minigame: %s from %s applied (%s) %s", kind, pname(from), g.cls, ok and "" or tostring(err))
    popup(kind == "win" and (pname(from) .. " won the game for everyone") or (pname(from) .. " cleared the round"))
end)

------------------------------------------------------------------ wiring
-- Alone in a room for a while: the usual reason is a different code or a different chapter (rooms are
-- per chapter - a Chapter 2 code typed into Chapter 1 opens an empty Chapter 1 room). Say so once.
local Alone = { since = nil, told = false }
local function alone_tick()
    if Alone.told or not Coop.active() then return end
    if next(Net.players) ~= nil then Alone.told = true; return end      -- someone was here: never nag
    if tostring(P.Config.room or "") == "public" then return end
    Alone.since = Alone.since or now()
    if now() - Alone.since > 45 then
        Alone.told = true
        popup(("Nobody in room %s yet. Everyone needs the same code AND the same chapter (Chapter %d)."):format(tostring(P.Config.room), P.CHAPTER or 0))
    end
end

table.insert(Handlers.tick, function(dt, have)
    if not have then return end
    local crumb = P.crumb or function() end
    -- experimental chapters: only popups (no prop / pose / minigame scans) unless "Try world sync" is on
    if P.EXPERIMENTAL and not (Cfg.exp_world == true or Cfg.exp_world == "true") then
        crumb("extra: popups"); popups_tick()
        crumb("extra: alone"); pcall(alone_tick)
        return
    end
    -- levels are being torn down / loaded (dying, teleport, area unloaded): no scans over the world's objects
    -- and no moving of props until it is over (see P.Quiet in coop_world)
    if P.quiet and P.quiet() then crumb("extra: popups (quiet)"); popups_tick(); return end
    crumb("extra: census")
    local cc = os.clock()
    pcall(census_step)
    if os.clock() - cc > 0.008 then log("slow: census step %.1f ms", (os.clock() - cc) * 1000) end
    crumb("extra: popups"); popups_tick()
    crumb("extra: alone"); pcall(alone_tick)
    local c0 = os.clock()
    crumb("extra: motion"); motion_tick(dt)
    local c1 = os.clock()
    crumb("extra: pose"); pose_tick(dt)
    local S = P.Perf and P.Perf.sec
    if S then S.x_motion = (S.x_motion or 0) + c1 - c0; S.x_pose = (S.x_pose or 0) + os.clock() - c1 end
    if P.CHAPTER == 2 and P.Census.fresh and MG.gen ~= P.Census.gen then MG.gen = P.Census.gen; crumb("extra: minigames"); pcall(mg_hook, true)
    elseif MG.retry_at and now() > MG.retry_at then pcall(mg_hook, false) end
    crumb("extra: done")
    -- bridges are skeletal meshes animated in parallel worker tasks: reading/setting their animation
    -- inside the player's tick waited on those tasks and froze the game (seen in a debugger). Run it at
    -- UE4SS's game-thread point instead (outside any actor tick), at most one job queued at a time.
    -- (bridge animation sync runs from the late queue, see below / main.lua Late)
end)
table.insert(Handlers.unload, function()
    -- the level is going away: forget every engine object
    Popup.actors, Popup.cls = {}, nil
    Motion.tracked, Motion.scan_at = {}, -100
    -- the candidate list holds objects of the old world; the next list is fetched 10 s after the load
    -- (right after it only a handful of actors exist yet)
    Motion.smchk = {}
end)
-- the class dump (debug) used to run automatically and froze/crashed big levels; now only on request
RegisterConsoleCommandHandler("coop_dump", function(_, _, out)
    local ok, err = pcall(dump_classes)
    pcall(function() out:Log(ok and "class dump written" or ("class dump failed: " .. tostring(err))) end)
    return true
end)

------------------------------------------------------------------ deep dump (file trigger, CH2 has no console)
-- Create ue4ss\Mods\PoppyCoop\dump_now.txt (content = label). Writes deepdump_<label>.txt with the player's,
-- its components' and GrabPack/hand actors' functions and current property values. Read-only.
local SIMPLE = { BoolProperty = 1, IntProperty = 1, ByteProperty = 1, FloatProperty = 1, EnumProperty = 1, ObjectProperty = 1, NameProperty = 1 }
local function fmtval(v, ptype)
    local t = type(v)
    if t == "boolean" or t == "number" or t == "string" then return tostring(v) end
    if t == "userdata" and ptype == "ObjectProperty" then
        local ok, r = pcall(function() if v:IsValid() then return v:GetFName():ToString() end return "None" end)
        return ok and tostring(r) or "?"
    end
    if t == "userdata" and ptype == "NameProperty" then
        local ok, r = pcall(function() return v:ToString() end)
        return ok and tostring(r) or "?"
    end
    return "(" .. t .. ")"
end
local function dump_obj(lines, obj, title)
    local cls = try(function() return obj:GetClass() end)
    if not valid(cls) then return end
    local cname = tostring(fullpath(cls))
    lines[#lines + 1] = ("== %s %s (class %s)"):format(title, tostring(try(function() return obj:GetFName():ToString() end)), cname)
    if cname:find("/Script/", 1, true) == 1 then return end           -- engine/native class: name only
    local fns, props = {}, {}
    pcall(function() cls:ForEachFunction(function(f) fns[#fns + 1] = f:GetFName():ToString() end) end)
    pcall(function() cls:ForEachProperty(function(pr)
        props[#props + 1] = { pr:GetFName():ToString(), pr:GetClass():GetFName():ToString() }
    end) end)
    table.sort(fns)
    lines[#lines + 1] = ("  %d functions, %d properties (own class only)"):format(#fns, #props)
    for _, f in ipairs(fns) do lines[#lines + 1] = "    fn " .. f end
    for _, pr in ipairs(props) do
        local n, ty = pr[1], pr[2]
        local v = ""
        if SIMPLE[ty] then
            local ok, raw = pcall(function() return obj[n] end)
            v = " = " .. (ok and fmtval(raw, ty) or "?")
        end
        lines[#lines + 1] = ("    pr %s : %s%s"):format(n, ty, v)
    end
end
local function deep_dump(label)
    local lines = { ("PoppyCoop deep dump '%s' - player %s - chapter %s - %s"):format(label, tostring(P.Config.name), tostring(P.CHAPTER), os.date("%Y-%m-%d %H:%M:%S")) }
    local gi = try(function() return FindFirstOf("GameInstance") end)
    if valid(gi) then dump_obj(lines, gi, "GAMEINSTANCE") end
    local pc = try(function() return UEHelpers.GetPlayerController() end)
    if valid(pc) then dump_obj(lines, pc, "CONTROLLER") end
    local pawn = Game.pawn
    if not valid(pawn) then lines[#lines + 1] = "no pawn" else
        dump_obj(lines, pawn, "PAWN")
        local comps = try(function() return pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent")) end)
        if comps then
            for i = 1, math.min(#comps, 80) do
                local c = try(function() return comps[i]:get() end)
                if valid(c) then
                    dump_obj(lines, c, "COMPONENT")
                    local ca = try(function() return c.ChildActor end)
                    if valid(ca) then dump_obj(lines, ca, "CHILDACTOR") end
                end
            end
        end
    end
    local f = io.open(P.MOD_DIR .. "\\deepdump_" .. label .. ".txt", "w")
    if f then f:write(table.concat(lines, "\n"), "\n"); f:close() end
    log("wrote deep dump '%s' (%d lines)", label, #lines)
end
-- dev exec (CH2 debugging without restarts): ue4ss\Mods\PoppyCoop\exec_now.txt = "<player name>" on the
-- first line, Lua code below. Runs in the game thread; result/errors -> exec_out_<name>.txt
local function run_exec()
    local fn = P.MOD_DIR .. "\\exec_now.txt"
    local f = io.open(fn, "r")
    if not f then return end
    local who = f:read("*l") or ""
    local code = f:read("*a") or ""
    f:close()
    if who ~= tostring(P.Config.name) then return end
    os.remove(fn)
    local out = {}
    local env = setmetatable({ P = P, Game = Game, log = log, try = try, valid = valid,
        out = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end out[#out + 1] = table.concat(t, "\t") end },
        { __index = _G })
    if P.crumb then P.crumb("dev exec: " .. code:gsub("%s+", " "):sub(1, 70)) end
    local chunk, err = load(code, "exec", "t", env)
    local res
    if chunk then local ok, r = pcall(chunk); res = (ok and "OK " or "ERROR ") .. tostring(r) else res = "COMPILE " .. tostring(err) end
    out[#out + 1] = res
    local o = io.open(P.MOD_DIR .. "\\exec_out_" .. tostring(P.Config.name) .. ".txt", "w")
    if o then o:write(table.concat(out, "\n"), "\n"); o:close() end
end
local dump_check = 0
-- developer tools (deep dump, exec) only run when ue4ss\Mods\PoppyCoop\dev_exec_on.txt exists
local DEV_TOOLS = (function() local f = io.open(P.MOD_DIR .. "\\dev_exec_on.txt", "r"); if f then f:close(); return true end return false end)()
table.insert(Handlers.tick, function(dt, have)
    if not DEV_TOOLS then return end
    dump_check = dump_check + (dt or 0)
    if dump_check < 2 then return end
    dump_check = 0
    pcall(run_exec)
    local fn = P.MOD_DIR .. "\\dump_now.txt"
    local f = io.open(fn, "r")
    if not f then return end
    local line = f:read("*l") or "x"
    f:close()
    local lbl, who = line:match("^(%S+)%s+(%S+)")
    if who and who ~= tostring(P.Config.name) then return end   -- meant for the other game window
    os.remove(fn)
    local label = ((lbl or line) .. "_" .. tostring(P.Config.name)):gsub("[^%w_%-]", "_")
    if label == "" then label = "x" end
    local ok, err = pcall(deep_dump, label)
    if not ok then log("deep dump failed: %s", tostring(err)) end
end)
-- dev exec also outside of gameplay (main menu, loading): poll once a second on the game thread.
-- Only when a dev file exists, so normal players never run anything here.
local function dev_exec_enabled()
    local f = io.open(P.MOD_DIR .. "\\dev_exec_on.txt", "r")
    if f then f:close(); return true end
    return false
end
if dev_exec_enabled() then
    LoopAsync(1000, function()
        -- in game the tick runs the exec file; queueing a job every second as well put Lua on UE4SS's
        -- ExecuteInGameThread queue all the time (suspected in the freezes) - menu only now
        if Game.pawn ~= nil or (P.game_time and P.game_time() > 0 and Game.map ~= "?" and Game.map ~= "MainMenu") then return false end
        ExecuteInGameThread(function()
            -- never touch cached objects here: during a level change they are already freed
            -- (IsValid on a freed object crashes UE4SS). The exec file is consumed once, so running
            -- it from here and from the game tick is harmless.
            pcall(run_exec)
        end)
        return false
    end)
    log("dev exec: menu poller on")
end
Coop.on("ping_popup", function(from, msg) popup(pname(from) .. ": " .. tostring(msg)) end)

log("extras loaded (popups=%s physics=%s huggy=%s)", tostring(ENABLE_POPUPS), tostring(ENABLE_PHYSICS), tostring(ENABLE_HUGGY))

-- New Game: forget where doors, hatches, gates and props were left (they were put back there after every
-- load - in the new game too)
if P.NewGameReset then
    table.insert(P.NewGameReset, function()
        Motion.final, Pose.final, Anim.final = {}, {}, {}
        Pose.sent = {}
    end)
end
