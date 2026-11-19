# PoppyCoop Launcher 3

Own launcher (replaces the patched Launcher 2.0). Plain Win32 + GDI, one exe for Windows and Linux (Proton/Wine).

- Chapter setup only when a chapter is opened (no Chapter 1 folder needed to play Chapter 2).
- Per-chapter settings: keys (written to `keybinds.txt`) and sync switches (written to `config.txt`).
- Same settings file as Launcher 2 (`%APPDATA%\PoppyCoop\launcher.ini`), so name, colour, codes and game
  folders are kept; same install layout, `poppycoop://join/CODE` invite links, relay check.

Build (Linux, mingw-w64):

    python3 extract_res.py <original PoppyCoopLauncher 2.0 exe>   # once: UE4SS + loader + PoppyCoopNet
    ./build.sh                                                     # -> build/PoppyCoopLauncher.exe

The mod scripts and version come from `../mod-scripts`. Test mode: `POPPYCOOP_LAUNCHER_TEST=1` makes the
launcher replay `launcher_test.txt` next to the exe (`click X Y`, `key VK`, `type TEXT`).
