// logs.h - the "Logs" page of a chapter: the last game sessions (UE4SS.log of each start) and the game's crash reports.
//
// UE4SS overwrites UE4SS.log at every game start. The launcher therefore keeps a copy of each finished session in
// %APPDATA%\PoppyCoop\logs\Chapter<n>\session_<end time>.log (newest LOG_KEEP kept). A copy is made before the game
// is started, after it closed and when the Logs page is opened - the name comes from the log's last write time, so
// the same session is never stored twice. Crash report folders (%LOCALAPPDATA%\<Project>\Saved\Crashes\<id>\) are
// matched to the session they ended; crashes without a stored session (game started from Steam twice) are listed alone.
#pragma once
#include "core.h"
#include "crashreport.h"
#include <algorithm>

static const int LOG_KEEP = 15;                                  // stored sessions per chapter
static const ULONGLONG CRASH_MATCH = 180ULL * FT_SECOND;         // crash folder written up to 3 min after the log's end
static const ULONGLONG CRASH_LIST_AGE = 14ULL * 24 * 3600 * FT_SECOND;   // lone crashes older than 2 weeks are hidden
static const size_t LOG_TAIL_BYTES = 1024 * 1024;                // read from the end of a log for the preview (scrollable)
static const int LOG_PREVIEW_LINES = 8000;

struct LogEntry {
    std::wstring path;            // session log (empty: crash without a stored session)
    std::wstring crash_dir;       // matched crash report folder (with trailing backslash) or empty
    ULONGLONG end = 0;            // FILETIME (UTC): log's last write, or crash time
    ULONGLONG start = 0;          // FILETIME (UTC) from the log's first line, 0 = unknown
    bool running = false;         // the game is running right now (the current UE4SS.log)
    std::wstring version;         // "1.5.7" from "[PoppyCoop] v1.5.7 loaded"
    int errors = 0;               // Lua errors / tracebacks in the log
    std::string crash_msg;        // crash_summary() of the crash folder
    std::vector<std::string> tail;   // last lines (timestamps removed)
};

static std::wstring logs_root() {
    std::wstring d = g_ini;
    size_t p = d.find_last_of(L"\\/");
    d = p == std::wstring::npos ? L"." : d.substr(0, p);
    return d + L"\\logs";
}
static std::wstring logs_dir(const Chapter& c) { return logs_root() + L"\\Chapter" + std::to_wstring(c.num) + L"\\"; }

static std::wstring ft_local_string(ULONGLONG ft, const wchar_t* fmt) {
    FILETIME u = { (DWORD)ft, (DWORD)(ft >> 32) }, l;
    SYSTEMTIME s;
    if (!FileTimeToLocalFileTime(&u, &l) || !FileTimeToSystemTime(&l, &s)) return L"?";
    wchar_t b[64];
    if (wcscmp(fmt, L"file") == 0) swprintf(b, 64, L"%04d-%02d-%02d_%02d-%02d-%02d", s.wYear, s.wMonth, s.wDay, s.wHour, s.wMinute, s.wSecond);
    else swprintf(b, 64, L"%02d.%02d.%04d %02d:%02d", s.wDay, s.wMonth, s.wYear, s.wHour, s.wMinute);
    return b;
}

// "[2026-11-20 22:49:27.2044411] ..." (local time) -> FILETIME UTC, 0 if the line doesn't start like that
static ULONGLONG log_line_time(const std::string& line) {
    SYSTEMTIME s = {};
    int y, mo, d, h, mi, se;
    if (line.size() < 21 || line[0] != '[' || sscanf(line.c_str() + 1, "%4d-%2d-%2d %2d:%2d:%2d", &y, &mo, &d, &h, &mi, &se) != 6) return 0;
    s.wYear = (WORD)y; s.wMonth = (WORD)mo; s.wDay = (WORD)d; s.wHour = (WORD)h; s.wMinute = (WORD)mi; s.wSecond = (WORD)se;
    FILETIME l, u;
    if (!SystemTimeToFileTime(&s, &l) || !LocalFileTimeToFileTime(&l, &u)) return 0;
    return ft64(u);
}

// copies the chapter's finished UE4SS.log (and the older UE4SS_previous.log) into the log store, drops old ones
static void archive_logs(const Chapter& c) {
    if (c.dir.empty() || c.proj.empty()) return;
    std::wstring store = logs_dir(c);
    CreateDirectoryW(logs_root().c_str(), nullptr);
    CreateDirectoryW(store.c_str(), nullptr);
    std::wstring ue = bin_dir(c) + L"\\ue4ss\\";
    for (const wchar_t* f : { L"UE4SS_previous.log", L"UE4SS.log" }) {
        std::wstring src = ue + f;
        ULONGLONG t = file_time(src);
        if (!t) continue;
        std::wstring dst = store + L"session_" + ft_local_string(t, L"file") + L".log";
        if (!file_exists(dst)) CopyFileW(src.c_str(), dst.c_str(), TRUE);   // keeps the write time
    }
    // keep the newest LOG_KEEP (names sort by time)
    std::vector<std::wstring> names;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((store + L"session_*.log").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do names.push_back(fd.cFileName); while (FindNextFileW(h, &fd));
    FindClose(h);
    std::sort(names.begin(), names.end());
    for (size_t i = 0; i + LOG_KEEP < names.size(); i++) DeleteFileW((store + names[i]).c_str());
}

static std::vector<CrashInfo> all_crashes(const Chapter& ch) {
    std::vector<CrashInfo> out;
    wchar_t la[MAX_PATH];
    if (ch.proj.empty() || FAILED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, la))) return out;
    std::wstring crashes = std::wstring(la) + L"\\" + ch.proj + L"\\Saved\\Crashes\\";
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((crashes + L"*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return out;
    do {
        std::wstring n = fd.cFileName;
        if (n == L"." || n == L".." || !(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
        out.push_back({ crashes + n + L"\\", ft64(fd.ftLastWriteTime) });
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return out;
}

static std::string strip_log_time(const std::string& l) {
    if (l.size() > 2 && l[0] == '[') {
        size_t e = l.find("] ");
        if (e != std::string::npos && e < 32) return l.substr(e + 2);
    }
    return l;
}

// reads first line (start time), version, error count and the last lines of a session log
static void read_log_info(LogEntry& e) {
    std::string data;
    if (!read_file(e.path, data)) return;
    // session length from the first and last time stamp (same clock - under Proton that isn't always the PC's
    // time zone), start = file end time minus that length
    size_t nl = data.find('\n');
    ULONGLONG t0 = log_line_time(data.substr(0, nl == std::string::npos ? data.size() : nl)), t1 = 0;
    for (size_t q = data.size(); q > 0 && !t1 && data.size() - q < LOG_TAIL_BYTES; ) {
        size_t b = data.rfind('\n', q - 1);
        size_t ls = b == std::string::npos ? 0 : b + 1;
        t1 = log_line_time(data.substr(ls, q - ls));
        if (b == std::string::npos) break;
        q = b;
    }
    if (t0 && t1 >= t0) e.start = e.end > t1 - t0 ? e.end - (t1 - t0) : 0;
    size_t v = data.find("[PoppyCoop] v");
    if (v != std::string::npos) {
        size_t a = v + 13, b = a;
        while (b < data.size() && (isdigit((unsigned char)data[b]) || data[b] == '.')) b++;
        e.version = wide(data.substr(a, b - a));
    }
    for (size_t p = data.find("] Error"); p != std::string::npos; p = data.find("] Error", p + 1)) e.errors++;
    for (size_t p = data.find("stack traceback"); p != std::string::npos; p = data.find("stack traceback", p + 1)) e.errors++;
    size_t from = data.size() > LOG_TAIL_BYTES ? data.size() - LOG_TAIL_BYTES : 0;
    std::vector<std::string> lines;
    size_t p = from;
    while (p < data.size()) {
        size_t q = data.find('\n', p);
        std::string l = data.substr(p, q == std::string::npos ? std::string::npos : q - p);
        while (!l.empty() && (l.back() == '\r' || l.back() == ' ')) l.pop_back();
        for (size_t t = l.find('\t'); t != std::string::npos; t = l.find('\t', t)) l.replace(t, 1, "    ");
        if (!l.empty()) lines.push_back(strip_log_time(l));
        if (q == std::string::npos) break;
        p = q + 1;
    }
    if (from > 0 && !lines.empty()) lines.erase(lines.begin());         // cut in the middle of a line
    size_t n = std::min(lines.size(), (size_t)LOG_PREVIEW_LINES);
    e.tail.assign(lines.end() - n, lines.end());
}

// all entries of a chapter, newest first
static std::vector<LogEntry> scan_logs(const Chapter& c, bool running) {
    std::vector<LogEntry> out;
    if (!running) archive_logs(c);
    std::wstring store = logs_dir(c);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((store + L"session_*.log").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            LogEntry e;
            e.path = store + fd.cFileName;
            e.end = ft64(fd.ftLastWriteTime);
            out.push_back(e);
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    if (running) {                                    // the session that is being played: the live UE4SS.log
        LogEntry e;
        e.path = bin_dir(c) + L"\\ue4ss\\UE4SS.log";
        e.end = file_time(e.path);
        e.running = true;
        if (e.end) out.push_back(e);
    }
    std::sort(out.begin(), out.end(), [](const LogEntry& a, const LogEntry& b) { return a.end > b.end; });
    for (auto& e : out) read_log_info(e);
    // crash folders: to the session whose end is right before the crash, otherwise an entry of its own
    for (auto& ci : all_crashes(c)) {
        LogEntry* best = nullptr;
        for (auto& e : out) {
            if (e.running || !e.crash_dir.empty()) continue;
            bool after_start = !e.start || ci.time + 5 * FT_SECOND >= e.start;
            if (after_start && ci.time + 5 * FT_SECOND >= e.end && ci.time <= e.end + CRASH_MATCH && (!best || e.end > best->end)) best = &e;
        }
        std::string xml;
        read_file(ci.dir + L"CrashContext.runtime-xml", xml);
        std::string msg = xml.empty() ? std::string("(no crash details)") : crash_summary(xml);
        if (best) { best->crash_dir = ci.dir; best->crash_msg = msg; continue; }
        if (now_ft() - ci.time > CRASH_LIST_AGE) continue;
        LogEntry e;
        e.crash_dir = ci.dir;
        e.crash_msg = msg;
        e.end = ci.time;
        out.push_back(e);
    }
    std::sort(out.begin(), out.end(), [](const LogEntry& a, const LogEntry& b) { return a.running != b.running ? a.running : a.end > b.end; });
    return out;
}

// text for Discord (max ~1900 characters): versions, chapter, crash message, last log lines
static std::wstring log_report_text(const Chapter& c, const LogEntry& e) {
    std::string body;
    if (!e.crash_msg.empty()) body += "CRASH: " + e.crash_msg + "\n";
    std::string lines;
    for (auto& l : e.tail) lines += l + "\n";
    std::string head = "PoppyCoop log - Chapter " + std::to_string(c.num) + ", mod v" + utf8(e.version.empty() ? std::wstring(L"?") : e.version) +
                       ", launcher v" + utf8(MOD_VERSION) + ", " + utf8(ft_local_string(e.end, L"")) + (e.errors ? ", " + std::to_string(e.errors) + " errors" : "") + "\n";
    const size_t MAX = 1850;
    if (head.size() + body.size() > MAX) body = body.substr(0, MAX - head.size());
    size_t room = MAX - head.size() - body.size();
    if (lines.size() > room) lines = lines.substr(lines.size() - room);
    return wide(hide_user_names(head + body + "```\n" + lines + "```"));
}
