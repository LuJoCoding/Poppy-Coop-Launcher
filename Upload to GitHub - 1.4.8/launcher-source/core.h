// PoppyCoop Launcher 3 - system side: settings, chapters, Steam lookup, install, config, game process.
#pragma once
#ifndef UNICODE
#define UNICODE
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <iphlpapi.h>
#include <icmpapi.h>
#include <winhttp.h>
#include <string>
#include <vector>
#include <unordered_map>
#include <cwctype>
#include <random>
#include <cmath>

#ifndef MOD_VERSION
#define MOD_VERSION L"0.0.0"
#endif
#define LAUNCHER_VERSION L"3.0"

static const wchar_t* RELAY_URL = L"wss://poppycoop-relay.poppycoopnet.workers.dev";

// ------------------------------------------------------------------ resources (see launcher.rc)
enum {
    RES_DWMAPI = 101, RES_UE4SS = 102, RES_UE4SS_INI = 103, RES_MODS_TXT = 104, RES_CONSOLE = 105,
    RES_KEYBINDS = 106, RES_JSB = 107, RES_UEHELPERS = 108, RES_NET = 109, RES_MAIN = 110, RES_WORLD = 111,
    RES_COLORS = 112, RES_ENABLED = 113, RES_EXTRA = 114
};

static bool load_res(int id, const void** data, DWORD* size) {
    HRSRC r = FindResourceW(nullptr, MAKEINTRESOURCEW(id), MAKEINTRESOURCEW(10));
    if (!r) return false;
    HGLOBAL g = LoadResource(nullptr, r);
    if (!g) return false;
    *data = LockResource(g);
    *size = SizeofResource(nullptr, r);
    return *data != nullptr || *size == 0;
}

// ------------------------------------------------------------------ small helpers
static std::wstring trim(const std::wstring& s) {
    size_t a = s.find_first_not_of(L" \t\r\n"), b = s.find_last_not_of(L" \t\r\n");
    return a == std::wstring::npos ? L"" : s.substr(a, b - a + 1);
}
static std::wstring lower(std::wstring s) { for (auto& c : s) c = (wchar_t)towlower(c); return s; }
static std::wstring upper(std::wstring s) { for (auto& c : s) c = (wchar_t)towupper(c); return s; }
static bool file_exists(const std::wstring& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}
static bool dir_exists(const std::wstring& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}
static std::wstring parent(const std::wstring& p) {
    size_t i = p.find_last_of(L"\\/");
    return i == std::wstring::npos ? L"" : p.substr(0, i);
}
static std::wstring strip_slash(std::wstring p) {
    while (p.size() > 3 && (p.back() == L'\\' || p.back() == L'/')) p.pop_back();
    return p;
}
static std::string utf8(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}
static std::wstring wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}
static bool read_file(const std::wstring& p, std::string& out) {
    HANDLE h = CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz; GetFileSizeEx(h, &sz);
    out.assign((size_t)sz.QuadPart, 0);
    DWORD got = 0;
    bool ok = sz.QuadPart == 0 || ReadFile(h, &out[0], (DWORD)sz.QuadPart, &got, nullptr);
    CloseHandle(h);
    return ok && got == (DWORD)sz.QuadPart;
}
// write only when the content differs (a game that has the file open can still keep running)
static bool write_file(const std::wstring& p, const void* data, size_t n) {
    std::string cur;
    if (read_file(p, cur) && cur.size() == n && (n == 0 || memcmp(cur.data(), data, n) == 0)) return true;
    SHCreateDirectoryExW(nullptr, parent(p).c_str(), nullptr);
    std::wstring tmp = p + L".new";
    HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD put = 0;
    bool ok = n == 0 || WriteFile(h, data, (DWORD)n, &put, nullptr);
    CloseHandle(h);
    if (!ok || put != n) { DeleteFileW(tmp.c_str()); return false; }
    if (!MoveFileExW(tmp.c_str(), p.c_str(), MOVEFILE_REPLACE_EXISTING)) { DeleteFileW(tmp.c_str()); return false; }
    return true;
}
static bool write_text(const std::wstring& p, const std::wstring& text) {
    std::string s = utf8(text);
    return write_file(p, s.data(), s.size());
}
static bool delete_tree(const std::wstring& dir) {
    if (!dir_exists(dir)) return true;
    std::wstring from = dir + L'\0';   // double-null terminated
    SHFILEOPSTRUCTW op = {};
    op.wFunc = FO_DELETE;
    op.pFrom = from.c_str();
    op.fFlags = FOF_NO_UI;
    return SHFileOperationW(&op) == 0;
}

// ------------------------------------------------------------------ settings (launcher.ini, same file as Launcher 2)
static std::wstring g_ini;
static void ini_init() {
    wchar_t buf[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, buf))) {
        std::wstring d = std::wstring(buf) + L"\\PoppyCoop";
        CreateDirectoryW(d.c_str(), nullptr);
        g_ini = d + L"\\launcher.ini";
    } else {
        g_ini = L"PoppyCoopLauncher.ini";
    }
}
static std::wstring ini_get(const wchar_t* sec, const wchar_t* key, const wchar_t* def = L"") {
    wchar_t buf[2048];
    GetPrivateProfileStringW(sec, key, def, buf, 2048, g_ini.c_str());
    return buf;
}
static void ini_set(const wchar_t* sec, const wchar_t* key, const std::wstring& v) {
    WritePrivateProfileStringW(sec, key, v.c_str(), g_ini.c_str());
}

// ------------------------------------------------------------------ chapters
enum class DirState { None, NotFound, Ok, OkUnknownVersion, OldVersion };

struct KeyBind { const wchar_t* id; const wchar_t* label; const wchar_t* def; std::wstring value; };
struct SyncOpt { const wchar_t* id; const wchar_t* label; const wchar_t* hint; int chapters; bool value; };

struct Chapter {
    int num;
    const wchar_t* title;
    const wchar_t* badge;          // READY / BETA / nullptr = coming later
    const wchar_t* blurb;
    const wchar_t* exe;            // in the WindowsNoEditor folder
    const wchar_t* proj;           // project folder
    const wchar_t* shipping;       // process name
    const wchar_t* steam_folder;   // steamapps\common\<this>
    const wchar_t* appid;
    const wchar_t* ini_key;        // GameDir / GameDir2 (kept from Launcher 2)
    bool needs_ue5;                // Chapter 1: only v1.3 (Unreal Engine 5) is supported
    std::wstring dir;              // WindowsNoEditor folder
    DirState state = DirState::None;
    int detect = -1;               // Found as int: -1 = not searched (folder came from launcher.ini)
    std::wstring found_where;      // where the automatic search found it
    std::vector<KeyBind> keys;
    std::vector<SyncOpt> sync;
};

static std::vector<KeyBind> default_keys() {
    return {
        { L"teleport", L"Teleport to a friend", L"F6", L"" },
        { L"buddy", L"Show / hide buddy figure", L"F7", L"" },
        { L"record", L"Record your movement", L"O", L"" },
        { L"play", L"Replay recorded movement", L"P", L"" },
        { L"ping", L"Ping a spot for everyone", L"T", L"" },
        { L"status", L"Show fps / ping / players", L"F10", L"" },
        { L"chat", L"Quick chat (press again: next)", L"Y", L"" },
    };
}
// chapters: bit 1 = Chapter 1, bit 2 = Chapter 2
static std::vector<SyncOpt> default_sync() {
    return {
        { L"sync_activations", L"Doors, switches & puzzles", L"Doors, power, levers, puzzle parts", 3, true },
        { L"sync_destroy", L"Picked-up items", L"Gone for everyone once picked up", 3, true },
        { L"sync_inventory", L"Shared inventory", L"One team inventory for keys & items", 3, true },
        { L"sync_hands", L"Shared GrabPack hands", L"A new hand goes to everyone", 3, true },
        { L"sync_physics", L"Pullable objects", L"Boxes, barrels, chairs move for all", 3, true },
        { L"bg_levels", L"Keep friends' areas loaded", L"Off = safer: their rooms' enemies can't reach you", 3, false },
        { L"sync_minigames", L"Minigames", L"Musical Memory, Whack-a-Wuggy", 2, true },
        { L"auto_follow", L"Follow out of chases", L"Friend escaped a chase you're in: go to them", 2, true },
        { L"respawn_at_friend", L"Respawn at a friend", L"After dying you are teleported to a friend", 3, false },
        { L"boost", L"Stand on friends", L"Jump on a friend's head to reach higher spots", 2, true },
        { L"fps60", L"Limit to 60 fps", L"Smoother on weaker PCs, less heat", 3, false },
        { L"popups", L"On-screen messages", L"Joined / died / teleport messages", 3, true },
    };
}

static std::vector<Chapter> g_ch;

static void chapters_init() {
    g_ch.push_back({ 1, L"A Tight Squeeze", L"READY",
        L"Explore the abandoned toy factory together. Doors, power, puzzles, items, pullable objects and loaded areas are shared with everyone in your room.",
        L"Poppy_Playtime.exe", L"Poppy_Playtime", L"Poppy_Playtime-Win64-Shipping.exe", L"Poppy Playtime", L"1721470", L"GameDir", true });
    g_ch.push_back({ 2, L"Fly in a Web", L"BETA",
        L"Explore the Game Station together. Doors, keys and items, power, checkpoints, pullable objects and loaded areas are shared - and Musical Memory and Whack-a-Wuggy are played together.",
        L"Playtime_Prototype4.exe", L"Playtime_Prototype4", L"Playtime_Prototype4-Win64-Shipping.exe", L"Poppy Playtime Chapter 2", L"1817490", L"GameDir2", false });
    g_ch.push_back({ 3, L"Deep Sleep", nullptr, L"", L"", L"", L"", L"", L"", L"", false });
    g_ch.push_back({ 4, L"Safe Haven", nullptr, L"", L"", L"", L"", L"", L"", L"", false });
    g_ch.push_back({ 5, L"Broken Things", nullptr, L"", L"", L"", L"", L"", L"", L"", false });
}

static bool playable(const Chapter& c) { return c.badge != nullptr; }
static std::wstring sec_name(const Chapter& c) { return L"Chapter" + std::to_wstring(c.num); }
static std::wstring bin_dir(const Chapter& c) { return c.dir + L"\\" + c.proj + L"\\Binaries\\Win64"; }
static std::wstring mod_dir(const Chapter& c) { return bin_dir(c) + L"\\ue4ss\\Mods\\PoppyCoop"; }

// ProductVersion of the shipping exe ("4.27..." = Unreal 4, "5.x" = Unreal 5); empty if unreadable
static std::wstring product_version(const std::wstring& exe) {
    DWORD h = 0, n = GetFileVersionInfoSizeW(exe.c_str(), &h);
    if (!n) return L"";
    std::vector<BYTE> buf(n);
    if (!GetFileVersionInfoW(exe.c_str(), 0, n, buf.data())) return L"";
    struct LangCp { WORD lang, cp; } *tr = nullptr;
    UINT len = 0;
    if (!VerQueryValueW(buf.data(), L"\\VarFileInfo\\Translation", (void**)&tr, &len) || len < sizeof(LangCp)) return L"";
    wchar_t key[128];
    swprintf(key, 128, L"\\StringFileInfo\\%04x%04x\\ProductVersion", tr->lang, tr->cp);
    wchar_t* val = nullptr;
    if (!VerQueryValueW(buf.data(), key, (void**)&val, &len) || !val) return L"";
    return val;
}

// Accepts the WindowsNoEditor folder, the folder above it or anything inside Binaries\Win64.
static std::wstring normalize_dir(const Chapter& c, std::wstring p) {
    p = strip_slash(p);
    if (p.empty()) return p;
    if (file_exists(p + L"\\" + c.exe)) return p;
    if (file_exists(p + L"\\WindowsNoEditor\\" + c.exe)) return p + L"\\WindowsNoEditor";
    std::wstring up = p;
    for (int i = 0; i < 4 && !up.empty(); i++) {
        up = parent(up);
        if (!up.empty() && file_exists(up + L"\\" + c.exe)) return up;
    }
    return p;
}

static DirState check_dir(const Chapter& c, const std::wstring& dir) {
    if (dir.empty()) return DirState::None;
    if (!file_exists(dir + L"\\" + c.exe)) return DirState::NotFound;
    if (!c.needs_ue5) return DirState::Ok;
    std::wstring v = product_version(dir + L"\\" + c.proj + L"\\Binaries\\Win64\\" + c.shipping);
    if (v.empty()) return DirState::OkUnknownVersion;
    if (v[0] == L'4') return DirState::OldVersion;
    return DirState::Ok;
}

static bool dir_usable(DirState s) { return s == DirState::Ok || s == DirState::OkUnknownVersion; }

// ------------------------------------------------------------------ automatic game detection
// Linux path -> the Wine/Proton drive Z: path ("/home/x" -> "Z:\home\x")
static std::wstring unix_to_z(const std::wstring& p) {
    if (p.empty() || p[0] != L'/') return p;
    std::wstring r = L"Z:" + p;
    for (auto& ch : r) if (ch == L'/') ch = L'\\';
    return strip_slash(r);
}
static std::wstring env(const wchar_t* name) {
    wchar_t buf[2048];
    DWORD n = GetEnvironmentVariableW(name, buf, 2048);
    return n && n < 2048 ? std::wstring(buf, n) : L"";
}
static void add_unique(std::vector<std::wstring>& v, std::wstring p) {
    p = strip_slash(p);
    if (p.empty()) return;
    for (auto& x : v) if (lower(x) == lower(p)) return;
    v.push_back(p);
}
// "path" entries of steamapps\libraryfolders.vdf (Windows or Linux paths)
static void add_vdf_libraries(const std::wstring& root, std::vector<std::wstring>& libs) {
    std::string vdf;
    if (!read_file(root + L"\\steamapps\\libraryfolders.vdf", vdf)) return;
    size_t pos = 0;
    while ((pos = vdf.find("\"path\"", pos)) != std::string::npos) {
        size_t a = vdf.find('"', pos + 6);
        size_t b = a == std::string::npos ? a : vdf.find('"', a + 1);
        if (b == std::string::npos) break;
        std::string v = vdf.substr(a + 1, b - a - 1), un;
        for (size_t i = 0; i < v.size(); i++) { if (v[i] == '\\' && i + 1 < v.size() && v[i + 1] == '\\') i++; un += v[i]; }
        std::wstring w = wide(un);
        for (auto& ch : w) if (ch == L'/' && !w.empty() && w[0] != L'/') ch = L'\\';
        add_unique(libs, unix_to_z(w));
        pos = b + 1;
    }
}
// Steam install folders: the registry (Windows), and under Proton/Wine the real Linux Steam of the player
static std::vector<std::wstring> steam_roots() {
    std::vector<std::wstring> roots;
    wchar_t buf[MAX_PATH]; DWORD sz = sizeof(buf);
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", 0, KEY_READ, &k) == ERROR_SUCCESS) {
        if (RegQueryValueExW(k, L"SteamPath", nullptr, nullptr, (BYTE*)buf, &sz) == ERROR_SUCCESS) {
            std::wstring sp = buf;
            for (auto& ch : sp) if (ch == L'/') ch = L'\\';
            add_unique(roots, sp);
        }
        RegCloseKey(k);
    }
    add_unique(roots, L"C:\\Program Files (x86)\\Steam");
    add_unique(roots, unix_to_z(env(L"STEAM_COMPAT_CLIENT_INSTALL_PATH")));   // set by Proton
    std::wstring home = env(L"WINEHOMEDIR");                                    // "\??\Z:\home\name" under Wine
    if (home.rfind(L"\\??\\", 0) == 0) home = home.substr(4);
    if (!home.empty()) {
        for (const wchar_t* rel : { L"\\.steam\\steam", L"\\.local\\share\\Steam", L"\\snap\\steam\\common\\.local\\share\\Steam",
                                    L"\\.var\\app\\com.valvesoftware.Steam\\.local\\share\\Steam" })
            add_unique(roots, home + rel);
    }
    std::vector<std::wstring> out;
    for (auto& r : roots) if (dir_exists(r)) add_unique(out, r);
    return out;
}

enum class Found { Nothing, Ok, OldVersion };
struct Detect { Found what = Found::Nothing; std::wstring dir, where; };

// Places a chapter can be in: every Steam library (steamapps\common\<game>) and Steam's download folder,
// where a version downloaded with the Steam console (download_depot, i.e. a downpatch) always ends up:
// steamapps\content\app_<app>\depot_<app+1> (Windows) / ubuntu12_32\steamapps\content\... (Linux Steam).
static Detect detect_game(const Chapter& c) {
    Detect best;
    if (env(L"POPPYCOOP_LAUNCHER_TEST") == L"1" && env(L"POPPYCOOP_LAUNCHER_NODETECT") == L"1") return best;   // test: "not found" page
    std::wstring depot = L"depot_" + std::to_wstring(_wtoi(c.appid) + 1);
    std::vector<std::pair<std::wstring, std::wstring>> cands;   // folder, where
    std::vector<std::wstring> roots = steam_roots(), libs;
    for (auto& r : roots) { add_unique(libs, r); add_vdf_libraries(r, libs); }
    for (auto& r : roots) {
        cands.push_back({ r + L"\\steamapps\\content\\app_" + c.appid + L"\\" + depot, L"Steam download folder (downpatch)" });
        cands.push_back({ r + L"\\ubuntu12_32\\steamapps\\content\\app_" + c.appid + L"\\" + depot, L"Steam download folder (downpatch)" });
    }
    for (auto& l : libs) {
        cands.push_back({ l + L"\\steamapps\\common\\" + c.steam_folder, L"Steam library" });
        cands.push_back({ l + L"\\steamapps\\content\\app_" + c.appid + L"\\" + depot, L"Steam download folder (downpatch)" });
    }
    for (auto& cand : cands) {
        if (!dir_exists(cand.first)) continue;
        std::wstring d = normalize_dir(c, cand.first);
        DirState st = check_dir(c, d);
        if (dir_usable(st)) return { Found::Ok, d, cand.second };
        if (st == DirState::OldVersion && best.what == Found::Nothing) best = { Found::OldVersion, d, cand.second };
    }
    return best;
}

static void chapter_load(Chapter& c) {
    c.keys = default_keys();
    c.sync = default_sync();
    if (!playable(c)) return;
    c.dir = ini_get(L"Launcher", c.ini_key);
    if (c.dir.empty() || !dir_usable(check_dir(c, c.dir))) {
        Detect d = detect_game(c);
        c.detect = (int)d.what;
        if (d.what != Found::Nothing) { c.dir = d.dir; c.found_where = d.where; }
    }
    c.state = check_dir(c, c.dir);
    std::wstring s = sec_name(c);
    // keys: launcher.ini first, else what the mod already has in keybinds.txt
    std::string kb;
    bool have_file = !c.dir.empty() && read_file(mod_dir(c) + L"\\keybinds.txt", kb);
    for (auto& k : c.keys) {
        std::wstring v = ini_get(s.c_str(), (std::wstring(L"key_") + k.id).c_str());
        if (v.empty() && have_file) {
            std::string id = utf8(k.id) + "=";
            size_t p = kb.find("\n" + id);
            if (p == std::string::npos && kb.compare(0, id.size(), id) == 0) p = 0; else if (p != std::string::npos) p++;
            if (p != std::string::npos) {
                size_t e = kb.find_first_of("\r\n", p);
                v = trim(wide(kb.substr(p + id.size(), e == std::string::npos ? std::string::npos : e - p - id.size())));
            }
        }
        k.value = v.empty() ? k.def : upper(v);
    }
    for (auto& o : c.sync) {
        std::wstring v = ini_get(s.c_str(), o.id);
        if (!v.empty()) o.value = v != L"0" && lower(v) != L"false";
    }
}

static void chapter_save_settings(const Chapter& c) {
    std::wstring s = sec_name(c);
    for (auto& k : c.keys) ini_set(s.c_str(), (std::wstring(L"key_") + k.id).c_str(), k.value);
    for (auto& o : c.sync) ini_set(s.c_str(), o.id, o.value ? L"1" : L"0");
}

// ------------------------------------------------------------------ install state
static std::wstring installed_version(const Chapter& c) {
    std::string v;
    if (c.dir.empty() || !read_file(mod_dir(c) + L"\\version.txt", v)) return L"";
    if (!file_exists(bin_dir(c) + L"\\dwmapi.dll") || !file_exists(bin_dir(c) + L"\\ue4ss\\UE4SS.dll")
        || !file_exists(mod_dir(c) + L"\\Scripts\\main.lua")) return L"";
    return trim(wide(v));
}
static bool up_to_date(const Chapter& c) { return installed_version(c) == MOD_VERSION; }

struct InstallItem { std::wstring rel; int res; bool keep_existing; };
static std::vector<InstallItem> install_items() {
    return {
        { L"ue4ss\\UE4SS.dll", RES_UE4SS, false },
        { L"dwmapi.dll", RES_DWMAPI, false },
        { L"ue4ss\\UE4SS-settings.ini", RES_UE4SS_INI, false },
        { L"ue4ss\\Mods\\mods.txt", RES_MODS_TXT, true },            // other mods the player set up stay as they are
        { L"ue4ss\\Mods\\ConsoleEnablerMod\\Scripts\\main.lua", RES_CONSOLE, true },
        { L"ue4ss\\Mods\\Keybinds\\Scripts\\main.lua", RES_KEYBINDS, true },
        { L"ue4ss\\Mods\\shared\\jsbProfiler\\jsbProfi.lua", RES_JSB, true },
        { L"ue4ss\\Mods\\shared\\UEHelpers\\UEHelpers.lua", RES_UEHELPERS, true },
        { L"ue4ss\\Mods\\PoppyCoop\\PoppyCoopNet.exe", RES_NET, false },
        { L"ue4ss\\Mods\\PoppyCoop\\Scripts\\main.lua", RES_MAIN, false },
        { L"ue4ss\\Mods\\PoppyCoop\\Scripts\\coop_world.lua", RES_WORLD, false },
        { L"ue4ss\\Mods\\PoppyCoop\\Scripts\\coop_extra.lua", RES_EXTRA, false },
        { L"ue4ss\\Mods\\PoppyCoop\\colors.txt", RES_COLORS, false },
        { L"ue4ss\\Mods\\PoppyCoop\\enabled.txt", RES_ENABLED, false },
    };
}

// ------------------------------------------------------------------ mod config files
// the server the game connects to (chosen on the Servers page)
struct Profile {
    std::wstring name, color, code, join_code; int tab = 0;
    std::wstring srv_mode = L"join", srv_addr = RELAY_URL; int srv_port = 27777;   // mode=host: this PC is the server
};

static std::wstring clean_name(const std::wstring& n) {
    std::wstring r;
    for (wchar_t ch : n) {
        if (iswalnum(ch) && ch < 128) r += ch;
        else if (ch == L'_' || ch == L'-') r += ch;
        else if (ch == L' ') r += L'_';
        if (r.size() >= 24) break;
    }
    return r;
}

static std::wstring room_for(const Profile& p) {
    if (p.tab == 1) return lower(p.code);
    if (p.tab == 2) return lower(p.join_code);
    return L"public";
}

static bool write_mod_settings(const Chapter& c, const Profile& p) {
    std::wstring m = mod_dir(c);
    std::wstring cfg = L"# written by PoppyCoop Launcher " LAUNCHER_VERSION L"\n";
    std::wstring nm = clean_name(p.name);
    if (nm.empty()) nm = L"Player";
    cfg += L"mode=" + p.srv_mode + L"\nname=" + nm + L"\nhost_ip=" + (p.srv_mode == L"host" ? L"127.0.0.1" : p.srv_addr)
         + L"\nport=" + std::to_wstring(p.srv_port) + L"\n";
    cfg += L"room=" + room_for(p) + L"\ncolor=" + p.color + L"\nautostart_helper=true\nsend_hz=20\n";
    for (auto& o : c.sync) if (o.chapters & (1 << (c.num - 1))) cfg += std::wstring(o.id) + L"=" + (o.value ? L"true" : L"false") + L"\n";
    std::wstring kb = L"# PoppyCoop keys - set in the launcher (chapter settings). F8/F9 are left free for other mods.\n";
    for (auto& k : c.keys) kb += std::wstring(k.id) + L"=" + k.value + L"\n";
    bool ok = write_text(m + L"\\config.txt", cfg);
    ok = write_text(m + L"\\keybinds.txt", kb) && ok;
    return ok;
}

// ------------------------------------------------------------------ game process
static bool process_running(const wchar_t* exe) {
    if (!exe || !*exe) return false;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W pe = { sizeof(pe) };
    bool found = false;
    for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe))
        if (_wcsicmp(pe.szExeFile, exe) == 0) { found = true; break; }
    CloseHandle(snap);
    return found;
}
static bool game_running(const Chapter& c) { return playable(c) && process_running(c.shipping); }

static bool via_steam(const Chapter& c) { return lower(c.dir).find(L"\\steamapps\\common\\") != std::wstring::npos; }

static bool launch_game(const Chapter& c) {
    if (via_steam(c)) {
        std::wstring url = std::wstring(L"steam://rungameid/") + c.appid;
        return (INT_PTR)ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL) > 32;
    }
    std::wstring exe = c.dir + L"\\" + c.exe;
    std::wstring cmd = L"\"" + exe + L"\"";
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, c.dir.c_str(), &si, &pi)) return false;
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return true;
}

// ------------------------------------------------------------------ servers + connection quality
enum class SrvKind { Relay, Direct, Host };
struct Server { SrvKind kind; std::wstring name, addr; int port; bool builtin; };

// "wss://x/y" / "x.workers.dev" -> relay; "1.2.3.4" / "host:port" -> direct (UDP, a friend hosting)
static bool parse_server(const std::wstring& raw, Server& out) {
    std::wstring a = trim(raw);
    if (a.empty()) return false;
    std::wstring l = lower(a);
    if (l.rfind(L"wss://", 0) == 0 || l.rfind(L"ws://", 0) == 0 || l.find(L".workers.dev") != std::wstring::npos) {
        if (l.rfind(L"ws", 0) != 0) a = L"wss://" + a;
        if (a.size() < 9) return false;
        out.kind = SrvKind::Relay; out.addr = a; out.port = 27777; return true;
    }
    int port = 27777;
    size_t c = a.find_last_of(L':');
    if (c != std::wstring::npos && a.find(L':') == c) {          // host:port (not an IPv6 address)
        port = _wtoi(a.substr(c + 1).c_str());
        a = a.substr(0, c);
        if (port <= 0 || port > 65535) return false;
    }
    for (wchar_t ch : a) if (!(iswalnum(ch) || ch == L'.' || ch == L'-' || ch == L':')) return false;
    out.kind = SrvKind::Direct; out.addr = a; out.port = port; return true;
}

struct Probe {
    int ms = -1, jitter = 0, loss = 0;   // average round trip, its spread, % of probes that failed
    std::wstring colo, note;             // Cloudflare datacenter / why it couldn't be measured
    bool done = false;
};

// ------------------------------------------------------------------ update check
// newest release tag on GitHub ("v1.4.3" -> "1.4.3"); empty when offline / on any error
#define RELEASES_HOST L"api.github.com"
#define RELEASES_PATH L"/repos/LuJoCoding/Poppy-Coop-Launcher/releases/latest"
#define RELEASES_PAGE L"https://github.com/LuJoCoding/Poppy-Coop-Launcher/releases/latest"
static std::wstring latest_release() {
    std::wstring tag;
    HINTERNET s = WinHttpOpen(L"PoppyCoopLauncher/" LAUNCHER_VERSION, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nullptr, nullptr, 0);
    if (!s) return tag;
    WinHttpSetTimeouts(s, 5000, 5000, 5000, 5000);
    HINTERNET c = WinHttpConnect(s, RELEASES_HOST, INTERNET_DEFAULT_HTTPS_PORT, 0);
    HINTERNET q = c ? WinHttpOpenRequest(c, L"GET", RELEASES_PATH, nullptr, nullptr, nullptr, WINHTTP_FLAG_SECURE) : nullptr;
    if (q && WinHttpSendRequest(q, L"Accept: application/vnd.github+json\r\n", (DWORD)-1L, nullptr, 0, 0, 0) && WinHttpReceiveResponse(q, nullptr)) {
        std::string body;
        char buf[4096];
        DWORD n = 0;
        while (body.size() < 256 * 1024 && WinHttpReadData(q, buf, sizeof buf, &n) && n > 0) body.append(buf, n);
        size_t k = body.find("\"tag_name\"");
        if (k != std::string::npos) {
            size_t a = body.find('"', body.find(':', k) + 1);
            size_t b = a == std::string::npos ? a : body.find('"', a + 1);
            if (a != std::string::npos && b != std::string::npos && b - a < 32) {
                std::string t = body.substr(a + 1, b - a - 1);
                if (!t.empty() && (t[0] == 'v' || t[0] == 'V')) t.erase(0, 1);
                bool okchars = !t.empty();
                for (char ch : t) if (!((ch >= '0' && ch <= '9') || ch == '.')) okchars = false;
                if (okchars) tag.assign(t.begin(), t.end());
            }
        }
    }
    if (q) WinHttpCloseHandle(q);
    if (c) WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    return tag;
}
// "1.4.10" > "1.4.9"
static bool version_newer(const std::wstring& a, const std::wstring& b) {
    size_t i = 0, j = 0;
    while (i < a.size() || j < b.size()) {
        long x = 0, y = 0;
        while (i < a.size() && a[i] != L'.') x = x * 10 + (a[i++] - L'0');
        while (j < b.size() && b[j] != L'.') y = y * 10 + (b[j++] - L'0');
        if (x != y) return x > y;
        i++; j++;
    }
    return false;
}

static Probe probe_relay(const std::wstring& url) {
    Probe r;
    std::wstring host = url.substr(url.find(L"://") + 3), path = L"/";
    size_t sl = host.find(L'/');
    if (sl != std::wstring::npos) { path = host.substr(sl); host = host.substr(0, sl); }
    bool secure = lower(url).rfind(L"wss", 0) == 0;
    HINTERNET s = WinHttpOpen(L"PoppyCoopLauncher/" LAUNCHER_VERSION, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nullptr, nullptr, 0);
    if (!s) { r.done = true; r.note = L"no network"; return r; }
    WinHttpSetTimeouts(s, 4000, 4000, 4000, 4000);
    HINTERNET c = WinHttpConnect(s, host.c_str(), secure ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT, 0);
    std::vector<int> times;
    int fails = 0;
    const int N = 6;                       // the first one sets up TLS and is not counted
    for (int i = 0; c && i < N; i++) {
        HINTERNET q = WinHttpOpenRequest(c, L"HEAD", path.c_str(), nullptr, nullptr, nullptr, secure ? WINHTTP_FLAG_SECURE : 0);
        if (!q) { fails++; continue; }
        ULONGLONG t0 = GetTickCount64();
        bool ok = WinHttpSendRequest(q, nullptr, 0, nullptr, 0, 0, 0) && WinHttpReceiveResponse(q, nullptr);
        int ms = (int)(GetTickCount64() - t0);
        if (ok) {
            if (i > 0) times.push_back(ms);
            if (r.colo.empty()) {
                wchar_t buf[128] = {}; DWORD sz = sizeof(buf);
                if (WinHttpQueryHeaders(q, WINHTTP_QUERY_CUSTOM, L"cf-ray", buf, &sz, WINHTTP_NO_HEADER_INDEX)) {
                    std::wstring ray = buf;
                    size_t d = ray.find_last_of(L'-');
                    if (d != std::wstring::npos) r.colo = ray.substr(d + 1);
                }
            }
        } else if (i > 0) fails++;
        else { WinHttpCloseHandle(q); fails = N - 1; break; }      // not even the first one: unreachable
        WinHttpCloseHandle(q);
        Sleep(120);
    }
    if (c) WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    if (!times.empty()) {
        double sum = 0; for (int t : times) sum += t;
        double avg = sum / times.size(), dev = 0;
        for (int t : times) dev += fabs(t - avg);
        r.ms = (int)(avg + 0.5); r.jitter = (int)(dev / times.size() + 0.5);
    }
    r.loss = fails * 100 / (N - 1);
    if (r.ms < 0) r.note = L"unreachable";
    r.done = true;
    return r;
}

// ICMP ping to a friend who hosts (the game itself uses UDP, which can't be tested without the game running)
static Probe probe_direct(const std::wstring& host) {
    Probe r;
    WSADATA wd; WSAStartup(MAKEWORD(2, 2), &wd);
    ADDRINFOW hints = {}, *res = nullptr;
    hints.ai_family = AF_INET;
    if (GetAddrInfoW(host.c_str(), nullptr, &hints, &res) != 0 || !res) { r.done = true; r.note = L"address not found"; return r; }
    IPAddr ip = ((sockaddr_in*)res->ai_addr)->sin_addr.s_addr;
    FreeAddrInfoW(res);
    HANDLE h = IcmpCreateFile();
    if (h == INVALID_HANDLE_VALUE) { r.done = true; r.note = L"can't measure"; return r; }
    char data[32] = "PoppyCoop";
    std::vector<BYTE> reply(sizeof(ICMP_ECHO_REPLY) + sizeof(data) + 64);
    std::vector<int> times;
    int fails = 0;
    for (int i = 0; i < 5; i++) {
        DWORD n = IcmpSendEcho(h, ip, data, sizeof(data), nullptr, reply.data(), (DWORD)reply.size(), 1500);
        auto* er = (ICMP_ECHO_REPLY*)reply.data();
        if (n > 0 && er->Status == IP_SUCCESS) times.push_back((int)er->RoundTripTime); else fails++;
        Sleep(100);
    }
    IcmpCloseHandle(h);
    if (!times.empty()) {
        double sum = 0; for (int t : times) sum += t;
        double avg = sum / times.size(), dev = 0;
        for (int t : times) dev += fabs(t - avg);
        r.ms = (int)(avg + 0.5); r.jitter = (int)(dev / times.size() + 0.5);
    } else r.note = L"no answer to ping (it may still work)";
    r.loss = fails * 20;
    r.done = true;
    return r;
}

// 0 = unknown / unreachable, 1 poor .. 4 excellent
static int quality(const Probe& p) {
    if (!p.done || p.ms < 0) return 0;
    double score = p.ms + p.jitter * 2.0 + p.loss * 8.0;
    // the HTTPS probe also counts the relay answering, so it reads ~20-40 ms above the game's own round trip
    return score < 100 ? 4 : score < 170 ? 3 : score < 280 ? 2 : 1;
}
static const wchar_t* quality_label(int q) {
    static const wchar_t* L[] = { L"No connection", L"Poor", L"OK", L"Good", L"Excellent" };
    return L[q < 0 ? 0 : q > 4 ? 4 : q];
}

// this PC's LAN addresses (shown on "Host on this PC")
static std::wstring lan_ips() {
    std::wstring out;
    ULONG sz = 16384;
    std::vector<BYTE> buf(sz);
    if (GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, nullptr,
                             (IP_ADAPTER_ADDRESSES*)buf.data(), &sz) != NO_ERROR) return out;
    for (auto* a = (IP_ADAPTER_ADDRESSES*)buf.data(); a; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp || a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        for (auto* u = a->FirstUnicastAddress; u; u = u->Next) {
            wchar_t ip[64]; DWORD n = 64;
            if (WSAAddressToStringW(u->Address.lpSockaddr, u->Address.iSockaddrLength, nullptr, ip, &n) == 0) {
                if (!out.empty()) out += L", ";
                out += ip;
            }
        }
    }
    return out;
}

// ------------------------------------------------------------------ invite links: poppycoop://join/CODE
static void register_protocol() {
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\poppycoop", 0, nullptr, 0, KEY_WRITE, nullptr, &k, nullptr) == ERROR_SUCCESS) {
        const wchar_t* d = L"URL:PoppyCoop invite";
        RegSetValueExW(k, nullptr, 0, REG_SZ, (const BYTE*)d, (DWORD)((wcslen(d) + 1) * 2));
        RegSetValueExW(k, L"URL Protocol", 0, REG_SZ, (const BYTE*)L"", 2);
        RegCloseKey(k);
    }
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\poppycoop\\shell\\open\\command", 0, nullptr, 0, KEY_WRITE, nullptr, &k, nullptr) == ERROR_SUCCESS) {
        std::wstring cmd = std::wstring(L"\"") + exe + L"\" \"%1\"";
        RegSetValueExW(k, nullptr, 0, REG_SZ, (const BYTE*)cmd.c_str(), (DWORD)((cmd.size() + 1) * 2));
        RegCloseKey(k);
    }
}
// room code out of "poppycoop://join/ABC123", an invite text or a bare code
static std::wstring extract_code(const std::wstring& text) {
    std::wstring t = text;
    size_t p = lower(t).find(L"poppycoop://join/");
    if (p != std::wstring::npos) t = t.substr(p + 17);
    else {
        size_t q = lower(t).find(L"room code:");
        if (q != std::wstring::npos) t = t.substr(q + 10);
    }
    std::wstring code;
    for (wchar_t ch : t) {
        if (iswalnum(ch) && ch < 128) { code += (wchar_t)towupper(ch); if (code.size() >= 12) break; }
        else if (!code.empty()) break;
    }
    return code;
}
static std::wstring new_code() {
    static const wchar_t* A = L"ABCDEFGHJKMNPQRSTUVWXYZ23456789";   // no 0/O/1/I/L: easy to read out
    std::random_device rd;
    std::wstring c;
    for (int i = 0; i < 6; i++) c += A[rd() % 31];
    return c;
}
