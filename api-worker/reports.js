// PoppyCoop crash reports (POST /report): the launcher POSTs a report here (multipart/form-data), the worker forwards it to a
// Discord channel through a webhook. The webhook URL is a secret of this worker (DISCORD_WEBHOOK) and never
// leaves Cloudflare, so nobody can read it out of the launcher and spam the channel directly.
//
// Fields from the launcher: version, chapter, os, summary (short text) and the files "log" (end of UE4SS.log)
// and "crash" (the game's CrashContext.runtime-xml). User names in paths are already replaced by <user>.

const MAX_BODY = 4 * 1024 * 1024;        // whole request
const MAX_FILE = 1536 * 1024;            // per file
const MAX_SUMMARY = 1500;                // Discord message limit is 2000 characters
const PER_IP_PER_HOUR = 6;               // best effort (per worker instance), against floods
const VERSION_RE = /^\d+\.\d+\.\d+$/;
const FILES = ["log", "crash"];

const recent = new Map();                // ip -> [timestamps]

function tooMany(ip) {
  const now = Date.now();
  const list = (recent.get(ip) || []).filter((t) => now - t < 3600_000);
  if (list.length >= PER_IP_PER_HOUR) {
    recent.set(ip, list);
    return true;
  }
  list.push(now);
  recent.set(ip, list);
  if (recent.size > 5000) recent.clear();
  return false;
}

function reply(status, error) {
  return new Response(JSON.stringify({ success: status === 200, error: error || null }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function clean(text, max) {
  // no mentions (@everyone / @here / users), no control characters, limited length
  return String(text || "")
    .replace(/@/g, "@\u200b")
    .replace(/`/g, "'")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "")
    .slice(0, max);
}

export async function handleReport(request, env) {
    if (request.method !== "POST") return reply(405, "POST only");
    if (!env.DISCORD_WEBHOOK) return reply(503, "reports are not set up");

    const length = Number(request.headers.get("content-length") || "0");
    if (!length || length > MAX_BODY) return reply(413, "report too big");
    const ua = request.headers.get("user-agent") || "";
    if (!ua.startsWith("PoppyCoopLauncher/")) return reply(403, "launcher only");

    const ip = request.headers.get("cf-connecting-ip") || "?";
    if (tooMany(ip)) return reply(429, "too many reports, try again later");

    let form;
    try {
      form = await request.formData();
    } catch {
      return reply(400, "bad form data");
    }
    const version = String(form.get("version") || "");
    if (!VERSION_RE.test(version)) return reply(400, "bad version");
    const chapter = clean(form.get("chapter"), 4);
    const os = clean(form.get("os"), 120);
    const summary = clean(form.get("summary"), MAX_SUMMARY);

    const out = new FormData();
    const content = `**Crash** - mod v${version}, Chapter ${chapter}\n${os}\n\`\`\`\n${summary}\n\`\`\``;
    out.append("payload_json", JSON.stringify({ content: content.slice(0, 1990), allowed_mentions: { parse: [] } }));
    let n = 0;
    for (const name of FILES) {
      const f = form.get(name);
      if (!f || typeof f === "string") continue;
      if (f.size > MAX_FILE) return reply(413, `${name} too big`);
      const ext = name === "crash" ? "xml" : "txt";
      out.append(`files[${n}]`, new Blob([await f.arrayBuffer()], { type: "text/plain" }), `${name}_v${version}_ch${chapter}.${ext}`);
      n++;
    }

    const res = await fetch(env.DISCORD_WEBHOOK, { method: "POST", body: out });
    if (!res.ok) return reply(502, `discord answered ${res.status}`);
    return reply(200);
}
