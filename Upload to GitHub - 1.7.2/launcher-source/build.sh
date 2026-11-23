#!/bin/bash
# build.sh [mod Scripts dir] : builds PoppyCoopLauncher.exe (Launcher 3) with the mod scripts embedded
set -e
cd "$(dirname "$0")"
SCRIPTS=${1:-../../mod/Scripts}
VER=$(grep -oP 'local VERSION = "\K[0-9.]+' "$SCRIPTS/main.lua")
[ -n "$VER" ] || { echo "VERSION not found in $SCRIPTS/main.lua"; exit 1; }
mkdir -p build
python3 ../../tools/gen_news.py ../../release/notes build/news_data.h     # "What's new" page: every release's notes
cat > build/launcher.rc <<RC
1 ICON "res/app.ico"
1 24 "manifest.xml"
101 10 "res/10_101.bin"
102 10 "res/10_102.bin"
103 10 "res/10_103.bin"
104 10 "res/10_104.bin"
105 10 "res/10_105.bin"
106 10 "res/10_106.bin"
107 10 "res/10_107.bin"
108 10 "res/10_108.bin"
109 10 "res/10_109.bin"
110 10 "$SCRIPTS/main.lua"
111 10 "$SCRIPTS/coop_world.lua"
112 10 "res/10_112.bin"
113 10 "res/10_113.bin"
114 10 "$SCRIPTS/coop_extra.lua"
RC
x86_64-w64-mingw32-windres -I. build/launcher.rc -O coff -o build/launcher.res
x86_64-w64-mingw32-g++ -std=c++17 -O2 -municode -mwindows -static -s -Wall -Wno-unused-function \
  -DMOD_VERSION="L\"$VER\"" main.cpp build/launcher.res -o build/PoppyCoopLauncher.exe \
  -lmsimg32 -liphlpapi -lws2_32 -lole32 -luuid -lshell32 -lwinhttp -lversion -lgdi32 -lcomctl32 -luser32 -ladvapi32
ls -la build/PoppyCoopLauncher.exe
echo "built Launcher 3 with mod v$VER"
