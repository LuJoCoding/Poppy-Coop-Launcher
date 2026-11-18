// PoppyCoop Launcher 3 - window and UI (plain GDI, immediate-mode: every paint rebuilds the click areas).
#include "core.h"
#include <windowsx.h>
#include <shobjidl.h>
#include <functional>
#include <thread>
#include <atomic>
#include <cmath>

// ------------------------------------------------------------------ messages from worker threads
enum { WM_APP_PROGRESS = WM_APP + 1, WM_APP_INSTALLED, WM_APP_PROBE };
enum { TIMER_POLL = 1, TIMER_CARET = 2, TIMER_ANIM = 3, TIMER_PROBE = 4 };

// ------------------------------------------------------------------ state
enum class Page { Welcome, Chapter, Settings, Profile, App, Servers };

static HWND g_wnd;
static Profile g_prof;
static int g_sel = 0;                        // selected chapter index
static Page g_page = Page::Chapter;
static double g_s = 1.0;                     // DPI scale
static std::wstring g_toast;
static ULONGLONG g_toast_until = 0;
static std::atomic<bool> g_installing{ false };
static int g_install_pct = 0;
static int g_install_ch = -1;
static bool g_launch_after_install = false;
static int g_starting_ch = -1;               // waiting for the game process to appear
static ULONGLONG g_starting_t0 = 0;
static bool g_running[8] = {};
static int g_capture = -1;                   // key row waiting for a key press (settings page)
static bool g_confirm_uninstall = false;
static std::wstring g_edit_name;             // profile page buffer
static int g_view = 0;
// servers (Servers page): built-in relay + "host on this PC" + the player's own entries
static std::vector<Server> g_servers;
static int g_srv = 0;
static std::vector<std::pair<std::wstring, Probe>> g_probes;   // by server key
static std::atomic<bool> g_probing{ false };
static std::wstring g_new_name, g_new_addr, g_lan;
static int g_confirm_remove = -1;                       // what the chapter page shows (setup / not found / play...), part of the fade signature

static int S(double v) { return (int)(v * g_s + 0.5); }

// installed mod version + "setup done" per chapter, cached (paint runs at 60 fps while animating)
static std::wstring g_iv[8];
static ULONGLONG g_iv_t[8] = {};
static int g_setup_done[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };
static std::wstring inst_ver(const Chapter& c) {
    int i = (c.num - 1) & 7;
    if (!g_iv_t[i] || GetTickCount64() - g_iv_t[i] > 1500) { g_iv[i] = installed_version(c); g_iv_t[i] = GetTickCount64(); }
    return g_iv[i];
}
static void iv_reset() { for (auto& t : g_iv_t) t = 0; }
static bool setup_done(const Chapter& c) {
    int i = (c.num - 1) & 7;
    if (g_setup_done[i] < 0) g_setup_done[i] = ini_get(sec_name(c).c_str(), L"SetupDone") == L"1" ? 1 : 0;
    return g_setup_done[i] == 1;
}

static void toast(const std::wstring& t) { g_toast = t; g_toast_until = GetTickCount64() + 4000; InvalidateRect(g_wnd, nullptr, FALSE); }
static Chapter& cur() { return g_ch[g_sel]; }

static void save_profile() {
    ini_set(L"Launcher", L"Name", g_prof.name);
    ini_set(L"Launcher", L"Color", g_prof.color);
    ini_set(L"Launcher", L"Code", g_prof.code);
    ini_set(L"Launcher", L"JoinCode", g_prof.join_code);
    ini_set(L"Launcher", L"Tab", std::to_wstring(g_prof.tab));
    if (g_page != Page::Welcome) ini_set(L"Launcher", L"Chapter", std::to_wstring(g_sel + 1));
}

// ------------------------------------------------------------------ colours
struct PlayerColor { const wchar_t* id; const wchar_t* label; COLORREF rgb; };
static const PlayerColor COLORS[] = {
    { L"yellow", L"Toy Yellow", RGB(245, 197, 24) }, { L"orange", L"Orange", RGB(255, 140, 26) },
    { L"pink", L"Pink", RGB(255, 95, 162) }, { L"purple", L"Purple", RGB(155, 92, 255) },
    { L"green", L"Green", RGB(61, 214, 107) }, { L"teal", L"Teal", RGB(34, 199, 192) },
    { L"blue", L"Blue", RGB(61, 139, 255) },
};
static COLORREF player_rgb(const std::wstring& id) {
    for (auto& c : COLORS) if (id == c.id) return c.rgb;
    return COLORS[0].rgb;
}

// launcher colour themes (Launcher settings page); the accent is the figure colour or one picked there
struct Theme { const wchar_t* id; const wchar_t* label; COLORREF bg, side, card, card2, line, text, dim, ok, warn, bad; };
static const Theme THEMES[] = {
    { L"dark", L"Dark", RGB(16, 17, 24), RGB(22, 24, 33), RGB(29, 31, 43), RGB(38, 41, 56), RGB(52, 56, 74),
      RGB(236, 237, 245), RGB(140, 145, 166), RGB(70, 210, 120), RGB(255, 170, 60), RGB(255, 90, 90) },
    { L"midnight", L"Midnight", RGB(5, 6, 10), RGB(10, 11, 18), RGB(16, 18, 28), RGB(25, 28, 42), RGB(38, 42, 60),
      RGB(232, 234, 248), RGB(125, 131, 160), RGB(70, 210, 120), RGB(255, 170, 60), RGB(255, 90, 90) },
    { L"light", L"Light", RGB(240, 241, 246), RGB(228, 230, 238), RGB(255, 255, 255), RGB(232, 234, 242), RGB(205, 209, 222),
      RGB(26, 28, 38), RGB(105, 110, 132), RGB(22, 150, 72), RGB(200, 110, 0), RGB(210, 50, 50) },
};
static COLORREF C_BG, C_SIDE, C_CARD, C_CARD2, C_LINE, C_TEXT, C_DIM, C_OK, C_WARN, C_BAD;
static const COLORREF C_RED = RGB(229, 57, 70);
static std::wstring g_theme = L"dark", g_accent_pref = L"figure";   // accent: "figure" or a colour id
static bool g_anims = true;
static void apply_theme() {
    const Theme* t = &THEMES[0];
    for (auto& th : THEMES) if (g_theme == th.id) t = &th;
    C_BG = t->bg; C_SIDE = t->side; C_CARD = t->card; C_CARD2 = t->card2; C_LINE = t->line;
    C_TEXT = t->text; C_DIM = t->dim; C_OK = t->ok; C_WARN = t->warn; C_BAD = t->bad;
}

static COLORREF mix(COLORREF a, COLORREF b, double t) {
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return RGB((int)(GetRValue(a) * (1 - t) + GetRValue(b) * t), (int)(GetGValue(a) * (1 - t) + GetGValue(b) * t),
               (int)(GetBValue(a) * (1 - t) + GetBValue(b) * t));
}

// ------------------------------------------------------------------ animation
// Every animated value is eased towards its target each frame; while anything still moves a 60 fps timer
// keeps repainting, otherwise the window only repaints on input (no idle CPU use).
static ULONGLONG g_frame_ms = 0;
static double g_dt = 0;
static bool g_moving = false;
static std::vector<std::pair<unsigned long long, double>> g_anim;   // small: a few dozen widgets
static double anim(unsigned long long key, double target, double speed = 14.0) {
    for (auto& a : g_anim) if (a.first == key) {
        if (!g_anims) { a.second = target; return target; }
        double k = 1.0 - exp(-speed * g_dt);
        a.second += (target - a.second) * k;
        if (fabs(target - a.second) < 0.002) a.second = target; else g_moving = true;
        return a.second;
    }
    g_anim.push_back({ key, target });
    return target;
}
static unsigned long long akey(int kind, int x, int y) { return ((unsigned long long)kind << 48) ^ ((unsigned long long)(x & 0xffffff) << 24) ^ (unsigned)(y & 0xffffff); }
static double ease(double t) { if (t <= 0) return 0; if (t >= 1) return 1; return 1 - pow(1 - t, 3); }

static COLORREF target_accent() { return player_rgb(g_accent_pref == L"figure" ? g_prof.color : g_accent_pref); }
// the accent fades over to a new colour instead of jumping
static COLORREF g_acc_from = 0, g_acc_to = 0;
static ULONGLONG g_acc_t0 = 0;
static COLORREF accent();
// accent used as text: a darker shade on the light theme so yellow/teal stay readable
static COLORREF acc_text() { return g_theme == L"light" ? mix(accent(), RGB(0, 0, 0), 0.38) : accent(); }
static COLORREF accent() {
    COLORREF t = target_accent();
    if (t != g_acc_to) { g_acc_from = g_acc_t0 ? mix(g_acc_from, g_acc_to, ease((g_frame_ms - g_acc_t0) / 300.0)) : t; g_acc_to = t; g_acc_t0 = g_frame_ms; }
    double k = g_anims ? ease((g_frame_ms - g_acc_t0) / 300.0) : 1;
    if (k < 1) g_moving = true;
    return mix(g_acc_from, g_acc_to, k);
}
static COLORREF on_color(COLORREF c) {   // readable text on a coloured button
    return (GetRValue(c) * 299 + GetGValue(c) * 587 + GetBValue(c) * 114) / 1000 > 150 ? RGB(20, 20, 28) : RGB(255, 255, 255);
}

// ------------------------------------------------------------------ fonts
static std::wstring g_face = L"Segoe UI";
static HFONT F_LOGO, F_H1, F_H2, F_BODY, F_SMALL, F_BOLD, F_CODE, F_BIG;
static void make_fonts() {
    // Windows: Segoe UI. Wine / Proton report a "Segoe UI" but draw it with a serif font, so there Tahoma
    // (shipped with Wine and Proton) is used - same as the Launcher 2 Linux build.
    bool wine = GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version") != nullptr;
    g_face = wine ? L"Tahoma" : L"Segoe UI";
    auto mk = [](int px, int weight) {
        return CreateFontW(-S(px), 0, 0, 0, weight, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, g_face.c_str());
    };
    F_LOGO = mk(26, FW_BLACK); F_H1 = mk(30, FW_BOLD); F_H2 = mk(15, FW_BOLD); F_BODY = mk(14, FW_NORMAL);
    F_SMALL = mk(12, FW_NORMAL); F_BOLD = mk(14, FW_BOLD); F_CODE = mk(36, FW_BOLD); F_BIG = mk(20, FW_BOLD);
}

// ------------------------------------------------------------------ immediate-mode drawing + click areas
struct Hit { RECT r; std::function<void()> fn; bool hand; };
static std::vector<Hit> g_hits;
static POINT g_mouse = { -1, -1 };
static int g_pressed = -1;
static HDC g_dc;

static bool hover(const RECT& r) { return PtInRect(&r, g_mouse) != 0; }
static RECT R(int x, int y, int w, int h) { return { S(x), S(y), S(x + w), S(y + h) }; }
static void fill(const RECT& r, COLORREF c, int radius = 0) {
    HBRUSH b = CreateSolidBrush(c);
    if (radius <= 0) { FillRect(g_dc, &r, b); DeleteObject(b); return; }
    HPEN p = CreatePen(PS_SOLID, 1, c);
    HGDIOBJ ob = SelectObject(g_dc, b), op = SelectObject(g_dc, p);
    RoundRect(g_dc, r.left, r.top, r.right, r.bottom, S(radius * 2), S(radius * 2));
    SelectObject(g_dc, ob); SelectObject(g_dc, op);
    DeleteObject(b); DeleteObject(p);
}
static void frame(const RECT& r, COLORREF c, int radius, int width = 1) {
    HPEN p = CreatePen(PS_SOLID, S(width), c);
    HGDIOBJ op = SelectObject(g_dc, p), ob = SelectObject(g_dc, GetStockObject(NULL_BRUSH));
    RoundRect(g_dc, r.left, r.top, r.right, r.bottom, S(radius * 2), S(radius * 2));
    SelectObject(g_dc, op); SelectObject(g_dc, ob);
    DeleteObject(p);
}
static void circle(int cx, int cy, int rad, COLORREF c) {
    HBRUSH b = CreateSolidBrush(c); HPEN p = CreatePen(PS_SOLID, 1, c);
    HGDIOBJ ob = SelectObject(g_dc, b), op = SelectObject(g_dc, p);
    Ellipse(g_dc, S(cx - rad), S(cy - rad), S(cx + rad), S(cy + rad));
    SelectObject(g_dc, ob); SelectObject(g_dc, op);
    DeleteObject(b); DeleteObject(p);
}
static void text(const RECT& r, const std::wstring& s, HFONT f, COLORREF c, UINT flags = DT_LEFT | DT_TOP | DT_WORDBREAK) {
    SelectObject(g_dc, f);
    SetTextColor(g_dc, c);
    RECT rr = r;
    DrawTextW(g_dc, s.c_str(), (int)s.size(), &rr, flags | DT_NOPREFIX);
}
static int text_w(const std::wstring& s, HFONT f) {
    SelectObject(g_dc, f);
    SIZE sz; GetTextExtentPoint32W(g_dc, s.c_str(), (int)s.size(), &sz);
    return (int)(sz.cx / g_s);
}
static void click(const RECT& r, std::function<void()> fn) { g_hits.push_back({ r, std::move(fn), true }); }

enum class Btn { Primary, Secondary, Ghost, Danger };
static void button(int x, int y, int w, int h, const std::wstring& label, Btn style, std::function<void()> fn, bool enabled = true) {
    RECT r = R(x, y, w, h);
    bool hv = enabled && hover(r);
    double t = anim(akey(1, x, y), hv ? 1.0 : 0.0, 16);
    COLORREF bg, fg;
    switch (style) {
    case Btn::Primary: bg = accent(); fg = on_color(bg); break;
    case Btn::Danger: bg = C_RED; fg = RGB(255, 255, 255); break;
    case Btn::Ghost: bg = C_CARD; fg = C_TEXT; break;
    default: bg = C_CARD2; fg = C_TEXT; break;
    }
    if (!enabled) { bg = mix(bg, C_BG, 0.6); fg = mix(fg, C_BG, 0.5); }
    else {
        bg = mix(bg, style == Btn::Primary || style == Btn::Danger ? RGB(255, 255, 255) : C_TEXT, 0.12 * t);
        if (hv && (GetKeyState(VK_LBUTTON) & 0x8000)) bg = mix(bg, RGB(0, 0, 0), 0.12);   // pressed
    }
    fill(r, bg, 8);
    if (style == Btn::Ghost) frame(r, mix(C_LINE, accent(), t), 8);
    text(r, label, style == Btn::Primary ? F_BOLD : F_BODY, fg, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (enabled) click(r, std::move(fn));
}

// a single-line text box; the focused one gets the keyboard (WM_CHAR)
struct Field { std::wstring* value; size_t max; bool code; };
static Field g_focus = { nullptr, 0, false };
static bool g_caret_on = true;
static void textbox(int x, int y, int w, int h, std::wstring* value, size_t max, bool code, const std::wstring& placeholder, HFONT f) {
    RECT r = R(x, y, w, h);
    bool focused = g_focus.value == value;
    double ft = anim(akey(7, x, y), focused ? 1.0 : 0.0, 16), ht = anim(akey(8, x, y), hover(r) ? 1.0 : 0.0, 16);
    fill(r, C_BG, 8);
    frame(r, mix(mix(C_LINE, C_DIM, ht), accent(), ft), 8, ft > 0.5 ? 2 : 1);
    RECT tr = { r.left + S(14), r.top, r.right - S(10), r.bottom };
    if (value->empty() && !focused) text(tr, placeholder, f, mix(C_DIM, C_BG, 0.3), DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    else text(tr, *value, f, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    if (focused && g_caret_on) {
        int cx = tr.left + S(text_w(*value, f)) + S(1);
        RECT c = { cx, r.top + S(10), cx + S(2), r.bottom - S(10) };
        fill(c, accent());
    }
    click(r, [=] { g_focus = { value, max, code }; g_caret_on = true; });
}

static void badge(int x, int y, const wchar_t* label) {
    COLORREF c = !label ? C_DIM : (wcscmp(label, L"READY") == 0 ? C_OK : C_WARN);
    std::wstring t = label ? label : L"SOON";
    int w = text_w(t, F_SMALL) + 14;
    RECT r = R(x, y, w, 18);
    fill(r, mix(c, C_BG, 0.75), 9);
    text(r, t, F_SMALL, c, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

// ------------------------------------------------------------------ actions
static void start_install(int ch, bool then_launch);
static void do_play();

static void copy_text(const std::wstring& s) {
    if (!OpenClipboard(g_wnd)) return;
    EmptyClipboard();
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, (s.size() + 1) * sizeof(wchar_t));
    if (h) {
        memcpy(GlobalLock(h), s.c_str(), (s.size() + 1) * sizeof(wchar_t));
        GlobalUnlock(h);
        SetClipboardData(CF_UNICODETEXT, h);
    }
    CloseClipboard();
}
static std::wstring clipboard_text() {
    std::wstring s;
    if (!OpenClipboard(g_wnd)) return s;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) { const wchar_t* p = (const wchar_t*)GlobalLock(h); if (p) s = p; GlobalUnlock(h); }
    CloseClipboard();
    return s;
}

static void browse_folder(Chapter& c) {
    IFileOpenDialog* dlg = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&dlg)))) return;
    DWORD opts; dlg->GetOptions(&opts);
    dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    std::wstring title = L"Select your Poppy Playtime Chapter " + std::to_wstring(c.num) + L" folder";
    dlg->SetTitle(title.c_str());
    if (SUCCEEDED(dlg->Show(g_wnd))) {
        IShellItem* it = nullptr;
        if (SUCCEEDED(dlg->GetResult(&it))) {
            PWSTR p = nullptr;
            if (SUCCEEDED(it->GetDisplayName(SIGDN_FILESYSPATH, &p))) {
                c.dir = normalize_dir(c, p);
                c.state = check_dir(c, c.dir);
                if (dir_usable(c.state)) ini_set(L"Launcher", c.ini_key, c.dir);
                CoTaskMemFree(p);
            }
            it->Release();
        }
    }
    dlg->Release();
}

static void apply_settings(Chapter& c) {
    chapter_save_settings(c);
    if (!inst_ver(c).empty()) {
        if (!write_mod_settings(c, g_prof)) toast(L"Couldn't save the mod settings - close the game or run the launcher as administrator.");
        else if (g_running[g_sel]) toast(L"Saved - takes effect next time you start the game.");
    }
}

// ------------------------------------------------------------------ servers
static std::wstring srv_key(const Server& v) { return v.kind == SrvKind::Host ? L"host" : v.addr + L"|" + std::to_wstring(v.port); }
static const Probe* probe_of(const Server& v) {
    std::wstring k = srv_key(v);
    for (auto& p : g_probes) if (p.first == k) return &p.second;
    return nullptr;
}
static void load_servers() {
    g_servers.clear();
    g_servers.push_back({ SrvKind::Relay, L"PoppyCoop Relay", RELAY_URL, 27777, true });
    g_servers.push_back({ SrvKind::Host, L"Host on this PC", L"", 27777, true });
    int n = _wtoi(ini_get(L"Servers", L"Count", L"0").c_str());
    for (int i = 1; i <= n && i <= 8; i++) {
        Server v;
        if (!parse_server(ini_get(L"Servers", (L"Addr" + std::to_wstring(i)).c_str()), v)) continue;
        v.name = ini_get(L"Servers", (L"Name" + std::to_wstring(i)).c_str());
        if (v.name.empty()) v.name = v.addr;
        v.builtin = false;
        g_servers.push_back(v);
    }
    std::wstring sel = ini_get(L"Launcher", L"Server");
    g_srv = 0;
    for (int i = 0; i < (int)g_servers.size(); i++) if (srv_key(g_servers[i]) == sel) g_srv = i;
}
static void save_servers() {
    int n = 0;
    WritePrivateProfileStringW(L"Servers", nullptr, nullptr, g_ini.c_str());     // rewrite the section
    for (auto& v : g_servers) {
        if (v.builtin) continue;
        n++;
        ini_set(L"Servers", (L"Name" + std::to_wstring(n)).c_str(), v.name);
        ini_set(L"Servers", (L"Addr" + std::to_wstring(n)).c_str(),
                v.kind == SrvKind::Relay ? v.addr : v.addr + L":" + std::to_wstring(v.port));
    }
    ini_set(L"Servers", L"Count", std::to_wstring(n));
    ini_set(L"Launcher", L"Server", srv_key(g_servers[g_srv]));
}
static void apply_server() {
    const Server& v = g_servers[g_srv];
    g_prof.srv_mode = v.kind == SrvKind::Host ? L"host" : L"join";
    g_prof.srv_addr = v.kind == SrvKind::Host ? L"127.0.0.1" : v.addr;
    g_prof.srv_port = v.port;
}

// measure in the background (all servers, or just the selected one), results come back as WM_APP_PROBE
struct ProbeResult { std::wstring key; Probe p; };
static void start_probe(bool all) {
    if (g_probing.exchange(true)) return;
    std::vector<Server> list;
    for (int i = 0; i < (int)g_servers.size(); i++)
        if ((all || i == g_srv) && g_servers[i].kind != SrvKind::Host) list.push_back(g_servers[i]);
    for (auto& v : list) {   // mark as "measuring"
        bool found = false;
        for (auto& p : g_probes) if (p.first == srv_key(v)) { found = true; }
        if (!found) g_probes.push_back({ srv_key(v), Probe() });
    }
    HWND w = g_wnd;
    std::thread([list, w] {
        for (auto& v : list) {
            auto* r = new ProbeResult{ srv_key(v), v.kind == SrvKind::Relay ? probe_relay(v.addr) : probe_direct(v.addr) };
            if (!PostMessageW(w, WM_APP_PROBE, 0, (LPARAM)r)) delete r;
        }
        g_probing = false;
        PostMessageW(w, WM_APP_PROBE, 1, 0);
    }).detach();
}

static COLORREF quality_color(int q) { return q >= 3 ? C_OK : q == 2 ? C_WARN : q == 1 ? C_BAD : C_DIM; }
// four signal bars; while measuring they light up one after another
static void signal_bars(int x, int y, const Probe* p, unsigned long long key) {
    bool measuring = !p || !p->done;
    int q = measuring ? 0 : quality(*p);
    double shown = anim(key, q, 10);
    for (int i = 0; i < 4; i++) {
        int bh = 6 + i * 4;
        COLORREF c = C_LINE;
        if (measuring) {
            int step = (int)(g_frame_ms / 180) % 5;
            if (i < step) c = mix(C_LINE, C_DIM, 0.6);
            if (g_anims) g_moving = true;
        } else if (shown >= i + 0.5) c = quality_color(q);
        fill(R(x + i * 6, y + 18 - bh, 4, bh), c, 1);
    }
}
static std::wstring probe_text(const Server& v, const Probe* p) {
    if (v.kind == SrvKind::Host) return L"You are the server";
    if (!p || !p->done) return L"Measuring...";
    if (p->ms < 0) return p->note.empty() ? L"Unreachable" : p->note;
    return std::to_wstring(p->ms) + L" ms  \x00B7  " + quality_label(quality(*p));
}

static void draw_server_card(int h) {
    RECT r = R(16, h - 52, 248, 46);
    bool on = g_page == Page::Servers;
    double ht = anim(akey(30, 0, 0), hover(r) ? 1.0 : 0.0, 16);
    fill(r, mix(mix(C_SIDE, C_CARD, ht), C_CARD2, on ? 1.0 : 0.0), 10);
    const Server& v = g_servers[g_srv];
    const Probe* p = probe_of(v);
    if (v.kind == SrvKind::Host) {
        for (int i = 0; i < 4; i++) fill(R(30 + i * 6, h - 39 + 18 - (6 + i * 4), 4, 6 + i * 4), C_OK, 1);
    } else signal_bars(30, h - 39, p, akey(31, 0, 0));
    text(R(64, h - 48, 196, 20), v.name, F_SMALL, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    std::wstring d = probe_text(v, p);
    if (p && p->done && !p->colo.empty()) d += L"  \x00B7  " + p->colo;
    text(R(64, h - 30, 196, 18), d, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    click(r, [] { g_page = Page::Servers; g_focus = {}; g_capture = -1; g_confirm_remove = -1; start_probe(true); });
}

// ------------------------------------------------------------------ sidebar
static void draw_sidebar(int h) {
    fill(R(0, 0, 280, h), C_SIDE);
    text(R(28, 26, 240, 30), L"POPPY PLAYTIME", F_LOGO, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(28, 56, 240, 30), L"CO-OP", F_LOGO, acc_text(), DT_LEFT | DT_SINGLELINE);

    // profile card
    RECT pc = R(16, 100, 248, 58);
    bool hv = hover(pc) || g_page == Page::Profile;
    fill(pc, hv ? C_CARD2 : C_CARD, 10);
    circle(44, 129, 13, player_rgb(g_prof.color));   // the figure colour, even with another accent
    std::wstring nm = g_prof.name.empty() ? L"Set your name" : g_prof.name;
    text(R(66, 110, 180, 20), nm, F_BOLD, g_prof.name.empty() ? C_WARN : C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    text(R(66, 130, 180, 18), L"Name & colour  \x203A", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    click(pc, [] { g_page = Page::Profile; g_edit_name = g_prof.name; g_focus = { &g_edit_name, 24, false }; });

    text(R(28, 180, 200, 18), L"CHAPTERS", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    bool any_sel = g_page != Page::Welcome && g_page != Page::App;
    double bar = anim(akey(14, 0, 0), g_sel, 16), bar_a = anim(akey(15, 0, 0), any_sel ? 1.0 : 0.0, 14);
    for (int i = 0; i < (int)g_ch.size(); i++) {
        Chapter& c = g_ch[i];
        RECT r = R(16, 202 + i * 62, 248, 56);
        bool sel = i == g_sel && g_page != Page::Welcome && g_page != Page::App;
        double ht = anim(akey(12, i, 0), hover(r) ? 1.0 : 0.0, 16), st = anim(akey(13, i, 0), sel ? 1.0 : 0.0, 14);
        fill(r, mix(mix(C_SIDE, C_CARD, ht), C_CARD2, st), 10);
        COLORREF tc = playable(c) ? C_TEXT : C_DIM;
        text(R(32, 210 + i * 62, 160, 20), L"Chapter " + std::to_wstring(c.num), F_BOLD, tc, DT_LEFT | DT_SINGLELINE);
        std::wstring sub = c.title;
        if (playable(c)) {
            if (g_running[i]) sub = L"In game";
            else if (!dir_usable(c.state) || (inst_ver(c).empty() && !setup_done(c))) sub = L"Not set up yet";
            else if (inst_ver(c).empty()) sub = L"Installs when you play";
            else if (inst_ver(c) != MOD_VERSION) sub = L"Update ready";
        }
        text(R(32, 230 + i * 62, 170, 18), sub, F_SMALL, g_running[i] ? C_OK : C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        badge(200, 211 + i * 62, c.badge);
        click(r, [i] { g_sel = i; g_page = Page::Chapter; g_focus = {}; g_capture = -1; g_confirm_uninstall = false; save_profile(); });
    }

    if (bar_a > 0.02) fill(R(16, 214 + (int)(bar * 62 + 0.5), 4, 32), mix(C_SIDE, accent(), bar_a), 2);

    // launcher settings (colours, animations)
    {
        RECT r = R(16, h - 98, 248, 36);
        bool on = g_page == Page::App;
        double ht = anim(akey(16, 0, 0), hover(r) ? 1.0 : 0.0, 16);
        fill(r, mix(mix(C_SIDE, C_CARD, ht), C_CARD2, on ? 1.0 : 0.0), 10);
        text(R(32, h - 98, 220, 36), L"Launcher settings", F_SMALL, on ? C_TEXT : mix(C_DIM, C_TEXT, ht), DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        click(r, [] { g_page = Page::App; g_focus = {}; g_capture = -1; });
    }

    // server + connection quality (click: Servers page)
    draw_server_card(h);
}

// ------------------------------------------------------------------ chapter page parts
static const int MX = 312;   // main area x
static const int MW = 636;   // main area width

static void draw_colors(int x, int y) {
    for (int i = 0; i < 7; i++) {
        int cx = x + 18 + i * 46;
        bool sel = g_prof.color == COLORS[i].id;
        RECT r = R(cx - 18, y, 36, 36);
        double st = anim(akey(9, cx, y), sel ? 1.0 : 0.0, 16), ht = anim(akey(10, cx, y), hover(r) ? 1.0 : 0.0, 16);
        if (st > 0.02) { circle(cx, y + 18, 12 + (int)(6 * st + 0.5), mix(C_CARD, C_TEXT, st)); circle(cx, y + 18, 12 + (int)(3 * st + 0.5), C_CARD); }
        else if (ht > 0.02) circle(cx, y + 18, 12 + (int)(5 * ht + 0.5), mix(C_CARD, C_LINE, ht));
        circle(cx, y + 18, 12, COLORS[i].rgb);
        std::wstring id = COLORS[i].id;
        click(r, [id] { g_prof.color = id; save_profile(); });
    }
}

static std::wstring dir_message(const Chapter& c, COLORREF& col) {
    switch (c.state) {
    case DirState::Ok: col = C_OK; return c.needs_ue5 ? L"Chapter 1 v1.3 found (Unreal Engine 5)" : L"Chapter " + std::to_wstring(c.num) + L" found";
    case DirState::OkUnknownVersion: col = C_OK; return L"Poppy Playtime found (version couldn't be checked)";
    case DirState::OldVersion: col = C_BAD; return L"This is the old Chapter 1 - update it to v1.3 in Steam first";
    case DirState::NotFound: col = C_BAD; return L"Chapter " + std::to_wstring(c.num) + L" isn't in that folder";
    default: col = C_DIM; return L"No folder selected yet - click Browse";
    }
}

// a primary button that fills up while the mod installs
static void progress_button(int x, int y, int w, int h, const std::wstring& label) {
    double p = anim(akey(6, 0, 0), g_install_pct / 100.0, 8);
    RECT r = R(x, y, w, h);
    fill(r, mix(accent(), C_BG, 0.65), 8);
    if (p > 0.01) fill(R(x, y, std::max(16, (int)(w * p)), h), accent(), 8);
    text(r, label + L" " + std::to_wstring((int)(p * 100 + 0.5)) + L"%", F_BOLD, p > 0.5 ? on_color(accent()) : C_TEXT,
         DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void search_again(Chapter& c) {
    Detect d = detect_game(c);
    c.detect = (int)d.what;
    if (d.what == Found::Ok) {
        c.dir = d.dir; c.found_where = d.where; c.state = check_dir(c, c.dir);
        ini_set(L"Launcher", c.ini_key, c.dir);
        toast(L"Found Chapter " + std::to_wstring(c.num) + L" in your " + d.where + L".");
    } else if (d.what == Found::OldVersion) {
        c.dir = d.dir; c.found_where = d.where; c.state = check_dir(c, c.dir);
        toast(L"Only found the old Chapter 1 - co-op needs v1.3.");
    } else toast(L"Still not found - choose the folder yourself.");
}

static void draw_folder_row(Chapter& c, int y) {
    RECT box = R(MX, y, MW - 130, 40);
    fill(box, C_BG, 8); frame(box, C_LINE, 8);
    std::wstring shown = c.dir.empty() ? L"No folder selected" : c.dir;
    text({ box.left + S(14), box.top, box.right - S(10), box.bottom }, shown, F_SMALL, c.dir.empty() ? C_DIM : C_TEXT,
         DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_PATH_ELLIPSIS);
    Chapter* pc = &c;
    button(MX + MW - 118, y, 118, 40, L"Browse", Btn::Secondary, [pc] { browse_folder(*pc); pc->found_where.clear(); });
    COLORREF col;
    std::wstring m = dir_message(c, col);
    if (dir_usable(c.state) && !c.found_where.empty()) m += L" - found automatically (" + c.found_where + L")";
    circle(MX + 6, y + 58, 4, col);
    text(R(MX + 18, y + 49, MW - 18, 20), m, F_SMALL, col, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
}

// nothing found anywhere: say so, show where we looked, let the player pick the folder
static void draw_not_found(Chapter& c, int y) {
    g_view = 3;
    RECT card = R(MX - 16, y, MW + 32, 330);
    fill(card, C_CARD, 14);
    text(R(MX, y + 18, MW, 20), L"SET UP CHAPTER " + std::to_wstring(c.num), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    circle(MX + 12, y + 56, 12, mix(C_CARD, C_WARN, 0.25));
    text(R(MX, y + 44, 24, 24), L"?", F_BOLD, C_WARN, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    text(R(MX + 36, y + 42, MW - 36, 28), L"Chapter " + std::to_wstring(c.num) + L" wasn't found automatically", F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX, y + 84, MW, 40), L"The launcher looked in all your Steam libraries and in Steam's download folder - a version "
         L"downloaded with the Steam console (downpatch) always ends up there:", F_SMALL, C_DIM);
    std::wstring depot = L"steamapps\\content\\app_" + std::wstring(c.appid) + L"\\depot_" + std::to_wstring(_wtoi(c.appid) + 1);
    RECT pr = R(MX, y + 126, MW, 34);
    fill(pr, C_BG, 8);
    text(R(MX + 14, y + 126, MW - 28, 34), L"Steam\\" + depot, F_SMALL, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    text(R(MX, y + 172, MW, 40), L"If the game is somewhere else (another drive, a copied folder), choose the folder that "
         L"contains " + std::wstring(c.exe) + L" yourself.", F_SMALL, C_DIM);
    Chapter* pc = &c;
    button(MX + MW - 220, y + 270, 220, 44, L"Choose folder...", Btn::Primary, [pc] { browse_folder(*pc); pc->found_where.clear(); });
    button(MX + MW - 380, y + 270, 148, 44, L"Search again", Btn::Ghost, [pc] { search_again(*pc); });
}

static void draw_setup(Chapter& c, int y) {
    if (c.dir.empty()) { draw_not_found(c, y); return; }
    g_view = 2;
    RECT card = R(MX - 16, y, MW + 32, 330);
    fill(card, C_CARD, 14);
    text(R(MX, y + 18, MW, 20), L"SET UP CHAPTER " + std::to_wstring(c.num), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    bool found = dir_usable(c.state);
    text(R(MX, y + 38, MW, 26), found ? L"Chapter " + std::to_wstring(c.num) + L" is ready to be set up"
                                      : L"Where is Chapter " + std::to_wstring(c.num) + L" installed?", F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
    std::wstring tip = c.needs_ue5 ? L"Co-op needs Chapter 1 version 1.3 (the current Steam version). " : L"";
    tip += found ? L"Is this the right folder? If not, pick another one with Browse."
                 : L"Pick the folder that contains " + std::wstring(c.exe) + L" (Steam > right-click the game > Manage > Browse local files).";
    text(R(MX, y + 68, MW, 40), tip, F_SMALL, C_DIM);
    draw_folder_row(c, y + 114);

    int by = y + 200;
    text(R(MX, by, 300, 20), L"What should other players call you?", F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE);
    textbox(MX, by + 24, 300, 40, &g_prof.name, 24, false, L"Your name", F_BODY);
    draw_colors(MX + 320, by + 26);
    if (g_installing && g_install_ch == g_sel) { progress_button(MX + MW - 220, y + 270, 220, 44, L"Installing"); return; }
    bool ok = found && !trim(g_prof.name).empty() && !g_installing;
    int idx = g_sel;
    button(MX + MW - 220, y + 270, 220, 44, L"Install co-op mod", Btn::Primary, [idx] {
        g_prof.name = clean_name(g_prof.name); save_profile(); g_focus = {};
        if (game_running(g_ch[idx])) { toast(L"Close Poppy Playtime first so the mod can be installed."); return; }
        start_install(idx, false);
    }, ok);
}

static void draw_modes(int y) {
    const wchar_t* tabs[] = { L"Quick Play", L"Create Game", L"Join Game" };
    int tw = (MW - 16) / 3;
    double pos = anim(akey(3, 0, 0), g_prof.tab, 16);            // the highlight slides between the tabs
    for (int i = 0; i < 3; i++) {
        RECT r = R(MX + i * (tw + 8), y, tw, 42);
        fill(r, mix(C_CARD, C_CARD2, anim(akey(11, i, 0), hover(r) ? 1.0 : 0.0, 16)), 10);
    }
    fill(R(MX + (int)(pos * (tw + 8) + 0.5), y, tw, 42), accent(), 10);
    for (int i = 0; i < 3; i++) {
        RECT r = R(MX + i * (tw + 8), y, tw, 42);
        double on = 1.0 - std::min(1.0, fabs(pos - i));
        text(r, tabs[i], F_BOLD, mix(C_TEXT, on_color(accent()), on), DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        click(r, [i] { g_prof.tab = i; g_focus = i == 2 ? Field{ &g_prof.join_code, 12, true } : Field{}; save_profile(); });
    }
    RECT card = R(MX, y + 54, MW, 150);
    fill(card, C_CARD, 14);
    int cy = y + 72;
    if (g_prof.tab == 0) {
        text(R(MX + 20, cy, MW - 40, 24), L"Public lobby", F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
        text(R(MX + 20, cy + 32, MW - 40, 60), L"Jump straight in and play with anyone who's online right now. No code needed.", F_BODY, C_DIM);
    } else if (g_prof.tab == 1) {
        if (g_prof.code.empty()) { g_prof.code = new_code(); save_profile(); }
        text(R(MX + 20, cy, 300, 18), L"YOUR ROOM CODE", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
        RECT cr = R(MX + 20, cy + 20, 260, 48);
        text(cr, g_prof.code, F_CODE, hover(cr) ? acc_text() : C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        click(cr, [] { copy_text(g_prof.code); toast(L"Copied to clipboard!  Room code " + g_prof.code); });
        button(MX + 300, cy + 4, 150, 36, L"Copy code", Btn::Secondary, [] { copy_text(g_prof.code); toast(L"Copied to clipboard!  Room code " + g_prof.code); });
        button(MX + 460, cy + 4, 156, 36, L"Copy invite", Btn::Secondary, [] {
            copy_text(L"Join my Poppy Playtime co-op game!\r\nRoom code: " + g_prof.code +
                      L"\r\nIn the PoppyCoop launcher pick Join Game and enter the code, or open this link: poppycoop://join/" + g_prof.code);
            toast(L"Invite copied - paste it to your friends!");
        });
        button(MX + 300, cy + 48, 150, 36, L"New code", Btn::Ghost, [] { g_prof.code = new_code(); save_profile(); });
        text(R(MX + 20, cy + 96, MW - 40, 40), L"Share the code or the invite. Friends pick Join Game and enter it.", F_SMALL, C_DIM);
    } else {
        text(R(MX + 20, cy, 300, 18), L"FRIEND'S ROOM CODE", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
        textbox(MX + 20, cy + 22, 300, 48, &g_prof.join_code, 12, true, L"ABC123", F_BIG);
        button(MX + 336, cy + 28, 120, 36, L"Paste", Btn::Secondary, [] {
            std::wstring code = extract_code(clipboard_text());
            if (code.empty()) { toast(L"No room code on the clipboard."); return; }
            g_prof.join_code = code; save_profile(); toast(L"Pasted room code " + code);
        });
        text(R(MX + 20, cy + 84, MW - 40, 40), L"Ask your friend for their code, or just open the invite link they sent you.", F_SMALL, C_DIM);
    }
}

static void draw_play_bar(Chapter& c, int y) {
    // mod status (left) + play button (right)
    std::wstring iv = inst_ver(c), st;
    COLORREF col = C_OK;
    if (iv.empty()) { st = L"Co-op mod not installed yet - it installs when you press Play"; col = C_WARN; }
    else if (iv != MOD_VERSION) { st = L"Update available: v" + iv + L" to v" MOD_VERSION L" - installs when you press Play"; col = C_WARN; }
    else st = L"Co-op mod v" + iv + L" installed";
    circle(MX + 6, y + 13, 4, col);
    text(R(MX + 18, y + 3, MW - 260, 20), st, F_SMALL, col, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    std::wstring room = g_prof.tab == 0 ? L"Public lobby" : (g_prof.tab == 1 ? L"Your room " + g_prof.code : L"Room " + (g_prof.join_code.empty() ? L"-" : g_prof.join_code));
    text(R(MX + 18, y + 24, MW - 260, 20), L"Playing as " + g_prof.name + L"  \x00B7  " + room + L"  \x00B7  " + g_servers[g_srv].name, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    text(R(MX + 18, y + 44, MW - 260, 20), L"Everyone loads the same checkpoint (Play > Load Game).", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);

    std::wstring label = L"PLAY";
    bool en = true;
    if (g_running[g_sel]) { label = L"IN GAME"; en = false; }
    else if (g_installing) { progress_button(MX + MW - 220, y, 220, 64, L"INSTALLING"); return; }
    else if (g_starting_ch == g_sel) { label = L"STARTING..."; en = false; }
    button(MX + MW - 220, y, 220, 64, label, Btn::Primary, [] { do_play(); }, en);
}

static void draw_chapter(int h) {
    Chapter& c = cur();
    text(R(MX, 28, 300, 18), L"CHAPTER " + std::to_wstring(c.num), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW - 160, 40), c.title, F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    badge(MX + text_w(c.title, F_H1) + 14, 60, c.badge);
    if (!playable(c)) {
        g_view = 1;
        RECT card = R(MX, 110, MW, 150);
        fill(card, C_CARD, 14);
        text(R(MX + 24, 132, MW - 48, 24), L"Coming later", F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
        text(R(MX + 24, 166, MW - 48, 60), L"Co-op for this chapter is still being built. It unlocks in a future update of the launcher.", F_BODY, C_DIM);
        return;
    }
    // the setup card stays until the player pressed "Install" once (or the mod is already there)
    bool ready = dir_usable(c.state) && !trim(g_prof.name).empty() && !(g_installing && g_install_ch == g_sel)
                 && (!inst_ver(c).empty() || setup_done(c));
    if (ready)
        button(MX + MW - 130, 50, 130, 36, L"Settings", Btn::Ghost, [] { g_page = Page::Settings; g_focus = {}; g_capture = -1; g_confirm_uninstall = false; });
    text(R(MX, 98, MW, 44), c.blurb, F_SMALL, C_DIM);
    if (!ready) { draw_setup(c, 152); return; }
    g_view = 4;
    draw_modes(156);
    draw_play_bar(c, h - 100);
}

// ------------------------------------------------------------------ welcome page (first start: nothing is set up yet)
static void draw_welcome(int h) {
    text(R(MX, 28, MW, 18), L"WELCOME", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW, 40), L"Play Poppy Playtime together", F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX, 96, MW, 40), L"Pick the chapter you want to play. The launcher only asks for that chapter's game folder - you don't need the other chapters.", F_BODY, C_DIM);
    int cw = (MW - 16) / 2;
    for (int i = 0; i < 2; i++) {
        Chapter& c = g_ch[i];
        RECT r = R(MX + i * (cw + 16), 160, cw, 230);
        bool hv = hover(r);
        fill(r, hv ? C_CARD2 : C_CARD, 14);
        if (hv) frame(r, accent(), 14, 2);
        text(R(MX + i * (cw + 16) + 22, 182, cw - 44, 18), L"CHAPTER " + std::to_wstring(c.num), F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
        text(R(MX + i * (cw + 16) + 22, 202, cw - 44, 30), c.title, F_BIG, C_TEXT, DT_LEFT | DT_SINGLELINE);
        badge(MX + i * (cw + 16) + 22, 238, c.badge);
        text(R(MX + i * (cw + 16) + 22, 266, cw - 44, 90), c.blurb, F_SMALL, C_DIM);
        std::wstring st = dir_usable(c.state) ? L"Game found - ready to set up  \x203A" : L"Set up  \x203A";
        text(R(MX + i * (cw + 16) + 22, 356, cw - 44, 20), st, F_BOLD, hv ? acc_text() : C_TEXT, DT_LEFT | DT_SINGLELINE);
        click(r, [i] { g_sel = i; g_page = Page::Chapter; save_profile(); });
    }
    text(R(MX, 410, MW, 40), L"Chapters 3 to 5 come in a later update. You can set up another chapter any time from the list on the left.", F_SMALL, C_DIM);
    (void)h;
}

// ------------------------------------------------------------------ settings page
static const wchar_t* vk_name(UINT vk) {
    static wchar_t buf[16];
    if (vk >= 'A' && vk <= 'Z') { buf[0] = (wchar_t)vk; buf[1] = 0; return buf; }
    static const wchar_t* digits[] = { L"ZERO", L"ONE", L"TWO", L"THREE", L"FOUR", L"FIVE", L"SIX", L"SEVEN", L"EIGHT", L"NINE" };
    if (vk >= '0' && vk <= '9') return digits[vk - '0'];
    static const wchar_t* nums[] = { L"NUM_ZERO", L"NUM_ONE", L"NUM_TWO", L"NUM_THREE", L"NUM_FOUR", L"NUM_FIVE", L"NUM_SIX", L"NUM_SEVEN", L"NUM_EIGHT", L"NUM_NINE" };
    if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) return nums[vk - VK_NUMPAD0];
    if (vk >= VK_F1 && vk <= VK_F12) { swprintf(buf, 16, L"F%d", vk - VK_F1 + 1); return buf; }
    switch (vk) {
    case VK_SPACE: return L"SPACE"; case VK_TAB: return L"TAB"; case VK_BACK: return L"BACKSPACE"; case VK_RETURN: return L"RETURN";
    case VK_INSERT: return L"INS"; case VK_DELETE: return L"DEL"; case VK_HOME: return L"HOME"; case VK_END: return L"END";
    case VK_PRIOR: return L"PAGE_UP"; case VK_NEXT: return L"PAGE_DOWN"; case VK_LEFT: return L"LEFT_ARROW";
    case VK_RIGHT: return L"RIGHT_ARROW"; case VK_UP: return L"UP_ARROW"; case VK_DOWN: return L"DOWN_ARROW";
    case VK_MULTIPLY: return L"MULTIPLY"; case VK_ADD: return L"ADD"; case VK_SUBTRACT: return L"SUBTRACT";
    case VK_DECIMAL: return L"DECIMAL"; case VK_DIVIDE: return L"DIVIDE"; case VK_PAUSE: return L"PAUSE";
    }
    return nullptr;
}
static std::wstring key_label(const std::wstring& k) {
    static const struct { const wchar_t* a; const wchar_t* b; } nice[] = {
        { L"ZERO", L"0" }, { L"ONE", L"1" }, { L"TWO", L"2" }, { L"THREE", L"3" }, { L"FOUR", L"4" }, { L"FIVE", L"5" },
        { L"SIX", L"6" }, { L"SEVEN", L"7" }, { L"EIGHT", L"8" }, { L"NINE", L"9" }, { L"PAGE_UP", L"Page Up" },
        { L"PAGE_DOWN", L"Page Down" }, { L"LEFT_ARROW", L"Left" }, { L"RIGHT_ARROW", L"Right" }, { L"UP_ARROW", L"Up" },
        { L"DOWN_ARROW", L"Down" }, { L"RETURN", L"Enter" }, { L"BACKSPACE", L"Backspace" }, { L"SPACE", L"Space" },
    };
    for (auto& n : nice) if (k == n.a) return n.b;
    if (k.rfind(L"NUM_", 0) == 0) return L"Num " + key_label(k.substr(4));
    return k;
}
// keys the game itself uses (warned about, still allowed)
static bool game_key(const std::wstring& k) {
    static const wchar_t* used[] = { L"W", L"A", L"S", L"D", L"E", L"C", L"SPACE", L"TAB", L"F", L"R", L"Q" };
    for (auto u : used) if (k == u) return true;
    return false;
}

static void set_key(UINT vk) {
    Chapter& c = cur();
    if (g_capture < 0 || g_capture >= (int)c.keys.size()) return;
    if (vk == VK_ESCAPE) { g_capture = -1; return; }
    const wchar_t* n = vk_name(vk);
    if (!n) { toast(L"That key can't be used - pick another one."); return; }
    std::wstring k = n;
    if (k == L"F8" || k == L"F9") toast(L"F8 / F9 are kept free for other mods - pick another key.");
    else {
        for (int i = 0; i < (int)c.keys.size(); i++)
            if (i != g_capture && c.keys[i].value == k) { c.keys[i].value = c.keys[g_capture].value; toast(L"Swapped with \"" + std::wstring(c.keys[i].label) + L"\"."); }
        c.keys[g_capture].value = k;
        if (game_key(k)) toast(L"Careful: the game uses " + key_label(k) + L" too.");
        apply_settings(c);
    }
    g_capture = -1;
}

static void draw_toggle(int x, int y, bool on) {
    double t = anim(akey(2, x, y), on ? 1.0 : 0.0, 18);
    RECT r = R(x, y, 40, 22);
    fill(r, mix(C_LINE, accent(), t), 11);
    circle(x + 11 + (int)(18 * t + 0.5), y + 11, 8, RGB(255, 255, 255));
}

static void draw_settings(int h) {
    Chapter& c = cur();
    button(MX, 26, 96, 32, L"\x2039  Back", Btn::Ghost, [] { g_page = Page::Chapter; g_capture = -1; g_confirm_uninstall = false; });
    text(R(MX + 112, 28, MW - 112, 30), L"Chapter " + std::to_wstring(c.num) + L" settings", F_BIG, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    if (g_running[g_sel]) text(R(MX, 64, MW, 18), L"The game is running - changes apply next time you start it.", F_SMALL, C_WARN, DT_LEFT | DT_SINGLELINE);

    // keys
    int y = 92;
    RECT kc = R(MX, y, 300, 254);   // keys card: left column, 300 wide
    fill(kc, C_CARD, 14);
    text(R(MX + 18, y + 14, 260, 18), L"KEYS", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    for (int i = 0; i < (int)c.keys.size(); i++) {
        int ry = y + 40 + i * 44;
        text(R(MX + 18, ry, 170, 34), c.keys[i].label, F_SMALL, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        bool cap = g_capture == i;
        std::wstring lbl = cap ? L"press a key" : key_label(c.keys[i].value);
        button(MX + 190, ry, 92, 34, lbl, cap ? Btn::Primary : Btn::Secondary, [i] { g_capture = g_capture == i ? -1 : i; g_focus = {}; });
    }
    button(MX + 18, y + 218, 120, 26, L"Reset keys", Btn::Ghost, [] {
        Chapter& ch = cur();
        for (auto& k : ch.keys) k.value = k.def;
        apply_settings(ch); toast(L"Keys reset to F6 / F7 / O / P.");
    });
    text(R(MX + 146, y + 214, 150, 34), L"Click a key, then press the new one", F_SMALL, C_DIM);

    // sync options
    const int SX = MX + 312, SW = MW - 312;
    RECT sc = R(SX, y, SW, 446);
    fill(sc, C_CARD, 14);
    text(R(SX + 18, y + 14, SW - 36, 18), L"SHARED WITH YOUR ROOM", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    int row = 0;
    for (int i = 0; i < (int)c.sync.size(); i++) {
        SyncOpt& o = c.sync[i];
        if (!(o.chapters & (1 << (c.num - 1)))) continue;
        int ry = y + 40 + row * 46;
        RECT rr = R(SX + 8, ry - 3, SW - 16, 44);
        if (hover(rr)) fill(rr, C_CARD2, 8);
        text(R(SX + 18, ry, SW - 90, 18), o.label, F_SMALL, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        text(R(SX + 18, ry + 18, SW - 90, 18), o.hint, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        draw_toggle(SX + SW - 58, ry + 8, o.value);
        click(rr, [i] { Chapter& ch = cur(); ch.sync[i].value = !ch.sync[i].value; apply_settings(ch); });
        row++;
    }
    text(R(SX + 18, y + 412, SW - 36, 20), L"Use the same settings as your friends.", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);

    // folder + mod
    int my = y + 266;
    RECT mc = R(MX, my, 300, 180);
    fill(mc, C_CARD, 14);
    text(R(MX + 18, my + 14, 260, 18), L"CO-OP MOD", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    std::wstring iv = inst_ver(c);
    text(R(MX + 18, my + 34, 270, 18), iv.empty() ? L"Not installed" : L"v" + iv + (iv == MOD_VERSION ? L" installed" : L" (update ready)"), F_SMALL, iv.empty() ? C_WARN : C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX + 18, my + 54, 266, 18), c.dir, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_PATH_ELLIPSIS);
    my += 30;
    int idx = g_sel;
    button(MX + 18, my + 60, 128, 30, L"Reinstall", Btn::Secondary, [idx] {
        if (game_running(g_ch[idx])) { toast(L"Close the game first."); return; }
        start_install(idx, false);
    }, !g_installing);
    button(MX + 154, my + 60, 128, 30, g_confirm_uninstall ? L"Click to confirm" : L"Uninstall", g_confirm_uninstall ? Btn::Danger : Btn::Ghost, [idx] {
        Chapter& ch = g_ch[idx];
        if (!g_confirm_uninstall) { g_confirm_uninstall = true; return; }
        g_confirm_uninstall = false;
        if (game_running(ch)) { toast(L"Close the game first."); return; }
        bool ok = (DeleteFileW((bin_dir(ch) + L"\\dwmapi.dll").c_str()) || !file_exists(bin_dir(ch) + L"\\dwmapi.dll"));
        ok = delete_tree(mod_dir(ch)) && ok;
        iv_reset();
        toast(ok ? L"Co-op mod removed - your game is back to normal." : L"Couldn't remove everything - close the game or run the launcher as administrator.");
    }, !iv.empty() && !g_installing);
    button(MX + 18, my + 98, 128, 30, L"Change folder", Btn::Ghost, [idx] { browse_folder(g_ch[idx]); });
    button(MX + 154, my + 98, 128, 30, L"Open folder", Btn::Ghost, [idx] {
        Chapter& ch = g_ch[idx];
        std::wstring d = dir_exists(mod_dir(ch)) ? mod_dir(ch) : ch.dir;
        ShellExecuteW(nullptr, L"open", d.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    });
    (void)h;
}

// ------------------------------------------------------------------ profile page
static void draw_profile(int h) {
    button(MX, 26, 96, 32, L"\x2039  Back", Btn::Ghost, [] {
        std::wstring n = clean_name(g_edit_name);
        if (!n.empty()) g_prof.name = n;
        save_profile(); g_page = Page::Chapter; g_focus = {};
    });
    text(R(MX + 112, 28, MW - 112, 30), L"Name & colour", F_BIG, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    RECT card = R(MX, 84, MW, 250);
    fill(card, C_CARD, 14);
    text(R(MX + 24, 104, 400, 18), L"PLAYER NAME", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    textbox(MX + 24, 126, 320, 44, &g_edit_name, 24, false, L"Your name", F_BIG);
    text(R(MX + 24, 178, MW - 48, 20), L"Your name floats above your figure in everyone else's game. Letters, numbers, _ and - only.", F_SMALL, C_DIM);
    text(R(MX + 24, 214, 400, 18), L"FIGURE COLOUR", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    draw_colors(MX + 24, 238);
    for (auto& c : COLORS) if (g_prof.color == c.id) text(R(MX + 24, 284, 300, 20), std::wstring(c.label) + L" - your figure's colour in other players' games", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    button(MX + MW - 160, 346, 160, 42, L"Done", Btn::Primary, [] {
        std::wstring n = clean_name(g_edit_name);
        if (n.empty()) { toast(L"Type a name first."); return; }
        g_prof.name = n; save_profile(); g_page = Page::Chapter; g_focus = {};
        for (auto& ch : g_ch) if (!inst_ver(ch).empty()) write_mod_settings(ch, g_prof);
    });
    (void)h;
}

// ------------------------------------------------------------------ launcher settings page (colours, animations)
static void save_app_prefs() {
    ini_set(L"Launcher", L"Theme", g_theme);
    ini_set(L"Launcher", L"Accent", g_accent_pref);
    ini_set(L"Launcher", L"Animations", g_anims ? L"1" : L"0");
}

static void draw_app(int h) {
    text(R(MX, 28, MW, 18), L"LAUNCHER", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW, 40), L"Launcher settings", F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX, 92, MW, 20), L"How the launcher looks. This doesn't change anything in the game.", F_BODY, C_DIM, DT_LEFT | DT_SINGLELINE);

    // themes: a small preview of each
    text(R(MX, 130, MW, 18), L"THEME", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    int cw = (MW - 32) / 3;
    for (int i = 0; i < 3; i++) {
        const Theme& t = THEMES[i];
        int x = MX + i * (cw + 16);
        RECT r = R(x, 152, cw, 132);
        bool sel = g_theme == t.id;
        double ht = anim(akey(20, i, 0), hover(r) ? 1.0 : 0.0, 16), st = anim(akey(21, i, 0), sel ? 1.0 : 0.0, 14);
        fill(r, mix(C_CARD, C_CARD2, ht), 12);
        fill(R(x + 12, 164, cw - 24, 80), t.bg, 8);                        // mini window
        fill(R(x + 12, 164, 46, 80), t.side, 8);
        fill(R(x + 20, 176, 30, 6), t.text, 3);
        fill(R(x + 20, 190, 24, 5), t.dim, 2);
        fill(R(x + 66, 176, cw - 92, 26), t.card, 6);
        fill(R(x + 74, 184, 50, 6), t.text, 3);
        fill(R(x + cw - 74, 222, 50, 14), target_accent(), 7);
        text(R(x + 14, 252, cw - 28, 22), t.label, F_BOLD, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        if (st > 0.02) { frame(r, mix(C_CARD, accent(), st), 12, 2); circle(x + cw - 22, 263, 7, mix(C_CARD, accent(), st)); }
        std::wstring id = t.id;
        click(r, [id] { g_theme = id; apply_theme(); save_app_prefs(); });
    }

    // accent colour
    text(R(MX, 306, MW, 18), L"ACCENT COLOUR", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    {
        RECT r = R(MX, 328, 196, 40);
        bool sel = g_accent_pref == L"figure";
        double ht = anim(akey(22, 0, 0), hover(r) ? 1.0 : 0.0, 16), st = anim(akey(23, 0, 0), sel ? 1.0 : 0.0, 14);
        fill(r, mix(C_CARD, C_CARD2, ht), 20);
        if (st > 0.02) frame(r, mix(C_CARD, accent(), st), 20, 2);
        circle(MX + 22, 348, 9, player_rgb(g_prof.color));
        text(R(MX + 40, 328, 150, 40), L"My figure colour", F_SMALL, C_TEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        click(r, [] { g_accent_pref = L"figure"; save_app_prefs(); });
    }
    for (int i = 0; i < 7; i++) {
        int cx = MX + 232 + i * 46;
        RECT r = R(cx - 18, 330, 36, 36);
        bool sel = g_accent_pref == COLORS[i].id;
        double st = anim(akey(24, i, 0), sel ? 1.0 : 0.0, 16), ht = anim(akey(25, i, 0), hover(r) ? 1.0 : 0.0, 16);
        if (st > 0.02) { circle(cx, 348, 12 + (int)(6 * st + 0.5), mix(C_BG, C_TEXT, st)); circle(cx, 348, 12 + (int)(3 * st + 0.5), C_BG); }
        else if (ht > 0.02) circle(cx, 348, 12 + (int)(5 * ht + 0.5), mix(C_BG, C_LINE, ht));
        circle(cx, 348, 12, COLORS[i].rgb);
        std::wstring id = COLORS[i].id;
        click(r, [id] { g_accent_pref = id; save_app_prefs(); });
    }
    text(R(MX, 376, MW, 20), L"\"My figure colour\" follows the colour you play with (Name & colour).", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);

    // animations
    RECT ar = R(MX, 414, MW, 60);
    fill(ar, mix(C_CARD, C_CARD2, anim(akey(26, 0, 0), hover(ar) ? 1.0 : 0.0, 16)), 12);
    text(R(MX + 18, 422, MW - 100, 20), L"Animations", F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE);
    text(R(MX + 18, 444, MW - 100, 20), L"Smooth fades and movements. Turn off on very slow PCs.", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    draw_toggle(MX + MW - 60, 433, g_anims);
    click(ar, [] { g_anims = !g_anims; save_app_prefs(); });
    (void)h;
}

// ------------------------------------------------------------------ servers page
static void select_server(int i) {
    g_srv = i;
    apply_server();
    save_servers();
    if (!trim(g_prof.name).empty())
        for (auto& ch : g_ch) if (playable(ch) && !inst_ver(ch).empty()) write_mod_settings(ch, g_prof);
    if (!probe_of(g_servers[i])) start_probe(false);
}

static void draw_servers(int h) {
    text(R(MX, 28, MW, 18), L"SERVERS", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    text(R(MX, 46, MW - 160, 40), L"Server & connection", F_H1, C_TEXT, DT_LEFT | DT_SINGLELINE);
    button(MX + MW - 130, 50, 130, 36, g_probing ? L"Testing..." : L"Test again", Btn::Ghost, [] { start_probe(true); }, !g_probing);
    text(R(MX, 92, MW, 20), L"Everyone you play with has to pick the same server.", F_BODY, C_DIM, DT_LEFT | DT_SINGLELINE);

    for (int i = 0; i < (int)g_servers.size(); i++) {
        const Server& v = g_servers[i];
        int y = 124 + i * 66;
        RECT r = R(MX, y, MW, 58);
        bool sel = i == g_srv;
        double ht = anim(akey(40, i, 0), hover(r) ? 1.0 : 0.0, 16), st = anim(akey(41, i, 0), sel ? 1.0 : 0.0, 14);
        fill(r, mix(C_CARD, C_CARD2, ht * 0.7), 12);
        if (st > 0.02) frame(r, mix(C_CARD, accent(), st), 12, 2);
        // radio
        circle(MX + 24, y + 29, 9, mix(C_LINE, accent(), st));
        circle(MX + 24, y + 29, 7, C_CARD);
        if (st > 0.02) circle(MX + 24, y + 29, (int)(4 * st + 0.5), accent());
        text(R(MX + 44, y + 9, 300, 20), v.name, F_BOLD, C_TEXT, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        std::wstring sub;
        if (v.kind == SrvKind::Relay && v.builtin) sub = L"Free relay (Cloudflare), nearest datacenter automatically";
        else if (v.kind == SrvKind::Relay) sub = L"Relay  \x00B7  " + v.addr;
        else if (v.kind == SrvKind::Host) sub = L"Your IP " + (g_lan.empty() ? std::wstring(L"(see your router)") : g_lan) + L"  \x00B7  UDP port 27777 open";
        else sub = L"Friend who hosts  \x00B7  " + v.addr + L":" + std::to_wstring(v.port);
        int right = v.builtin ? MW - 16 : MW - 50;
        text(R(MX + 44, y + 30, right - 260, 18), sub, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        // connection quality
        const Probe* p = probe_of(v);
        int qx = MX + right - 200;
        if (v.kind == SrvKind::Host) {
            text(R(qx + 34, y + 9, 166, 20), L"You are the server", F_SMALL, C_TEXT, DT_LEFT | DT_SINGLELINE);
            text(R(qx + 34, y + 29, 166, 18), L"friends connect to you", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
        } else {
            signal_bars(qx, y + 18, p, akey(42, i, 0));
            COLORREF qc = p && p->done ? quality_color(quality(*p)) : C_DIM;
            text(R(qx + 34, y + 9, 166, 20), probe_text(v, p), F_SMALL, qc == C_DIM ? C_TEXT : qc, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
            std::wstring det;
            if (p && p->done && p->ms >= 0) {
                det = L"jitter " + std::to_wstring(p->jitter) + L" ms  \x00B7  " + std::to_wstring(p->loss) + L"% loss";
                if (!p->colo.empty()) det += L"  \x00B7  " + p->colo;
            }
            text(R(qx + 34, y + 29, 170, 18), det, F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
        click(r, [i] { select_server(i); });
        if (!v.builtin) {
            bool conf = g_confirm_remove == i;
            button(MX + MW - 42, y + 15, conf ? 34 : 28, 28, conf ? L"OK?" : L"x", conf ? Btn::Danger : Btn::Ghost, [i] {
                if (g_confirm_remove != i) { g_confirm_remove = i; return; }
                g_confirm_remove = -1;
                g_servers.erase(g_servers.begin() + i);
                if (g_srv == i) g_srv = 0; else if (g_srv > i) g_srv--;
                apply_server(); save_servers();
                if (!trim(g_prof.name).empty())
                    for (auto& ch : g_ch) if (playable(ch) && !inst_ver(ch).empty()) write_mod_settings(ch, g_prof);
            });
        }
    }

    // add a server
    int y = 124 + (int)g_servers.size() * 66 + 6;
    bool full = g_servers.size() >= 5;
    RECT card = R(MX, y, MW, 104);
    fill(card, C_CARD, 12);
    text(R(MX + 16, y + 10, 300, 18), full ? L"ADD A SERVER (remove one first - 3 at most)" : L"ADD A SERVER", F_SMALL, acc_text(), DT_LEFT | DT_SINGLELINE);
    textbox(MX + 16, y + 32, 170, 40, &g_new_name, 24, false, L"Name", F_SMALL);
    textbox(MX + 196, y + 32, MW - 330, 40, &g_new_addr, 120, false, L"wss://... or IP of a friend who hosts", F_SMALL);
    button(MX + MW - 120, y + 32, 104, 40, L"Add", Btn::Primary, [] {
        Server v;
        if (!parse_server(g_new_addr, v)) { toast(L"That doesn't look like a server address."); return; }
        v.name = trim(g_new_name).empty() ? v.addr : trim(g_new_name);
        v.builtin = false;
        for (auto& o : g_servers) if (srv_key(o) == srv_key(v)) { toast(L"That server is already in the list."); return; }
        g_servers.push_back(v);
        g_new_name.clear(); g_new_addr.clear(); g_focus = {};
        select_server((int)g_servers.size() - 1);
        start_probe(true);
        toast(L"Added " + v.name + L" - testing the connection...");
    }, !full && !trim(g_new_addr).empty());
    text(R(MX + 16, y + 78, MW - 32, 18), L"A relay address (wss://...) or a friend's IP, e.g. 203.0.113.5 or 203.0.113.5:27777", F_SMALL, C_DIM, DT_LEFT | DT_SINGLELINE);
    (void)h;
}

// ------------------------------------------------------------------ paint
// Page / chapter / theme changes cross-fade: the previous frame is kept and blended out over the new one.
static HBITMAP g_last_bmp = nullptr, g_fade_bmp = nullptr;
static int g_bmp_w = 0, g_bmp_h = 0;
static ULONGLONG g_fade_t0 = 0;
static bool g_fade_full = false;
static long long g_last_sig = -1;
static const double FADE_MS = 230.0;

static int theme_index() { for (int i = 0; i < 3; i++) if (g_theme == THEMES[i].id) return i; return 0; }

static void paint(HDC wdc, int w, int h) {
    ULONGLONG now = GetTickCount64();
    g_dt = g_frame_ms ? std::min(0.05, (now - g_frame_ms) / 1000.0) : 0.0;
    g_frame_ms = now;
    g_moving = false;

    HDC dc = CreateCompatibleDC(wdc);
    HBITMAP bmp = CreateCompatibleBitmap(wdc, w, h);
    HGDIOBJ old = SelectObject(dc, bmp);
    g_dc = dc;
    SetBkMode(dc, TRANSPARENT);
    g_hits.clear();
    RECT all = { 0, 0, w, h };
    fill(all, C_BG);
    int lh = (int)(h / g_s);
    draw_sidebar(lh);
    g_view = 0;
    if (g_page == Page::Settings && playable(cur())) draw_settings(lh);
    else if (g_page == Page::Profile) draw_profile(lh);
    else if (g_page == Page::Welcome) draw_welcome(lh);
    else if (g_page == Page::App) draw_app(lh);
    else if (g_page == Page::Servers) draw_servers(lh);
    else draw_chapter(lh);

    // toast: fades and slides in, fades out
    bool tv = !g_toast.empty() && now < g_toast_until;
    double ta = anim(akey(5, 0, 0), tv ? 1.0 : 0.0, 12);
    if (ta > 0.01 && !g_toast.empty()) {
        int tw = text_w(g_toast, F_SMALL) + 36;
        RECT r = R(MX + (MW - tw) / 2, lh - 150 + (int)((1 - ta) * 12), tw, 34);
        fill(r, mix(C_BG, C_CARD2, ta), 17);
        text(r, g_toast, F_SMALL, mix(C_BG, C_TEXT, ta), DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    text(R(MX, lh - 26, MW, 18), L"Fan-made co-op mod. Not affiliated with Mob Entertainment.  \x00B7  Launcher " LAUNCHER_VERSION L"  \x00B7  mod v" MOD_VERSION,
         F_SMALL, mix(C_DIM, C_BG, 0.35), DT_LEFT | DT_SINGLELINE);

    // cross-fade
    long long sig = theme_index() * 100000LL + (long long)g_page * 1000 + g_sel * 10 + g_view;
    if (w != g_bmp_w || h != g_bmp_h) {
        if (g_last_bmp) DeleteObject(g_last_bmp);
        if (g_fade_bmp) { DeleteObject(g_fade_bmp); g_fade_bmp = nullptr; }
        g_last_bmp = CreateCompatibleBitmap(wdc, w, h); g_bmp_w = w; g_bmp_h = h; g_last_sig = -1;
    }
    HDC tmp = CreateCompatibleDC(wdc);
    if (g_last_sig != -1 && sig != g_last_sig && g_anims) {
        if (!g_fade_bmp) g_fade_bmp = CreateCompatibleBitmap(wdc, w, h);
        HDC fd = CreateCompatibleDC(wdc);
        HGDIOBJ o1 = SelectObject(fd, g_fade_bmp), o2 = SelectObject(tmp, g_last_bmp);
        BitBlt(fd, 0, 0, w, h, tmp, 0, 0, SRCCOPY);
        SelectObject(fd, o1); SelectObject(tmp, o2); DeleteDC(fd);
        g_fade_full = sig / 100000 != g_last_sig / 100000;   // theme change: whole window
        g_fade_t0 = now;
    }
    g_last_sig = sig;
    HGDIOBJ o = SelectObject(tmp, g_last_bmp);
    BitBlt(tmp, 0, 0, w, h, dc, 0, 0, SRCCOPY);                // the clean frame, for the next fade
    SelectObject(tmp, o);
    if (g_fade_bmp) {
        double t = ease((now - g_fade_t0) / FADE_MS);
        if (t >= 1) { DeleteObject(g_fade_bmp); g_fade_bmp = nullptr; }
        else {
            int x0 = g_fade_full ? 0 : S(284);
            HGDIOBJ o3 = SelectObject(tmp, g_fade_bmp);
            BLENDFUNCTION bf = { AC_SRC_OVER, 0, (BYTE)(255 * (1 - t)), 0 };
            AlphaBlend(dc, x0, 0, w - x0, h, tmp, x0, 0, w - x0, h, bf);
            SelectObject(tmp, o3);
            g_moving = true;
        }
    }
    DeleteDC(tmp);

    BitBlt(wdc, 0, 0, w, h, dc, 0, 0, SRCCOPY);
    SelectObject(dc, old);
    DeleteObject(bmp);
    DeleteDC(dc);
    if (g_moving) SetTimer(g_wnd, TIMER_ANIM, 15, nullptr); else KillTimer(g_wnd, TIMER_ANIM);
}

// ------------------------------------------------------------------ install / play
static void start_install(int ch, bool then_launch) {
    if (g_installing.exchange(true)) return;
    g_install_ch = ch; g_install_pct = 0; g_launch_after_install = then_launch;
    for (auto& a : g_anim) if (a.first == akey(6, 0, 0)) a.second = 0;
    Chapter c = g_ch[ch];         // copy for the worker
    Profile p = g_prof;
    p.name = clean_name(p.name);
    HWND w = g_wnd;
    std::thread([c, p, w] {
        auto items = install_items();
        size_t total = 0, done = 0;
        std::vector<std::pair<const void*, DWORD>> data;
        for (auto& it : items) {
            const void* d = nullptr; DWORD n = 0;
            if (!load_res(it.res, &d, &n)) { PostMessageW(w, WM_APP_INSTALLED, 0, 0); return; }
            data.push_back({ d, n }); total += n;
        }
        bool ok = true;
        std::wstring base = bin_dir(c);
        for (size_t i = 0; i < items.size() && ok; i++) {
            std::wstring path = base + L"\\" + items[i].rel;
            if (!(items[i].keep_existing && file_exists(path))) ok = write_file(path, data[i].first, data[i].second);
            done += data[i].second;
            PostMessageW(w, WM_APP_PROGRESS, (WPARAM)(done * 100 / (total ? total : 1)), 0);
        }
        if (ok) ok = write_mod_settings(c, p);
        if (ok) ok = write_text(mod_dir(c) + L"\\version.txt", MOD_VERSION);
        PostMessageW(w, WM_APP_INSTALLED, ok ? 1 : 0, 0);
    }).detach();
}

static void launch_now(int idx) {
    Chapter& c = g_ch[idx];
    if (!write_mod_settings(c, g_prof)) { toast(L"Couldn't save the mod settings - try running the launcher as administrator."); return; }
    if (!launch_game(c)) { toast(L"Couldn't start the game."); return; }
    g_starting_ch = idx; g_starting_t0 = GetTickCount64();
    toast(via_steam(c) ? L"Starting Poppy Playtime - Steam may take a few seconds" : L"Starting Poppy Playtime...");
}

static void do_play() {
    Chapter& c = cur();
    g_focus = {};
    if (game_running(c)) { toast(L"The game is already running - close it to switch rooms."); return; }
    if (g_prof.tab == 2 && extract_code(g_prof.join_code).empty()) { toast(L"Type your friend's room code first."); g_focus = { &g_prof.join_code, 12, true }; return; }
    if (g_prof.tab == 2) g_prof.join_code = extract_code(g_prof.join_code);
    save_profile();
    if (inst_ver(c) != MOD_VERSION) { start_install(g_sel, true); return; }
    launch_now(g_sel);
}

// ------------------------------------------------------------------ invite handling
static void open_invite(const std::wstring& arg) {
    if (lower(arg).find(L"poppycoop://") == std::wstring::npos) return;
    std::wstring code = extract_code(arg);
    if (code.empty()) return;
    g_prof.join_code = code; g_prof.tab = 2; g_page = Page::Chapter;
    save_profile();
    toast(L"Invite opened - room " + code + L". Pick the chapter and press PLAY!");
}

// ------------------------------------------------------------------ window
static bool g_test = false;
static void test_tick(HWND h);
static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        paint(dc, rc.right, rc.bottom);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_ERASEBKGND: return 1;
    case WM_MOUSEMOVE: {
        g_mouse = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
        TRACKMOUSEEVENT t = { sizeof(t), TME_LEAVE, h, 0 }; TrackMouseEvent(&t);
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_MOUSELEAVE: g_mouse = { -1, -1 }; InvalidateRect(h, nullptr, FALSE); return 0;
    case WM_SETCURSOR:
        if (LOWORD(lp) == HTCLIENT) {
            for (auto& hit : g_hits) if (hover(hit.r)) { SetCursor(LoadCursor(nullptr, IDC_HAND)); return TRUE; }
            SetCursor(LoadCursor(nullptr, IDC_ARROW)); return TRUE;
        }
        break;
    case WM_LBUTTONDOWN: {
        g_mouse = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
        g_pressed = -1;
        for (int i = (int)g_hits.size() - 1; i >= 0; i--) if (hover(g_hits[i].r)) { g_pressed = i; break; }
        if (g_pressed < 0) { g_focus = {}; g_capture = -1; }
        SetCapture(h);
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_LBUTTONUP: {
        ReleaseCapture();
        g_mouse = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
        if (g_pressed >= 0 && g_pressed < (int)g_hits.size() && hover(g_hits[g_pressed].r)) {
            auto fn = g_hits[g_pressed].fn;   // copy: the handler may change the page
            fn();
        }
        g_pressed = -1;
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_KEYDOWN: case WM_SYSKEYDOWN:
        if (g_capture >= 0) { set_key((UINT)wp); InvalidateRect(h, nullptr, FALSE); return 0; }
        if (g_focus.value && wp == 'V' && (GetKeyState(VK_CONTROL) & 0x8000)) {
            std::wstring t = clipboard_text();
            if (g_focus.code) t = extract_code(t);
            for (wchar_t ch : t) if (g_focus.value->size() < g_focus.max && ch >= 32) *g_focus.value += g_focus.code ? (wchar_t)towupper(ch) : ch;
            InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        if (g_focus.value && wp == VK_RETURN) {
            if (g_focus.value == &g_prof.join_code) do_play();
            g_focus = {}; InvalidateRect(h, nullptr, FALSE); return 0;
        }
        if (g_focus.value && wp == VK_ESCAPE) { g_focus = {}; InvalidateRect(h, nullptr, FALSE); return 0; }
        break;
    case WM_CHAR:
        if (g_focus.value && g_capture < 0) {
            wchar_t ch = (wchar_t)wp;
            std::wstring& v = *g_focus.value;
            if (ch == 8) { if (!v.empty()) v.pop_back(); }
            else if (ch >= 32 && ch != 127 && v.size() < g_focus.max && !(GetKeyState(VK_CONTROL) & 0x8000)) {
                if (g_focus.code) { if (iswalnum(ch) && ch < 128) v += (wchar_t)towupper(ch); }
                else if (g_focus.value == &g_new_addr) { if (ch > 32 && ch < 127) v += ch; }   // server address: URL / IP
                else if ((iswalnum(ch) && ch < 128) || ch == L'_' || ch == L'-' || ch == L' ') v += ch;
            }
            if (g_focus.value == &g_prof.join_code || g_focus.value == &g_prof.name) save_profile();
            g_caret_on = true;
            InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        break;
    case WM_TIMER:
        if (wp == TIMER_ANIM) { InvalidateRect(h, nullptr, FALSE); return 0; }
        if (wp == TIMER_PROBE) { start_probe(g_page == Page::Servers); return 0; }
        if (wp == TIMER_CARET) { if (g_focus.value) { g_caret_on = !g_caret_on; InvalidateRect(h, nullptr, FALSE); } return 0; }
        if (wp == TIMER_POLL) {
            if (g_test) test_tick(h);
            bool changed = false;
            for (size_t i = 0; i < g_ch.size() && i < 8; i++) {
                bool r = game_running(g_ch[i]);
                if (r != g_running[i]) { g_running[i] = r; changed = true; }
            }
            if (g_starting_ch >= 0) {
                if (g_running[g_starting_ch]) {
                    toast(L"Have fun! Everyone loads the same checkpoint.");
                    g_starting_ch = -1;
                } else if (GetTickCount64() - g_starting_t0 > 45000) {
                    toast(L"The game didn't open yet - check Steam.");
                    g_starting_ch = -1;
                }
                changed = true;
            }
            ULONGLONG nw = GetTickCount64();
            if (!g_toast.empty() && nw > g_toast_until + 1500) g_toast.clear();   // after its fade-out
            if (changed || (!g_toast.empty() && nw > g_toast_until)) InvalidateRect(h, nullptr, FALSE);
            return 0;
        }
        break;
    case WM_APP_PROGRESS: g_install_pct = (int)wp; InvalidateRect(h, nullptr, FALSE); return 0;
    case WM_APP_INSTALLED: {
        g_installing = false;
        int idx = g_install_ch;
        iv_reset();
        if (wp && idx >= 0) { ini_set(sec_name(g_ch[idx]).c_str(), L"SetupDone", L"1"); g_setup_done[(g_ch[idx].num - 1) & 7] = 1; }
        if (!wp) { toast(L"Install failed - close the game, or run the launcher as administrator."); g_launch_after_install = false; }
        else {
            toast(L"Co-op mod v" MOD_VERSION L" installed.");
            if (g_launch_after_install && idx >= 0) launch_now(idx);
        }
        g_launch_after_install = false;
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_APP_PROBE: {
        if (lp) {
            ProbeResult* r = (ProbeResult*)lp;
            bool found = false;
            for (auto& p : g_probes) if (p.first == r->key) { p.second = r->p; found = true; }
            if (!found) g_probes.push_back({ r->key, r->p });
            delete r;
        }
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_COPYDATA: {
        COPYDATASTRUCT* cd = (COPYDATASTRUCT*)lp;
        if (cd && cd->lpData && cd->cbData >= 2) open_invite(std::wstring((const wchar_t*)cd->lpData, cd->cbData / 2));
        if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
        SetForegroundWindow(h);
        InvalidateRect(h, nullptr, FALSE);
        return TRUE;
    }
    case WM_DESTROY: save_profile(); PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(h, m, wp, lp);
}

// Developer test hook (POPPYCOOP_LAUNCHER_TEST=1): reads launcher_test.txt next to the exe once a second and
// replays it - "click X Y" (client coordinates at 96 dpi), "key VK", "type TEXT". Off for normal players.
static void test_tick(HWND h) {
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring f = parent(exe) + L"\\launcher_test.txt";
    std::string cmds;
    if (!read_file(f, cmds)) return;
    DeleteFileW(f.c_str());
    size_t p = 0;
    while (p < cmds.size()) {
        size_t e = cmds.find('\n', p);
        std::string line = cmds.substr(p, e == std::string::npos ? std::string::npos : e - p);
        p = e == std::string::npos ? cmds.size() : e + 1;
        int x = 0, y = 0;
        if (sscanf(line.c_str(), "click %d %d", &x, &y) == 2) {
            LPARAM lp = MAKELPARAM(S(x), S(y));
            SendMessageW(h, WM_MOUSEMOVE, 0, lp);
            UpdateWindow(h);
            RECT rc; GetClientRect(h, &rc);
            HDC dc = GetDC(h); paint(dc, rc.right, rc.bottom); ReleaseDC(h, dc);   // rebuild click areas
            SendMessageW(h, WM_LBUTTONDOWN, MK_LBUTTON, lp);
            SendMessageW(h, WM_LBUTTONUP, 0, lp);
        } else if (sscanf(line.c_str(), "key %d", &x) == 1) {
            SendMessageW(h, WM_KEYDOWN, (WPARAM)x, 0);
        } else if (line.rfind("type ", 0) == 0) {
            for (wchar_t ch : wide(line.substr(5))) if (ch != L'\r') SendMessageW(h, WM_CHAR, ch, 0);
        }
    }
}


int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR cmd, int show) {
    std::wstring arg = cmd ? cmd : L"";
    // one launcher at a time: hand an invite link to the running one
    HANDLE mtx = CreateMutexW(nullptr, TRUE, L"PoppyCoopLauncherSingleInstance");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND other = FindWindowW(L"PoppyCoopLauncher3", nullptr);
        if (other) {
            COPYDATASTRUCT cd = { 1, (DWORD)((arg.size() + 1) * 2), (void*)arg.c_str() };
            SendMessageW(other, WM_COPYDATA, 0, (LPARAM)&cd);
            SetForegroundWindow(other);
        }
        return 0;
    }
    // sharp text on high-DPI screens
    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    auto ctx = (BOOL(WINAPI*)(HANDLE))GetProcAddress(u32, "SetProcessDpiAwarenessContext");
    if (!ctx || !ctx((HANDLE)-4)) SetProcessDPIAware();
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    HDC sdc = GetDC(nullptr);
    g_s = GetDeviceCaps(sdc, LOGPIXELSX) / 96.0;
    ReleaseDC(nullptr, sdc);
    if (g_s < 1.0) g_s = 1.0;

    ini_init();
    chapters_init();
    for (auto& c : g_ch) chapter_load(c);
    g_prof.name = clean_name(ini_get(L"Launcher", L"Name"));
    g_prof.color = ini_get(L"Launcher", L"Color", L"yellow");
    g_prof.code = upper(ini_get(L"Launcher", L"Code"));
    g_prof.join_code = upper(ini_get(L"Launcher", L"JoinCode"));
    g_prof.tab = _wtoi(ini_get(L"Launcher", L"Tab", L"0").c_str());
    if (g_prof.tab < 0 || g_prof.tab > 2) g_prof.tab = 0;
    g_sel = _wtoi(ini_get(L"Launcher", L"Chapter", L"1").c_str()) - 1;
    if (g_sel < 0 || g_sel >= (int)g_ch.size() || !playable(g_ch[g_sel])) g_sel = 0;
    {
        bool any = false;
        for (auto& c : g_ch) if (playable(c) && !inst_ver(c).empty()) any = true;
        if (!any && ini_get(L"Launcher", L"Chapter").empty()) g_page = Page::Welcome;
    }
    {
        wchar_t tv[8] = {};
        g_test = GetEnvironmentVariableW(L"POPPYCOOP_LAUNCHER_TEST", tv, 8) > 0 && tv[0] == L'1';
    }
    register_protocol();
    g_theme = ini_get(L"Launcher", L"Theme", L"dark");
    g_accent_pref = ini_get(L"Launcher", L"Accent", L"figure");
    g_anims = ini_get(L"Launcher", L"Animations", L"1") != L"0";
    apply_theme();
    make_fonts();
    load_servers();
    apply_server();
    g_lan = lan_ips();

    WNDCLASSEXW wc = { sizeof(wc) };
    wc.lpfnWndProc = wndproc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    wc.hIconSm = wc.hIcon;
    wc.lpszClassName = L"PoppyCoopLauncher3";
    RegisterClassExW(&wc);
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT r = { 0, 0, S(980), S(640) };
    AdjustWindowRect(&r, style, FALSE);
    g_wnd = CreateWindowExW(0, wc.lpszClassName, L"Poppy Playtime Co-op", style, CW_USEDEFAULT, CW_USEDEFAULT,
                            r.right - r.left, r.bottom - r.top, nullptr, nullptr, inst, nullptr);
    // dark title bar (Windows 10 20H1+ / 11); ignored elsewhere
    if (HMODULE dwm = LoadLibraryW(L"dwmapi.dll")) {
        auto set = (HRESULT(WINAPI*)(HWND, DWORD, LPCVOID, DWORD))GetProcAddress(dwm, "DwmSetWindowAttribute");
        BOOL on = TRUE;
        if (set) set(g_wnd, 20, &on, sizeof(on));
    }
    for (size_t i = 0; i < g_ch.size() && i < 8; i++) g_running[i] = game_running(g_ch[i]);
    open_invite(arg);
    ShowWindow(g_wnd, show);
    UpdateWindow(g_wnd);
    SetTimer(g_wnd, TIMER_POLL, 1000, nullptr);
    SetTimer(g_wnd, TIMER_CARET, 530, nullptr);
    start_probe(false);
    SetTimer(g_wnd, TIMER_PROBE, 30000, nullptr);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    if (mtx) CloseHandle(mtx);
    return 0;
}
