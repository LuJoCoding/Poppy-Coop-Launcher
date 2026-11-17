# Poppy Playtime Co-op (PoppyCoop)

An unofficial online co-op mod for **Poppy Playtime Chapter 1** and **Chapter 2 (beta)** on PC (Steam).
It's free to play, with no account needed. You just need the launcher.

> Fan-made. Not affiliated with or endorsed by Mob Entertainment.

## Download

Download the latest **[`PoppyCoop_Launcher_1.3.6.zip`](Upload%20to%20GitHub%20-%201.3.6/PoppyCoop_Launcher_1.3.6.zip)**
(folder `Upload to GitHub - 1.3.6`, or from Releases), unzip it, and run **`PoppyCoopLauncher.exe`**.

Windows may show "Windows protected your PC" because the launcher isn't signed:
click **More info → Run anyway**.

## How to play

1. On first start, pick your game folder, a name and a colour. The launcher installs the mod for you.
2. Pick **Chapter 1** or **Chapter 2** on the left.
3. One player presses **Create Game** and sends the room code. The others press **Join Game** and paste it.
   Or everyone presses **Quick Play** to join the public lobby.
4. In the game, everyone loads the **same checkpoint** (Play → Load Game).
5. If Windows Firewall asks about `PoppyCoopNet.exe`, click **Allow**.

Everyone needs the **same launcher version**, or the mods won't match.

### Keys

| Key | What it does |
| --- | --- |
| **F6** | Teleport to another player (if someone is stuck or far behind; with 3+ players each press goes to the next one) |
| **F7** | Buddy figure that follows you (solo testing / clips) |
| **O / P** | Record your movement / replay it as a second player (trailer clips) |
| **F10** | Console. Type `coop_status` to see your room and who's connected |

F8 and F9 are intentionally left free for other mods.

You can change these keys in `ue4ss/Mods/PoppyCoop/keybinds.txt` (created the first time you play): change a key, save, restart the game. Key names are UE4SS names such as `F6`, `G`, `NUM_ONE`, `HOME`.

## What's shared

**Chapter 1:** player figures - a faceless mannequin with a round head in your colour (walk, run, crouch, jump,
lying down when dead) carrying the real Chapter 1 GrabPack (shown once that player has it); launched hands are
the real game hands with the same angle and grab state (holding on = closed hand) and a black cable; doors
(real swing), buttons, power, code and hand pads, puzzles, picked-up items, inventory, checkpoints, deaths;
boxes, toy blocks, chairs and other physics props (while moved and where they were left); the pull platforms
in the factory; which parts of the factory are loaded.

**Chapter 2 (beta):** full player figures with GrabPack and animations; launched hands with cable; the green hand
(if one player has it, everyone gets it); doors, floor hatches, levers, crane handles, vents, spider webs,
wooden walls, cut-outs and carts; puzzle pieces (furnace doors, gears, molds, paint cartridges, garage levers);
power, switches, keys, items and checkpoints. Some minigames and chases are not shared yet.

**2, 3 or more players** can share a room. Checkpoints only move forward: a player who is behind can't reset
everyone else's "Load Game" position.

Rooms are public, so the mod only accepts the actions it sends itself from other players (power, switches,
puzzle steps, inventory, item pickups, moving parts with sane values). Anything else is dropped.

## Troubleshooting

- **Can't see anyone:** press F10 and type `coop_status`.
  - `helper=down`: `PoppyCoopNet.exe` is blocked or was removed by an antivirus. Restore it, allow it, and press PLAY again.
  - Different room: check that the code matches exactly. Copy and paste it instead of typing it.
  - Different chapter: rooms are per chapter, so everyone must pick the same chapter in the launcher.
- **"Servers unreachable":** the free servers have a daily limit. It resets at 01:00 Irish time.
- **Uninstall:** click *Uninstall* in the launcher. The game goes back to normal.

## For developers

- The mod is Lua for UE4SS 3.0.1 (`ue4ss/Mods/PoppyCoop/Scripts`). The launcher embeds these scripts and installs them.
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
