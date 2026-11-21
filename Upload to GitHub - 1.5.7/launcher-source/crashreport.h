// crashreport.h - automatic crash reports (only with the player's consent, launcher setting "Send crash reports").
//
// The game (Unreal) writes a crash report folder to %LOCALAPPDATA%\<Project>\Saved\Crashes\<id>\ when it crashes.
// After a game ends (and at launcher start) the newest such folder is looked at; a new one is sent once to the
// poppycoop-reports Cloudflare worker (tools/report-worker), which posts it into the developers' Discord channel.
// Sent: the crash message + call stack, the end of that session's UE4SS.log, mod version, chapter, Windows version.
// User names in paths ("C:\Users\Max\...", "Z:\home\max\...") are replaced by <user> before anything leaves the PC.
#pragma once
#include "core.h"

#define REPORT_HOST L"poppycoop-api.poppycoopnet.workers.dev"
#define REPORT_PATH L"/report"

static const size_t REPORT_LOG_TAIL = 1024 * 1024;           // end of UE4SS.log that is sent
static const ULONGLONG FT_SECOND = 10000000ULL;             // FILETIME ticks
static const ULONGLONG REPORT_MAX_AGE = 3ULL * 24 * 3600 * FT_SECOND;   // older crashes are not sent any more

struct CrashInfo {
    std::wstring dir;          // ...\Saved\Crashes\<id>\  (with trailing backslash)
    ULONGLONG time = 0;        // last write time (FILETIME)
};

static ULONGLONG ft64(const FILETIME& f) { return ((ULONGLONG)f.dwHighDateTime << 32) | f.dwLowDateTime; }
static ULONGLONG now_ft() { FILETIME f; GetSystemTimeAsFileTime(&f); return ft64(f); }
static ULONGLONG file_time(const std::wstring& path) {
    WIN32_FILE_ATTRIBUTE_DATA d;
    return GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &d) ? ft64(d.ftLastWriteTime) : 0;
}

// newest crash report folder of this chapter's game
static bool newest_crash(const Chapter& ch, CrashInfo& out) {
    wchar_t la[MAX_PATH];
    if (ch.proj.empty() || FAILED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, la))) return false;
    std::wstring crashes = std::wstring(la) + L"\\" + ch.proj + L"\\Saved\\Crashes\\";
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((crashes + L"*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    out = CrashInfo();
    do {
        std::wstring n = fd.cFileName;
        if (n == L"." || n == L".." || !(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
        ULONGLONG t = ft64(fd.ftLastWriteTime);
        if (t > out.time) { out.time = t; out.dir = crashes + n + L"\\"; }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return !out.dir.empty();
}

// "...Users\Max\..." / "...home/max/..." -> "...Users\<user>\..." (case-insensitive marker, name up to the next separator)
static std::string hide_user_names(std::string s) {
    static const char* MARKERS[] = { "users\\", "users/", "home\\", "home/" };
    std::string low = s;
    for (char& c : low) c = (char)tolower((unsigned char)c);
    std::string out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        bool hit = false;
        for (const char* m : MARKERS) {
            size_t ml = strlen(m);
            if (low.compare(i, ml, m) != 0) continue;
            size_t e = i + ml;
            while (e < s.size() && s[e] != '\\' && s[e] != '/' && s[e] != '"' && s[e] != '\r' && s[e] != '\n') e++;   // (Windows user names may contain spaces)
            if (e == i + ml) continue;                       // nothing after the marker
            out.append(s, i, ml);
            out += "<user>";
            i = e;
            hit = true;
            break;
        }
        if (!hit) out += s[i++];
    }
    return out;
}

static std::string xml_field(const std::string& xml, const char* tag) {
    std::string open = std::string("<") + tag + ">", close = std::string("</") + tag + ">";
    size_t a = xml.find(open);
    if (a == std::string::npos) return "";
    a += open.size();
    size_t b = xml.find(close, a);
    return b == std::string::npos ? "" : xml.substr(a, b - a);
}

// short text for the Discord message: the error and the top of the call stack
static std::string crash_summary(const std::string& xml) {
    std::string msg = xml_field(xml, "ErrorMessage");
    std::string stack = xml_field(xml, "PCallStack");
    std::string out = msg + "\n";
    size_t p = 0;
    for (int lines = 0; p < stack.size() && lines < 14; lines++) {
        size_t e = stack.find('\n', p);
        std::string l = stack.substr(p, e == std::string::npos ? std::string::npos : e - p);
        size_t s = l.find_first_not_of(" \t\r"), t = l.find_last_not_of(" \t\r");
        if (s != std::string::npos) {
            std::string line = l.substr(s, t - s + 1);
            for (size_t k = line.find("  "); k != std::string::npos; k = line.find("  ")) line.erase(k, 1);
            out += line + "\n";
        }
        if (e == std::string::npos) break;
        p = e + 1;
    }
    return out;
}

// multipart/form-data POST to the report worker; true when it answered 200
static bool post_report(const std::vector<std::pair<std::string, std::string>>& fields,
                        const std::vector<std::pair<std::string, std::string>>& files, std::string& err) {
    std::string boundary = "----PoppyCoopReport" + std::to_string(GetTickCount64());
    std::string body;
    for (auto& f : fields)
        body += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + f.first + "\"\r\n\r\n" + f.second + "\r\n";
    for (auto& f : files)
        body += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + f.first + "\"; filename=\"" + f.first +
                ".txt\"\r\nContent-Type: text/plain\r\n\r\n" + f.second + "\r\n";
    body += "--" + boundary + "--\r\n";

    bool ok = false;
    HINTERNET s = WinHttpOpen(L"PoppyCoopLauncher/" LAUNCHER_VERSION, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nullptr, nullptr, 0);
    if (!s) { err = "no internet"; return false; }
    WinHttpSetTimeouts(s, 10000, 10000, 30000, 30000);
    HINTERNET c = WinHttpConnect(s, REPORT_HOST, INTERNET_DEFAULT_HTTPS_PORT, 0);
    HINTERNET q = c ? WinHttpOpenRequest(c, L"POST", REPORT_PATH, nullptr, nullptr, nullptr, WINHTTP_FLAG_SECURE) : nullptr;
    std::wstring hdr = L"Content-Type: multipart/form-data; boundary=" + wide(boundary) + L"\r\n";
    if (q && WinHttpSendRequest(q, hdr.c_str(), (DWORD)-1L, (LPVOID)body.data(), (DWORD)body.size(), (DWORD)body.size(), 0)
          && WinHttpReceiveResponse(q, nullptr)) {
        DWORD code = 0, sz = sizeof code;
        WinHttpQueryHeaders(q, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nullptr, &code, &sz, nullptr);
        ok = code == 200;
        if (!ok) err = "server answered " + std::to_string(code);
    } else {
        err = "could not reach the report server";
    }
    if (q) WinHttpCloseHandle(q);
    if (c) WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    return ok;
}

// The log of the session that crashed: UE4SS.log, unless the game was started again after the crash (then the
// launcher saved that session's log as UE4SS_previous.log before the new start)
static std::string crashed_session_log(const std::wstring& ue4ss_dir, ULONGLONG crash_time) {
    std::wstring cur = ue4ss_dir + L"UE4SS.log", prev = ue4ss_dir + L"UE4SS_previous.log";
    bool restarted = file_time(cur) > crash_time + 120 * FT_SECOND;
    std::string log;
    if (!read_file(restarted ? prev : cur, log)) return "";
    if (log.size() > REPORT_LOG_TAIL) log = "[... start cut ...]\n" + log.substr(log.size() - REPORT_LOG_TAIL);
    return hide_user_names(log);
}

// Builds and sends one report. os = short system description (Windows version, Wine/Proton).
static bool send_crash_report(const Chapter& ch, const CrashInfo& ci, const std::wstring& mod_version,
                              const std::wstring& os, std::string& err) {
    std::string xml;
    read_file(ci.dir + L"CrashContext.runtime-xml", xml);
    xml = hide_user_names(xml);
    std::string log = crashed_session_log(bin_dir(ch) + L"\\ue4ss\\", ci.time);
    if (xml.empty() && log.empty()) { err = "crash report is empty"; return false; }
    std::string summary = xml.empty() ? std::string("(no crash context)") : crash_summary(xml);
    std::vector<std::pair<std::string, std::string>> fields = {
        { "version", utf8(mod_version) }, { "chapter", std::to_string(ch.num) },
        { "os", hide_user_names(utf8(os)) }, { "summary", summary } };
    std::vector<std::pair<std::string, std::string>> files;
    if (!log.empty()) files.push_back({ "log", log });
    if (!xml.empty()) files.push_back({ "crash", xml });
    return post_report(fields, files, err);
}
