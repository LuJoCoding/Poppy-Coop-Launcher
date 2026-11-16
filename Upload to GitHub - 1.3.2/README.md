# Poppy Playtime Co-op (PoppyCoop)

An unofficial online co-op mod for **Poppy Playtime Chapter 1** and **Chapter 2 (beta)** on PC (Steam).
It's free to play, with no account needed. You just need the launcher.

> Fan-made. Not affiliated with or endorsed by Mob Entertainment.

## Download

Download the latest **`PoppyCoop_Launcher_x.x.x_CH2.zip`** from this repository (or from Releases), unzip it,
and run **`PoppyCoopLauncher.exe`**.

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
| **F6** | Teleport to your friend (if someone is stuck or far behind) |
| **F7** | Buddy figure that follows you (solo testing / clips) |
| **O / P** | Record your movement / replay it as a second player (trailer clips) |
| **F10** | Console. Type `coop_status` to see your room and who's connected |

F8 and F9 are intentionally left free for other mods.

You can change these keys in `ue4ss/Mods/PoppyCoop/keybinds.txt` (created the first time you play): change a key, save, restart the game. Key names are UE4SS names such as `F6`, `G`, `NUM_ONE`, `HOME`.

## What's shared

**Chapter 1:** players (position, animations, GrabPack hands), doors, buttons, power, puzzles, picked-up items,
inventory, checkpoints, deaths and which parts of the factory are loaded.

**Chapter 2 (beta):** full player figures with GrabPack and animations; launched hands with cable; the green hand
(if one player has it, everyone gets it); doors, floor hatches, levers, crane handles, vents, spider webs,
wooden walls, cut-outs and carts; puzzle pieces (furnace doors, gears, molds, paint cartridges, garage levers);
power, switches, keys, items and checkpoints. Some minigames and chases are not shared yet.

## Troubleshooting

- **Can't see anyone:** press F10 and type `coop_status`.
  - `helper=down`: `PoppyCoopNet.exe` is blocked or was removed by an antivirus. Restore it, allow it, and press PLAY again.
  - Different room: check that the code matches exactly. Copy and paste it instead of typing it.
- **"Servers unreachable":** the free servers have a daily limit. It resets at 01:00 Irish time.
- **Uninstall:** click *Uninstall* in the launcher. The game goes back to normal.

## For developers

- The mod is Lua for UE4SS 3.0.1 (`ue4ss/Mods/PoppyCoop/Scripts`). The launcher embeds these scripts and installs them.
- Developer tools are **off** for players. Turn them on by creating these files in `ue4ss/Mods/PoppyCoop/`:
  - `dev_exec_on.txt`: deep dumps (`dump_now.txt`) and running Lua from `exec_now.txt`.
  - `perf_on.txt`: performance report every 15 s (`perf_<name>.txt`).
  - `trace_on.txt`: log of every hooked call (slow).
- Rule of thumb: no engine errors in normal play. Each error leaks memory in UE4SS 3.0.1 and eventually crashes the game.

## Changelog

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
