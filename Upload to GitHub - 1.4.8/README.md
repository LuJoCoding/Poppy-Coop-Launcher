# Poppy Playtime Co-op (PoppyCoop)

An unofficial online co-op mod for **Poppy Playtime Chapter 1** and **Chapter 2 (beta)** on PC (Steam).
It's free to play, with no account needed. You just need the launcher.

> Fan-made. Not affiliated with or endorsed by Mob Entertainment.

## Download

Download **`PoppyCoop_Launcher_1.4.8.zip`** from this folder (or from Releases), unzip it,
and run **`PoppyCoopLauncher.exe`**.

Windows may show "Windows protected your PC" because the launcher isn't signed:
click **More info → Run anyway**. The same exe also runs on Linux / Steam Deck through Proton.

## How to play

1. Start the launcher and **click the chapter** you want to play. Only then it sets that chapter up - you
   don't need Chapter 1 to play Chapter 2.
2. The launcher finds the game by itself (Steam libraries, and Steam's download folder where a version
   downgraded with the Steam console always lands). If it can't find it, it says so and you pick the folder.
3. Enter your name, pick a colour and press **Install co-op mod**.
4. One player presses **Create Game** and sends the room code (or the invite). The others press **Join Game**
   and paste it. Or everyone uses **Quick Play** for the public lobby.
5. Press **PLAY**. In the game everyone loads the **same checkpoint** (Play → Load Game).
6. If Windows Firewall asks about `PoppyCoopNet.exe`, click **Allow**.

Everyone needs the **same launcher version**, or the mods won't match. Older installs are updated
automatically when you press PLAY.

### Settings

- **Chapter settings** (button at the top right of a chapter): change the keys (click, then press the new key)
  and switch what is shared - doors & puzzles, picked-up items, inventory, GrabPack hands, pullable objects,
  loaded areas, minigames (Chapter 2), on-screen messages. Everyone in a room should use the same switches.
  Reinstall, uninstall, change or open the game folder here too.
- **Server** (card at the bottom left): the free PoppyCoop relay (default), **Host on this PC**, or your own
  entries (a friend's IP who hosts, or another relay). Every server shows how good the connection is: signal
  bars, ping, jitter and packet loss. Everyone you play with has to pick the same server.
  Hosting needs UDP port 27777 forwarded in your router and a real public IPv4 address (not DS-Lite).
- **Launcher settings** (bottom left): language (English / Deutsch), theme (Dark / Midnight / Light), accent colour,
  animations on/off. The launcher tells you when a new version is out.

### Keys (default)

| Key | What it does |
| --- | --- |
| **F6** | Teleport to another player (loads their area first, so you don't fall out of the map; with 3+ players each press goes to the next one) |
| **F7** | Buddy figure that follows you (solo testing / clips) |
| **O / P** | Record your movement / replay it as a second player (trailer clips) |
| **T** | Ping: marks the spot you look at for everyone |
| **Y** | Quick chat: each press picks the next phrase, it is sent a moment later |
| **F10** | Status: version, fps, ping, play time, deaths and where your friends are. (`coop_status` in the console still works.) |

Change them in the launcher (chapter settings). F8 and F9 are intentionally left free for other mods.

## What's shared

**Chapter 1:** player figures - a faceless mannequin with a round head in your colour (walk, run, crouch, jump,
lying down when dead) carrying the real Chapter 1 GrabPack (shown once that player has it); launched hands are
the real game hands with the same angle and grab state (holding on = closed hand) and a black cable; doors
(real swing), buttons, power, code and hand pads, puzzles, picked-up items, inventory, checkpoints, deaths;
boxes, toy blocks, chairs and other physics props (while moved and where they were left); the pull platforms
in the factory; which parts of the factory are loaded.

**Chapter 2 (beta):** full player figures with GrabPack and animations (crouching figures stay on the floor);
launched hands with cable; the green hand (if one player has it, everyone gets it); doors, floor hatches,
levers, crane handles, vents, spider webs, wooden walls, cut-outs and carts; puzzle pieces (furnace doors,
gears, molds, paint cartridges, garage levers); power, switches, keys, items and checkpoints; **everything the
GrabPack can pull** (barrels, buckets, boxes, bins, ladders, toy blocks, toy boxes, chairs, the train handle...);
**minigames**: Musical Memory - whoever wins, wins for everyone; Whack-a-Wuggy - played together, everyone's
hits add up. Statues is an escape and stays per player.

**2, 3 or more players** can share a room. Checkpoints only move forward: a player who is behind can't reset
everyone else's "Load Game" position. Areas a friend is in are loaded for you when you press F6 (or always,
with the switch "Keep friends' areas loaded").

Rooms are public, so the mod only accepts the actions it sends itself from other players (power, switches,
puzzle steps, inventory, item pickups, moving parts with sane values). Anything else is dropped.

## Troubleshooting

- **Can't see anyone:** press F10 (status shows the players), or type `coop_status` in the F10 console.
  - `helper=down`: `PoppyCoopNet.exe` is blocked or was removed by an antivirus. Restore it, allow it, and press PLAY again.
  - Different room: check that the code matches exactly. Copy and paste it instead of typing it.
  - Different chapter or server: everyone must pick the same chapter and the same server in the launcher.
- **Server card shows "No connection":** the free relay has a daily limit. It resets at 01:00 Irish time.
- **Uninstall:** chapter settings → *Uninstall*. The game goes back to normal.

## For developers

- The mod is Lua for UE4SS 3.0.1 (`ue4ss/Mods/PoppyCoop/Scripts`, see `mod-scripts/`). The launcher embeds these
  scripts and installs them.
- The launcher is in `launcher-source/` (C++, Win32 + GDI, built with mingw-w64; see its README). UE4SS, its
  loader and `PoppyCoopNet.exe` are taken from the original launcher 2.0 (`extract_res.py`).
- Developer tools are **off** for players. Turn them on by creating these files in `ue4ss/Mods/PoppyCoop/`:
  - `dev_exec_on.txt`: deep dumps (`dump_now.txt`) and running Lua from `exec_now.txt`.
  - `perf_on.txt`: performance report every 15 s (`perf_<name>.txt`).
  - `trace_on.txt`: log of every hooked call (slow).
  - `crumbs_on.txt`: writes the last block the mod entered to `crumb_<name>.txt` (to find freezes).
- Chapter 1: never call animation functions (PlayAnimation, SetAnimationMode, GetPosition, GetSocketLocation on
  an animated mesh) from the player tick - they wait for the engine's parallel animation tasks, which need
  UE4SS's lock -> the game freezes. Queue them with `late()` (runs in the crosshair widget's Tick).
- Rule of thumb: no engine errors in normal play. Each error leaks memory in UE4SS 3.0.1 and eventually crashes the game.

## Changelog

### 1.4.8
- **One game for everyone:** levers, switches and the Game Station lights now work for everyone (the level's own
  lever events are shared, e.g. the first power lever lights up the whole Game Station for all players).
- **Following a friend (F6):** if your friend is further ahead, F6 first loads their checkpoint (chases and won
  games are over for you too), then puts you next to them. No more being "caught" after you already arrived.
- **Chases:** when a friend escapes a chase you are still in (Statues, Mommy's chase), you are brought to them
  automatically after 3 s (launcher switch "Follow out of chases").
- **Fixed deaths from falling through the floor** when a friend reached a checkpoint or loaded a game room, and a
  friend's minigame (Statues, Mommy) no longer hunts you somewhere else. Friends' areas are no longer kept loaded
  in the background by default (switch "Keep friends' areas loaded"); F6 loads them when needed.
- **Much less lag in long sessions:** game hooks were registered again after every death and piled up (less fps
  the longer you played). Now each one is hooked once. Object scans run far less often.
- **Chapter 2 hands like Chapter 1:** the friend's GrabPack hand turns and grabs like the real one, its cable bends
  around corners like the real cable and glows green when it carries power. The friend's flashlight casts light.
- **New keys:** T = ping a spot for everyone, Y = quick chat ("Come here!", "Wait for me!", "Help!" ...),
  F10 = status (fps, ping, play time, deaths and where your friends are: "35 m at 2 o'clock").
- Stand on a friend's head to reach higher spots, optional respawn at a friend, friends' footsteps, distance on
  name tags, split time at every checkpoint, smoother figures, "Connection lost / Reconnected" messages and a
  version check when someone joins.
- **Launcher:** German / English, update notice when a new version is out, "What's new", your last room codes as
  buttons, "Show game log" (copies a short report for Discord), "Limit to 60 fps".

### 1.4.0
- **New launcher (Launcher 3.0)**, written from scratch (source in `launcher-source/`):
  - A chapter is only set up when you click it - no Chapter 1 folder needed for Chapter 2. Welcome page on
    the first start.
  - Automatic game search, including Steam's download folder (Steam-console downgrades); a clear "not found"
    page with *Choose folder* / *Search again* otherwise.
  - Chapter settings: keys and sync switches per chapter, reinstall / uninstall / change folder.
  - Server page: PoppyCoop relay, host on your own PC, or your own servers, each with a connection quality
    display (signal bars, ping, jitter, loss).
  - Launcher settings: Dark / Midnight / Light theme, accent colour, smooth animations (can be turned off).
  - Keeps your name, colour, codes and game folders from the old launcher. One exe for Windows and Proton.
- **Chapter 2 pullable objects:** everything the GrabPack can pull moves for everyone and stays where it was
  left (also after reloads and for late joiners); the train handle too.
- **Chapter 2 minigames:** Musical Memory - whoever wins, wins for everyone. Whack-a-Wuggy - everyone's hits
  add up, both games reach 40 hits and win.
- **Chapter 2 figure:** crouching players crouch on the floor instead of floating.
- **Teleport (F6)** first loads your friend's area and only then teleports you; if you still fall, you're put
  back on your friend. Areas your own game had hidden are shown again while a friend is in them.

### 1.3.6
- **Chapter 1 player figure:** mannequin with a round head (like the game's player model), jointed arms and legs,
  walk/run/crouch/jump/dead poses, in your colour, with the real Chapter 1 GrabPack (backpack, both launchers,
  hands on the tubes). GrabPack and the red hand only show once that player really has them.
- **Chapter 1 hands:** launched hands are the game's own animated hand, turned like the sender's hand and
  closed when they hold on to something. Short shots are shown too (a hand counts as launched once it leaves
  its launcher). The cable comes out of the tube.
- **Chapter 1 objects:** boxes, crates, toy boxes, blocks, chairs, tables, stools, bins, signs, brooms, toy
  parts... are shared while moved and stay where they were left (also after reloads and for late joiners).
  The pull platforms in the factory move for everyone (no more standing in mid-air).
- **Freeze fix (Chapter 1):** animation and physics calls now run after the frame's animation work (they
  deadlocked with UE4SS's lock before). The mod also no longer goes silent after a checkpoint reload.
- Launcher: old installs (e.g. the original 1.1.0 mod) are now detected as outdated and updated
  (the installed-version check compared against a constant that was never patched).

### 1.3.5
- Chapter 1: doors swing for everyone exactly as opened; code pad and hand pad synced; crash fixes for areas
  that are unloaded while you play.

### 1.3.4
- Chapter 2: launched hands turn toward where they were shot (palm to the target).

### 1.3.3
- Merge of both 1.3.2 lines (keybinds.txt / dev tools opt-in / 30 s scan + the changes below).
- 3+ players: checkpoints only move forward; the teleport key cycles through all players.
- Public rooms: incoming events are whitelisted, moving-part values are range-checked.
- Rooms are per chapter (a Chapter 2 code in Chapter 1 opens an empty Chapter 1 room). If you're alone in a
  room for 45 s, the game now tells you to check the code and the chapter.
- Chapter 2 figures: hands sit on the launcher tubes, palms forward; launched hands start at the launcher
  (they used to start at the figure's feet); the cable comes out of the tube.

### 1.3.2
- Keys can be changed in `keybinds.txt` (teleport, buddy, record, play). A launcher Customisation tab is planned once the launcher source is in the repo.

### 1.3.1
- Teleport moved from **F8 to F6** (F8/F9 are used by other mods).
- Developer tools (deep dump, exec, perf log) are now off unless a dev file exists. Normal players no longer
  get a perf log file that grows forever.
- Chapter 2: the door/lever/puzzle scan runs every 30 s instead of 10 s (still immediately after every level load),
  which cuts the small regular stutter.

### 1.3.0
- Chapter 2 playable (beta): real player figures, pose sync, puzzle sync, green hand sync, F8 teleport,
  crash fix when reloading a checkpoint, smoother launcher.

### 1.1.0
- Fixed 0 fps freezes and crashes (no more full material scans or class dumps). Player colours use one tinted
  toy paint instead of random materials. Huggy and physics sync are off by default (Huggy keeps his chase animation).
