// friends.h - the launcher's friend list (basics, no server).
//
// Friend codes: "Name#12345". Player names aren't unique, so every launcher makes a 5-digit number once
// (player_tag(), core.h) and the mod tells it to the other players; a friend is a name AND a number.
// The mod writes recent_players.txt in every chapter's mod folder: "<ROOM>\t<name>#<tag>" per line, newest last
// (players with an older mod: just "<name>"). "Recently played with" and each friend's last room come from there.
// Stored in launcher.ini [Launcher] Friends = "name#tag|ROOM;..." (tag may be empty for old entries).
#pragma once
#include "core.h"

struct Friend {
    std::wstring name;
    std::wstring tag;      // 5 digits, "" = not known (added by name / met someone with an older mod)
    std::wstring room;     // last room played in together ("" = not yet)
};

static const size_t FRIENDS_MAX = 50;
static const size_t FRIEND_NAME_MAX = 24;
static const size_t FRIEND_TAG_LEN = 5;

static std::vector<Friend> g_friends;

// same rule as the mod's player names: letters, digits, _ and -, max 24
static std::wstring clean_player_name(const std::wstring& in) {
    std::wstring out;
    for (wchar_t c : in) {
        if (out.size() >= FRIEND_NAME_MAX) break;
        if ((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9') || c == L'_' || c == L'-') out += c;
    }
    return out;
}
static std::wstring clean_tag(const std::wstring& in) {
    std::wstring t;
    for (wchar_t c : in) if (c >= L'0' && c <= L'9') t += c;
    return t.size() == FRIEND_TAG_LEN ? t : L"";
}
// "Max#12345" -> {Max, 12345};  "Max" -> {Max, ""}
static Friend parse_code(const std::wstring& code) {
    size_t h = code.find(L'#');
    Friend f;
    f.name = clean_player_name(h == std::wstring::npos ? code : code.substr(0, h));
    if (h != std::wstring::npos) f.tag = clean_tag(code.substr(h + 1));
    return f;
}
static std::wstring friend_code(const Friend& f) { return f.tag.empty() ? f.name : f.name + L"#" + f.tag; }
static bool same_name(const std::wstring& a, const std::wstring& b) { return lower(a) == lower(b); }
// the same player: same name, and the same number when both are known
static bool same_player(const Friend& a, const Friend& b) {
    if (!same_name(a.name, b.name)) return false;
    return a.tag.empty() || b.tag.empty() || a.tag == b.tag;
}

static void friends_save() {
    std::wstring v;
    for (auto& f : g_friends) v += (v.empty() ? L"" : L";") + friend_code(f) + L"|" + f.room;
    ini_set(L"Launcher", L"Friends", v);
}
static void friends_load() {
    g_friends.clear();
    std::wstring v = ini_get(L"Launcher", L"Friends", L"");
    size_t p = 0;
    while (p < v.size() && g_friends.size() < FRIENDS_MAX) {
        size_t e = v.find(L';', p);
        if (e == std::wstring::npos) e = v.size();
        std::wstring item = v.substr(p, e - p);
        p = e + 1;
        size_t bar = item.find(L'|');
        Friend f = parse_code(item.substr(0, bar));
        if (bar != std::wstring::npos) f.room = clean_player_name(item.substr(bar + 1));
        for (auto& c : f.room) c = towupper(c);
        if (!f.name.empty()) g_friends.push_back(f);
    }
}
static int friend_index(const Friend& who) {
    for (size_t i = 0; i < g_friends.size(); i++) if (same_player(g_friends[i], who)) return (int)i;
    return -1;
}
enum class AddResult { Added, Empty, NeedsTag, Already, Full, Self };
static AddResult friend_add(Friend f, bool tag_required) {
    f.name = clean_player_name(f.name);
    if (f.name.empty()) return AddResult::Empty;
    if (tag_required && f.tag.empty()) return AddResult::NeedsTag;
    if (f.tag == player_tag() && !f.tag.empty()) return AddResult::Self;
    if (friend_index(f) >= 0) return AddResult::Already;
    if (g_friends.size() >= FRIENDS_MAX) return AddResult::Full;
    g_friends.push_back(f);
    friends_save();
    return AddResult::Added;
}
static void friend_remove(const Friend& who) {
    for (size_t i = 0; i < g_friends.size(); i++) {
        if (same_name(g_friends[i].name, who.name) && g_friends[i].tag == who.tag) {
            g_friends.erase(g_friends.begin() + i);
            friends_save();
            return;
        }
    }
}

// everyone met in a room, newest first, each player once
static std::vector<Friend> players_met(const std::vector<std::wstring>& mod_dirs, const std::wstring& me) {
    std::vector<Friend> all;
    for (auto& dir : mod_dirs) {
        std::string data;
        if (!read_file(dir + L"\\recent_players.txt", data)) continue;
        size_t p = 0;
        while (p < data.size()) {
            size_t e = data.find('\n', p);
            if (e == std::string::npos) e = data.size();
            std::string line = data.substr(p, e - p);
            p = e + 1;
            size_t t = line.find('\t');
            if (t == std::string::npos) continue;
            Friend f = parse_code(wide(line.substr(t + 1)));
            f.room = clean_player_name(wide(line.substr(0, t)));
            for (auto& c : f.room) c = towupper(c);
            bool self = same_name(f.name, me) && (f.tag.empty() || f.tag == player_tag());
            if (!f.name.empty() && !f.room.empty() && !self) all.push_back(f);
        }
    }
    std::vector<Friend> out;
    for (auto it = all.rbegin(); it != all.rend(); ++it) {
        bool dup = false;
        for (auto& o : out) if (same_name(o.name, it->name) && o.tag == it->tag) dup = true;
        // a tagged line and an untagged line of the same name: keep the tagged one
        if (!dup && it->tag.empty()) for (auto& o : out) if (same_name(o.name, it->name)) dup = true;
        if (!dup) out.push_back(*it);
    }
    return out;
}
// each friend's last room (and their number, if it wasn't known) from the players met; saved when changed
static bool friends_update_from(const std::vector<Friend>& met) {
    bool changed = false;
    for (auto& f : g_friends)
        for (auto& m : met)
            if (same_player(f, m)) {
                if (f.room != m.room) { f.room = m.room; changed = true; }
                if (f.tag.empty() && !m.tag.empty()) { f.tag = m.tag; changed = true; }
                break;
            }
    if (changed) friends_save();
    return changed;
}
