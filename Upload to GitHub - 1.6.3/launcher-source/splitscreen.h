// splitscreen.h - "Several games at once" with a layout: each game window gets its part of the screen.
//
// The games are started windowed (core.h split_args). Every few hundred ms the launcher finds each game's
// window (by process id; the first window started through Steam has none - it is the remaining game window),
// removes its frame and puts it at its place. A window that moved (focus change, the game resizing itself)
// is put back. Layouts: 1 = left / right, 2 = top / bottom (both on the main monitor), 3 = one per monitor.
// 3-4 windows in layouts 1-2: the four quarters of the main monitor.
#pragma once
#include "core.h"
#include <algorithm>
#include <tlhelp32.h>
#include <map>

static int g_split_layout = 0;          // ini Launcher SplitLayout: 0 off, 1 left/right, 2 top/bottom, 3 per monitor
static const int SPLIT_LAYOUTS = 4;
static const wchar_t* split_layout_name(int l) {
    static const wchar_t* N[] = { L"Off", L"Left / right", L"Top / bottom", L"One per monitor" };
    return N[(l >= 0 && l < SPLIT_LAYOUTS) ? l : 0];
}

struct MonitorList { std::vector<RECT> r; };
static BOOL CALLBACK split_mon_cb(HMONITOR m, HDC, LPRECT, LPARAM lp) {
    MONITORINFO mi = { sizeof(mi) };
    if (GetMonitorInfoW(m, &mi)) {
        auto* ml = (MonitorList*)lp;
        if (mi.dwFlags & MONITORINFOF_PRIMARY) ml->r.insert(ml->r.begin(), mi.rcMonitor);   // main monitor first
        else ml->r.push_back(mi.rcMonitor);
    }
    return TRUE;
}
static std::vector<RECT> split_monitors() {
    MonitorList ml;
    EnumDisplayMonitors(nullptr, nullptr, split_mon_cb, (LPARAM)&ml);
    if (ml.r.empty()) ml.r.push_back({ 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) });
    return ml.r;
}

// where game window `w` (0 = first) of `n` running ones goes; false = leave it alone
static bool split_rect(int w, int n, RECT& out) {
    if (!g_split_on || w < 0 || w > 7) return false;
    std::vector<RECT> mons = split_monitors();
    if (g_split_layout == 3) {
        if (w >= (int)mons.size()) return false;
        out = mons[w];
        return true;
    }
    RECT m = mons[0];
    int W = m.right - m.left, H = m.bottom - m.top;
    if (n >= 3) {                                              // 3-4 players: quarters
        if (w >= 4) return false;
        int col = w % 2, row = w / 2;
        out = { m.left + col * W / 2, m.top + row * H / 2, m.left + (col + 1) * W / 2, m.top + (row + 1) * H / 2 };
        return true;
    }
    if (w >= 2) return false;
    if (g_split_layout == 1) out = { m.left + w * W / 2, m.top, m.left + (w + 1) * W / 2, m.bottom };
    else out = { m.left, m.top + w * H / 2, m.right, m.top + (w + 1) * H / 2 };
    return true;
}

struct FindGameWnd { DWORD pid; HWND found; std::vector<std::pair<HWND, DWORD>> all; };
static BOOL CALLBACK split_wnd_cb(HWND h, LPARAM lp) {
    auto* f = (FindGameWnd*)lp;
    if (!IsWindowVisible(h) || GetWindow(h, GW_OWNER)) return TRUE;
    wchar_t cls[64] = {};
    GetClassNameW(h, cls, 64);
    if (wcscmp(cls, L"UnrealWindow") != 0) return TRUE;       // the game's main window class (Unreal Engine)
    RECT r; GetWindowRect(h, &r);
    if (r.right - r.left < 200 || r.bottom - r.top < 150) return TRUE;   // splash / tiny helper windows
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    f->all.push_back({ h, pid });
    if (pid == f->pid && !f->found) f->found = h;
    return TRUE;
}
static bool pid_alive(DWORD pid) {
    if (!pid) return false;
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!p) return false;
    DWORD code = 0;
    bool alive = GetExitCodeProcess(p, &code) && code == STILL_ACTIVE;
    CloseHandle(p);
    return alive;
}

// The launcher starts the game's small start exe (Poppy_Playtime.exe); it starts the real game
// (...-Win64-Shipping.exe) and waits for it. The window belongs to that child: window pid -> its parent.
static std::map<DWORD, DWORD> parent_pids() {
    std::map<DWORD, DWORD> m;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return m;
    PROCESSENTRY32W pe = { sizeof(pe) };
    if (Process32FirstW(snap, &pe)) do m[pe.th32ProcessID] = pe.th32ParentProcessID; while (Process32NextW(snap, &pe));
    CloseHandle(snap);
    return m;
}

// puts every game window at its place (called on a short timer while split screen is on)
static void keep_game_windows() {
    if (!g_split_on) return;
    FindGameWnd f = { 0, nullptr, {} };
    EnumWindows(split_wnd_cb, (LPARAM)&f);
    if (f.all.empty()) return;
    for (int w = 0; w < 8; w++) if (g_game_pid[w] && !pid_alive(g_game_pid[w])) g_game_pid[w] = 0;
    // a window whose process was started by one of our start exes belongs to that window slot
    std::map<DWORD, DWORD> parent = parent_pids();
    for (auto& e : f.all) {
        auto it = parent.find(e.second);
        if (it == parent.end()) continue;
        for (int w = 0; w < 8; w++) if (g_game_pid[w] && g_game_pid[w] == it->second) g_game_pid[w] = e.second;
    }
    // game windows nobody claimed (the first one, started by Steam, or games that were already running when
    // the launcher started) take the free places in process order
    std::sort(f.all.begin(), f.all.end(), [](const std::pair<HWND, DWORD>& x, const std::pair<HWND, DWORD>& y) { return x.second < y.second; });
    for (auto& e : f.all) {
        bool known = false;
        for (int w = 0; w < 8; w++) if (g_game_pid[w] == e.second) known = true;
        if (known) continue;
        for (int w = 0; w < 8; w++) if (!g_game_pid[w]) { g_game_pid[w] = e.second; break; }
    }
    int n = 0;
    for (int w = 0; w < 8; w++) if (g_game_pid[w]) n++;
    for (int w = 0; w < 8; w++) {
        if (!g_game_pid[w]) continue;
        HWND h = nullptr;
        for (auto& e : f.all) if (e.second == g_game_pid[w]) { h = e.first; break; }
        RECT want;
        if (!h || !split_rect(w, n, want) || IsIconic(h)) continue;
        LONG st = GetWindowLongW(h, GWL_STYLE);
        LONG flat = (st & ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MAXIMIZEBOX | WS_MINIMIZEBOX)) | WS_POPUP;
        bool restyle = st != flat;
        if (restyle) SetWindowLongW(h, GWL_STYLE, flat);
        RECT now; GetWindowRect(h, &now);
        if (restyle || !EqualRect(&now, &want))
            SetWindowPos(h, nullptr, want.left, want.top, want.right - want.left, want.bottom - want.top,
                         SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }
}
