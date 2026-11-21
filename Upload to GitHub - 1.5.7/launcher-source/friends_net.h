// friends_net.h - the friends server (tools/api-worker, Cloudflare Worker "poppycoop-api" with a D1 database).
//
// Account: a random id (16 hex) + secret (32 hex) made once and kept in launcher.ini; the server stores only a
// hash of the secret, so nobody else can act as this player. The friend code Name#12345 is just the visible
// name: when the number is taken on the server the launcher picks a new one.
// Every call is a POST with form fields; the answers are text lines (see friends.js):
//   OK ... / E <code> / F <code> <online> <chapter> <room|-> / I <code> / O <code>
// Network calls run in worker threads; results go back to the window as WM_APP_FRIENDS (a FriendsResult*).
#pragma once
#include "core.h"
#include "friends.h"

#define API_HOST L"poppycoop-api.poppycoopnet.workers.dev"

struct NetFriend {
    std::wstring code;      // Name#12345
    bool online = false;
    int chapter = 0;        // 0 = not in a game
    std::wstring room;      // their room while in a game ("" = none)
};
struct FriendsResult {
    bool reachable = false;          // the server answered at all
    std::string error;               // E code of the action (empty = ok)
    std::string action;              // "list", "request", "respond", "remove", "hello"
    std::string ok_word;             // word after OK ("friends", "requested", ...)
    bool has_list = false;
    std::vector<NetFriend> friends;
    std::vector<std::wstring> incoming, outgoing;
};

static std::wstring random_hex(size_t n) {
    static const wchar_t* HEX = L"0123456789abcdef";
    std::random_device rd;
    std::wstring s;
    while (s.size() < n) {
        unsigned v = rd();
        for (int i = 0; i < 8 && s.size() < n; i++, v >>= 4) s += HEX[v & 15];
    }
    return s;
}
static bool is_hex(const std::wstring& s, size_t n) {
    if (s.size() != n) return false;
    for (wchar_t c : s) if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f'))) return false;
    return true;
}
struct Account { std::wstring id, secret; };
static Account account() {
    static Account a;
    if (!a.id.empty()) return a;
    a.id = ini_get(L"Launcher", L"AccountId", L"");
    a.secret = ini_get(L"Launcher", L"AccountSecret", L"");
    if (!is_hex(a.id, 16) || !is_hex(a.secret, 32)) {
        a.id = random_hex(16);
        a.secret = random_hex(32);
        ini_set(L"Launcher", L"AccountId", a.id);
        ini_set(L"Launcher", L"AccountSecret", a.secret);
    }
    return a;
}

static std::string url_encode(const std::string& s) {
    static const char* HEX = "0123456789ABCDEF";
    std::string o;
    for (unsigned char c : s) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') o += (char)c;
        else { o += '%'; o += HEX[c >> 4]; o += HEX[c & 15]; }
    }
    return o;
}

// one POST to the friends server; false = not reachable. body gets the answer text.
static bool api_post(const wchar_t* path, const std::vector<std::pair<std::string, std::string>>& fields, std::string& body) {
    std::string data = "_=1";
    for (auto& f : fields) data += "&" + f.first + "=" + url_encode(f.second);
    Account a = account();
    std::wstring hdr = L"Content-Type: application/x-www-form-urlencoded\r\nX-Account: " + a.id + L"\r\nX-Secret: " + a.secret + L"\r\n";
    bool ok = false;
    HINTERNET s = WinHttpOpen(L"PoppyCoopLauncher/" LAUNCHER_VERSION, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nullptr, nullptr, 0);
    if (!s) return false;
    WinHttpSetTimeouts(s, 6000, 6000, 8000, 8000);
    // developer test against a local `wrangler dev`: POPPYCOOP_API_TEST=127.0.0.1:8787 (plain http)
    wchar_t test[64] = {};
    bool local = GetEnvironmentVariableW(L"POPPYCOOP_API_TEST", test, 64) > 0;
    std::wstring host = API_HOST;
    INTERNET_PORT port = INTERNET_DEFAULT_HTTPS_PORT;
    if (local) {
        std::wstring t = test;
        size_t colon = t.find(L':');
        host = t.substr(0, colon);
        port = colon == std::wstring::npos ? 80 : (INTERNET_PORT)_wtoi(t.c_str() + colon + 1);
    }
    HINTERNET c = WinHttpConnect(s, host.c_str(), port, 0);
    HINTERNET q = c ? WinHttpOpenRequest(c, L"POST", path, nullptr, nullptr, nullptr, local ? 0 : WINHTTP_FLAG_SECURE) : nullptr;
    if (q && WinHttpSendRequest(q, hdr.c_str(), (DWORD)-1L, (LPVOID)data.data(), (DWORD)data.size(), (DWORD)data.size(), 0)
          && WinHttpReceiveResponse(q, nullptr)) {
        char buf[4096];
        DWORD n = 0;
        body.clear();
        while (body.size() < 256 * 1024 && WinHttpReadData(q, buf, sizeof buf, &n) && n > 0) body.append(buf, n);
        ok = body.rfind("OK", 0) == 0 || body.rfind("E ", 0) == 0;     // our worker answered (not some 404 page)
    }
    if (q) WinHttpCloseHandle(q);
    if (c) WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    return ok;
}

static std::vector<std::string> split_lines(const std::string& s) {
    std::vector<std::string> out;
    size_t p = 0;
    while (p < s.size()) {
        size_t e = s.find('\n', p);
        if (e == std::string::npos) e = s.size();
        std::string l = s.substr(p, e - p);
        if (!l.empty() && l.back() == '\r') l.pop_back();
        if (!l.empty()) out.push_back(l);
        p = e + 1;
    }
    return out;
}
// fills r from an answer: first line OK.../E ..., then F/I/O lines
static void parse_answer(const std::string& body, FriendsResult& r) {
    auto lines = split_lines(body);
    if (lines.empty()) { r.error = "empty"; return; }
    if (lines[0].rfind("E ", 0) == 0) { r.error = lines[0].substr(2); return; }
    r.ok_word = lines[0].size() > 3 ? lines[0].substr(3) : "";
    for (size_t i = 1; i < lines.size(); i++) {
        const std::string& l = lines[i];
        if (l.size() < 3) continue;
        std::wstring rest = wide(l.substr(2));
        if (l[0] == 'I') { r.has_list = true; r.incoming.push_back(rest); }
        else if (l[0] == 'O') { r.has_list = true; r.outgoing.push_back(rest); }
        else if (l[0] == 'F') {
            r.has_list = true;
            NetFriend f;
            std::wstring parts[4];
            int k = 0;
            for (wchar_t ch : rest) { if (ch == L' ' && k < 3) k++; else parts[k] += ch; }
            f.code = parts[0];
            f.online = parts[1] == L"1";
            f.chapter = _wtoi(parts[2].c_str());
            f.room = parts[3] == L"-" ? L"" : parts[3];
            r.friends.push_back(f);
        }
    }
}

// status sent with every hello: in a game (chapter + room) or just in the launcher
struct HelloInfo { std::wstring name, tag, room; int chapter = 0; bool ingame = false; };

// hello (register / update / heartbeat). A taken friend-code number gets a new one (returned in new_tag).
static FriendsResult api_hello(const HelloInfo& h, std::wstring& new_tag) {
    FriendsResult r;
    r.action = "hello";
    std::wstring tag = h.tag;
    for (int attempt = 0; attempt < 4; attempt++) {
        std::string body;
        r.reachable = api_post(L"/v1/hello", { { "name", utf8(h.name) }, { "tag", utf8(tag) }, { "chapter", std::to_string(h.chapter) },
                                                 { "room", utf8(h.room) }, { "ingame", h.ingame ? "1" : "0" } }, body);
        if (!r.reachable) return r;
        r = FriendsResult(); r.action = "hello"; r.reachable = true;
        parse_answer(body, r);
        if (r.error != "tag_taken") break;
        std::random_device rd;
        tag = std::to_wstring(10000 + rd() % 90000);       // the number is taken: pick another one
        new_tag = tag;
    }
    return r;
}
static FriendsResult api_action(const char* action, const wchar_t* path, const std::vector<std::pair<std::string, std::string>>& fields) {
    FriendsResult r;
    r.action = action;
    std::string body;
    r.reachable = api_post(path, fields, body);
    if (r.reachable) parse_answer(body, r);
    return r;
}
