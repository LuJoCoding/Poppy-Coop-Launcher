# Poppy Playtime Co-op (PoppyCoop)

An unofficial online co-op mod for **Poppy Playtime Chapter 1** and **Chapter 2 (beta)** on PC (Steam) - and, as an experiment, **Chapters 3-5**.
It's free to play, with no account needed. You just need the launcher.

> Fan-made. Not affiliated with or endorsed by Mob Entertainment.

## Download

Download **`PoppyCoop_Launcher_1.7.1.zip`**
from this folder (or from Releases), unzip it, and run **`PoppyCoopLauncher.exe`**.

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
  animations on/off. The launcher tells you when a new version is out and can update itself.
- **Experimental chapters** (launcher settings): Chapters 3, 4 and 5 can be tried. You see each other and can
  teleport, ping and chat, but doors, puzzles and items are not shared yet (chapter switch "Try world sync"
  turns it on at your own risk), and the game may crash.
- **Several games at once** (launcher settings): for Nucleus Co-op / split screen. With a game running, PLAY
  becomes PLAY ANOTHER and starts another window with its own name and colour in the same room.
  Command line for Nucleus handlers / scripts:
  `PoppyCoopLauncher.exe --play --chapter N [--name X] [--color C] [--room CODE] [--dir "game folder"] [--multi]`
  (errors are written to `%APPDATA%\PoppyCoop\cli_last_error.txt`).

### Keys (default)

| Key | What it does |
| --- | --- |
| **F6** | Teleport to another player (loads their area first, so you don't fall out of the map; with 3+ players each press goes to the next one) |
| **F7** | Buddy figure that follows you (solo testing / clips) |
| **O / P** | Record your movement / replay it as a second player (trailer clips) |
| **T** | Ping: marks the spot you look at for everyone |
| **Y** | Chat menu: 1-8 quick messages, or type a message + Enter (Esc closes). `/help` lists the chat commands (`/tp`, `/stats`, `/report`, `/solid`, `/spectate`, ...) |
| **F11** | Status panel: version, fps, ping, play time, deaths, split times and where your friends are. (F10 is the UE4SS console; `coop_status` there still works.) |

Change them in the launcher (chapter settings) - they apply to every chapter. F8 and F9 are intentionally left free for other mods, F10 opens the console.

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

- **Can't see anyone:** press F11 (status shows the players), or type `coop_status` in the F10 console.
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

### 1.7.1
- **Fixed (Chapter 1): your friend got teleported back to the power room** whenever you respawned or pressed Load Game. The game's checkpoint-loading script was sent to them and ran in their game.
- **Fixed (Chapter 1): out of bounds on the conveyor after Make-A-Friend** (the vents were not loaded for the player who didn't scan the doll). Loading the next area is shared again; only unloading / hiding is not.
- **Fixed (Chapter 1): invisible wall and Huggy staring at you** - the Huggy chase start (Huggy, his lights, the walls closing the way back) is no longer sent to the other player; each game starts it when its player gets there.
- **Chapter 1 breakers:** the blue one on top now disappears for the other player too, and breakers a friend picks up stay in your inventory (the game's own moving of the item was sent back and took it away again).
- **Fixed: interacting with the code pad removed it for the other player** (1.7.0). Picked-up things are only removed for others when they really went into the inventory.

### 1.7.0
- **Chapter 1: doors no longer shut in front of you.** When the game closed a door behind one player (Huggy chase, Make-A-Friend), the door closed for everyone - the other player was locked out. Closing is now only local.
- **Chapter 1: no more falling through the floor / invisible walls / out of bounds** after a friend moved on. A friend's "unload this area" was applied to your game while you were still in it. Each game now loads and unloads only for its own player.
- **Chapter 1 Make-A-Friend:** the levers (toy tubes) are synced; the toy machine no longer starts by itself or drops extra grey boxes in the other game.
- **Picked-up things that the game spawns** (breakers, the Make-A-Friend doll) now disappear for everyone too.
- **GrabPack hands:** if anyone in the team has a hand, you get it too - also after joining later or Load Game into a friend's checkpoint.
- **Flashlight on F** (Chapter 1) - e.g. after F6 into the Huggy chase. Changeable in the launcher's key settings.
- **"Host on this PC" with several games on one PC:** the second game joins the first by itself (no more switching servers).
- **Crouching friends** no longer sink into the floor (Chapter 1).
- **Fixed: a crash right after respawning.**

### 1.6.9
- **Chapter 1: "Load Game" starts at the team's furthest checkpoint.** If a friend is further (e.g. at Make-A-Friend), pressing Load Game in the main menu loads that checkpoint for you, at its normal spawn point. Only on that button - nothing happens by itself after a death.
- **Chapter 1: the breakers in the red hand room have the same colours on the same spots for everyone.**
- **Chapter 1: Huggy's key and other picked-up things (the Make-A-Friend toy...) disappear for everyone** once one player takes them. This now also works in Speedrun mode.
- **Chapter 1: the vent door that opens when Huggy is triggered opens for everyone.**
- **Fixed (Chapter 2): a crash where the mod asked the game about a door part from inside a game event.**
- Fixed: after an area loaded, friends' figures in Chapter 2 could lose their cable parts.

### 1.6.8
- **Chapter 1: the breakers ("batteries") in the red hand room are synced.** The game puts them on random spots, different in every game. Now everyone gets the same spots, and a breaker one player picks up disappears for everyone.
- **Fixed (Chapter 1): the blue hand box stood open after "New Game".** A friend leaving their game for the main menu opened it. The box is no longer synced (the blue hand itself is still given to everyone).

### 1.6.7
- **Fixed (Chapter 1): both players crashed in the Steam Hallway when Storage loaded** (the area with the red hand). Walking through the hallway unloads the power room; the mod still held on to parts of it and read them after the game had freed them. It now looks everything up fresh.
- The players' figure paint and animations are looked up fresh too, so they can't point at something an unloaded area took with it.

### 1.6.6
- **Fixed (Chapter 1): the power room short circuit only happened for the player at the scanner.** When one player puts the hand on the scanner and the power shorts out, it now shorts out for everyone.
- **Fixed (Chapter 1): restoring the power only worked for the player who solved the puzzle.** The others had to do it all again. Now the whole power-up (scanner, lights, doors) happens for everyone.
- **Fixed: another Chapter 1 crash a little while after an area was loaded or unloaded** (e.g. after the power room). The mod used remembered parts of objects the game had replaced.

### 1.6.5
- **Fixed: Chapter 1 crash for both players after the power / hand scanner part.** The mod touched parts of an area the game had just unloaded.
- **Fixed (Chapter 1): hand scanners still weren't synced when both players had power.** A power event from a friend made the game hold back its own scans for a few seconds. Now every scan goes through - the other players see the charge bar and the roll-up door opens for everyone.
- **Fixed: "New Game" didn't reset everything.** Door leaves, hatches (e.g. the blue hand hatch), gates and moved props were put back where they were left in the old game. A new game now starts completely fresh, also when a friend is further.
- **Fixed (Chapter 2): the furnace doors flickered open and shut and Mommy could get through.** They move by themselves now, as in the normal game, and aren't re-opened after you die.

### 1.6.4
- **Fixed: crashes after dying, respawning or teleporting to a friend** (mostly Chapter 2). The mod touched game objects while the game was tearing the level down. It now stays quiet during these moments; what your friends did meanwhile is applied right after.
- **Fixed: crashes in Chapter 1 shortly after a roll-up door opened** (both players crashed).
- **Fixed: sometimes nothing was synced any more after joining.** A game could start treating everything its own player did as coming from a friend and stopped sending doors, codes and scanners.
- **Chapter 1: hand scanners are synced live.** When one player puts the hand on a scanner, the other players see the same scan (charge bar, sound) and the door opens for everyone.
- **Chapter 1: the door behind the security code opens for everyone** when one player enters the code.
- **Fixed: after "New Game" the door behind the code stood open.** A new game now also forgets the keys and the friends' old progress (doors, items, hand) - what they do from now on still comes through.

### 1.6.3
- **Fixed (Chapter 1): roll-up doors behind hand scanners didn't open for the other players.** When one player used the blue hand scanner (or the two-hand pad / the power room pad), the scanner turned green for everyone but the door only opened for that player. The doors themselves are synced now - however they were opened. Players who join later get them open too.
- **Fixed: after "New Game" doors stayed open** (e.g. the hallway door after taking the blue hand). The mod remembered everything that was opened before and opened it again in the new game. Now a new game starts with a clean slate; Load Game and respawns still restore everything as before.
- **Split screen:** with "Several games at once" (launcher settings) the game windows are placed for you - left / right, top / bottom, or one per monitor - without frames, and kept in place (they don't jump around any more when you click into the other one).

### 1.6.1
- **Friends (new):** every player has a friend code like `Max#12345` (Friends page, bottom left). Send a friend request with it - once it's accepted you see when your friends are online, which chapter and room they're in, and can join them with one click. Players you played with show up under "Recently played with".
- **Crash reports (new, only if you allow it):** at the first start the launcher asks whether it may send a crash report when the game crashes - the error, the end of the mod's log, the mod version and your Windows version, without user names. It helps us fix crashes. Change it any time in the launcher settings.

### 1.6.0
- **The co-op mod is only active when you start the game with PLAY in the launcher.** Started from Steam or the game's exe, Poppy Playtime is completely normal again - handy for solo runs. Other UE4SS mods keep working.
- New launcher setting **"Co-op without the launcher"**: turns co-op on for Steam starts too - for the Steam Deck game mode.
- **Logs page:** long logs can be scrolled now (mouse wheel over the log, Page Up / Page Down, Home / End) - the whole session, not only its end.
- **Fixed: a player could show up twice** after their connection dropped and came back (the old figure stayed). Late position updates of a player who left are ignored now, and a player who rejoins replaces their old figure.
- **Fixed: "X has an older mod version (before 1.4.8)" spam** on shaky connections. The mod asks for the version again before warning, and warns only once per player.

### 1.5.9
- **Linux & Steam Deck: AppImage.** Download `PoppyCoop_Launcher.AppImage`, make it executable and double-click it. It finds Steam and Proton by itself and runs the launcher like a normal app. Games start exactly like from Steam.
- **Proper window bar on Linux:** under Proton the launcher now draws its own dark title bar instead of the old Windows 95 one (drag to move, double-click to maximize, resize at the edges).
- **Fixed: "Report zip" on the Logs page didn't work on Linux / Steam Deck.** It works everywhere now; on Linux the zip is saved in the launcher folder.
- **What's new** is a real page in the launcher now instead of a message box.

### 1.5.8
- **New: Logs page** for every chapter (button next to *Settings*). It lists your last game sessions with date, length, mod version and error count. Sessions that ended in a crash are red and show the crash message. One click copies a short report for Discord, or makes `PoppyCoop_report.zip` with the log, the crash report and the network logs. The launcher keeps the last 15 sessions per chapter, so a crash log isn't lost any more when you start the game again.
- **Chapter 2 is out of beta.**

### 1.5.7
- **Fixed: doors, levers, items and checkpoints stopped syncing after a while** (both chapters). After a short connection hiccup the game sent its whole world state at once and the network helper threw it away. Messages are now bundled and sent in portions.
- **Fixed: crashes after respawning or Load Game** - the message boxes of the old world were still being used.
- **Chapter 1: checkpoints are shared again, instantly** - Load Game and respawns put you at the furthest checkpoint anyone reached.
- **Chapter 1: keys and doors are shared**, and a player who joins later (also after a crash) gets everything that was done before.
- **Pullable objects** no longer spin wildly on the other player's screen.
- **Speedrun mode** (Chapter 1 settings): only what a run needs is shared, best fps. Switches you change afterwards stay as you set them.
- **Automatic updates:** from this version on the launcher updates itself when it starts (Launcher settings → Automatic updates). Works on Linux / Steam Deck too.
- **Crash logs are kept:** the last game's log is saved as `UE4SS_previous.log`, and "Report a problem" adds it and the game's crash report to the zip - send it to us after a crash.
- Chat: the text you type is readable now. The launcher window can be resized.

### 1.5.6
Small Chapter 1 update.
- **Speedrun mode (Chapter 1):** a new switch at the top of the Chapter 1 settings. Only what a run needs is shared
  (doors/switches/puzzles, inventory and keys, GrabPack hands, checkpoints); picked-up items, pullable objects,
  friends' areas, monsters, harder enemies, footsteps and solid friends are off, performance mode is on.
- **Chapter 1 checkpoints are shared again:** the furthest checkpoint anyone reached is saved in every game
  (forward only), so "Load Game" or a respawn puts you at your friend's checkpoint.
- **Chapter 1 keys are shared** (Giftshop key, Simon room key, security...): a key one player picks up is in
  everyone's inventory, a key used up is gone for everyone, and dying/loading never takes a team key away.
- **Chapter 1 doors open for everyone again** - opened by hand, key or code.
- Launcher window can be resized and maximized and remembers its size.

### 1.5.5
Merge of 1.5.0 (Chapters 3-5, Nucleus Co-op) with the new chat and message UI.
- **Experimental Chapters 3-5** and **several games at once** (Nucleus Co-op / split screen) - see Settings above.
- **Messages in boxes** at the left edge instead of the yellow text at the top; **status panel** at the top right (F11)
  with deaths per player and checkpoint split times.
- **Chat menu (Y):** 1-8 quick messages or type your own text; chat commands (`/help`). Friends nod or cheer on
  quick messages.
- **Friends are solid** from every side (you can stand on their head), their flying red hand is no longer mirrored.
- Chapter 2: **shoot your hand at a friend** to pull yourself to them.
- **Spectator camera:** after dying you watch a friend until you respawn.
- Friends see when you **watch a cutscene**; a tape in the VHS recorder plays for everyone standing there.
- New switches: **Performance mode**, **Harder enemies**, **Shared monsters (experimental)**.
- Keys apply to every chapter; status moved from F10 to **F11** (F10 is the console).
- Launcher: updates itself, figure preview, "Played with" names, problem report zip on the desktop,
  `--play` command line.

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
