// zipwrite.h - writes a plain .zip (files stored without compression) from the files of one folder.
// Used for the problem report zip: Windows' tar.exe isn't there on old Windows, Wine and Proton (Linux / Steam Deck).
#pragma once
#include "core.h"

static uint32_t zip_crc32(const std::string& d) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (unsigned char b : d) c = table[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static void zip_put16(std::string& o, uint16_t v) { o += (char)(v & 0xFF); o += (char)(v >> 8); }
static void zip_put32(std::string& o, uint32_t v) { zip_put16(o, (uint16_t)(v & 0xFFFF)); zip_put16(o, (uint16_t)(v >> 16)); }

// all files directly in `dir` -> `zip` (overwritten). false when nothing could be written.
static bool zip_folder(const std::wstring& dir, const std::wstring& zip) {
    static const size_t ZIP_MAX = 0x7FFFFFFF;          // no zip64: the report stays far below 2 GB
    std::string out, central;
    uint16_t count = 0;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        std::string data;
        if (!read_file(dir + L"\\" + fd.cFileName, data)) continue;
        std::string name = utf8(fd.cFileName);
        if (out.size() + data.size() + name.size() + 128 > ZIP_MAX) break;
        uint32_t crc = zip_crc32(data), off = (uint32_t)out.size(), size = (uint32_t)data.size();
        // DOS date/time of the file
        FILETIME lft; WORD dd = 0, dt = 0;
        if (FileTimeToLocalFileTime(&fd.ftLastWriteTime, &lft)) FileTimeToDosDateTime(&lft, &dd, &dt);
        out += "PK\x03\x04";
        zip_put16(out, 20); zip_put16(out, 0x0800); zip_put16(out, 0);       // version, flags (UTF-8 names), stored
        zip_put16(out, dt); zip_put16(out, dd);
        zip_put32(out, crc); zip_put32(out, size); zip_put32(out, size);
        zip_put16(out, (uint16_t)name.size()); zip_put16(out, 0);
        out += name;
        out += data;
        central += "PK\x01\x02";
        zip_put16(central, 20); zip_put16(central, 20); zip_put16(central, 0x0800); zip_put16(central, 0);
        zip_put16(central, dt); zip_put16(central, dd);
        zip_put32(central, crc); zip_put32(central, size); zip_put32(central, size);
        zip_put16(central, (uint16_t)name.size()); zip_put16(central, 0); zip_put16(central, 0);
        zip_put16(central, 0); zip_put16(central, 0); zip_put32(central, 0); zip_put32(central, off);
        central += name;
        count++;
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    if (!count) return false;
    uint32_t cd_off = (uint32_t)out.size(), cd_size = (uint32_t)central.size();
    out += central;
    out += "PK\x05\x06";
    zip_put16(out, 0); zip_put16(out, 0); zip_put16(out, count); zip_put16(out, count);
    zip_put32(out, cd_size); zip_put32(out, cd_off); zip_put16(out, 0);
    HANDLE f = CreateFileW(zip.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    DWORD w = 0;
    bool ok = WriteFile(f, out.data(), (DWORD)out.size(), &w, nullptr) && w == out.size();
    CloseHandle(f);
    if (!ok) DeleteFileW(zip.c_str());
    return ok;
}
