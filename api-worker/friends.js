// PoppyCoop friends (POST /v1/...): accounts, friend requests, friend list with online status.
//
// Every request is authenticated: headers X-Account (the launcher's random account id, 16 hex) and X-Secret
// (its random secret, 32 hex; only a SHA-256 of it is stored). The body is form data (application/x-www-form-
// urlencoded). Answers are plain text lines so the C++ launcher needs no JSON parser:
//   OK [word]            success
//   E <code>             error (bad_auth, tag_taken, not_found, self, already, limit, bad_input, ...)
//   F <name#tag> <online 0|1> <chapter> <room|->      a friend            (from /v1/list)
//   I <name#tag>         incoming request      O <name#tag>   outgoing request (still waiting)

const ONLINE_SECONDS = 120;          // seen within this time = online (the launcher says hello every 60 s)
const MAX_PENDING_OUT = 30;          // open requests one player may have
const MAX_FRIENDS = 200;
const REQUESTS_PER_HOUR = 30;

const ID_RE = /^[0-9a-f]{16}$/;
const SECRET_RE = /^[0-9a-f]{32}$/;
const NAME_RE = /^[A-Za-z0-9_-]{1,24}$/;
const TAG_RE = /^\d{5}$/;
const ROOM_RE = /^[A-Z0-9-]{0,16}$/;

const now = () => Math.floor(Date.now() / 1000);
const text = (body, status = 200) =>
  new Response(body.endsWith("\n") ? body : body + "\n", { status, headers: { "content-type": "text/plain; charset=utf-8" } });
const err = (code, status = 400) => text(`E ${code}`, status);

async function sha256(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// "Max#12345" -> { name_lc, tag } or null
function parseCode(code) {
  const m = /^([A-Za-z0-9_-]{1,24})#(\d{5})$/.exec(String(code || "").trim());
  return m ? { name_lc: m[1].toLowerCase(), tag: m[2] } : null;
}
const codeOf = (row) => `${row.name}#${row.tag}`;

// the calling account, checked against its secret; null = not registered yet / wrong secret
async function caller(request, env) {
  const id = request.headers.get("x-account") || "";
  const secret = request.headers.get("x-secret") || "";
  if (!ID_RE.test(id) || !SECRET_RE.test(secret)) return { bad: true };
  const row = await env.DB.prepare("SELECT * FROM accounts WHERE id = ?").bind(id).first();
  if (!row) return { id, secret, row: null };
  if (row.secret_hash !== (await sha256(secret))) return { bad: true };
  return { id, secret, row };
}

async function findByCode(env, code) {
  const c = parseCode(code);
  if (!c) return null;
  return env.DB.prepare("SELECT * FROM accounts WHERE name_lc = ? AND tag = ?").bind(c.name_lc, c.tag).first();
}

// hello: create the account or update name/tag/status (also the 60 s heartbeat)
async function hello(env, me, form) {
  const name = String(form.get("name") || "");
  const tag = String(form.get("tag") || "");
  const chapter = Math.max(0, Math.min(9, parseInt(form.get("chapter") || "0", 10) || 0));
  const room = String(form.get("room") || "").toUpperCase();
  const ingame = form.get("ingame") === "1" ? 1 : 0;
  if (!NAME_RE.test(name) || !TAG_RE.test(tag) || !ROOM_RE.test(room)) return err("bad_input");
  const taken = await env.DB.prepare("SELECT id FROM accounts WHERE name_lc = ? AND tag = ?").bind(name.toLowerCase(), tag).first();
  if (taken && taken.id !== me.id) return err("tag_taken", 409);
  const t = now();
  if (!me.row) {
    await env.DB.prepare(
      "INSERT INTO accounts (id, secret_hash, name, name_lc, tag, created, last_seen, chapter, room, ingame) VALUES (?,?,?,?,?,?,?,?,?,?)"
    ).bind(me.id, await sha256(me.secret), name, name.toLowerCase(), tag, t, t, chapter, room, ingame).run();
    return text("OK created");
  }
  await env.DB.prepare("UPDATE accounts SET name = ?, name_lc = ?, tag = ?, last_seen = ?, chapter = ?, room = ?, ingame = ? WHERE id = ?")
    .bind(name, name.toLowerCase(), tag, t, chapter, room, ingame, me.id).run();
  return text("OK");
}

async function list(env, me) {
  const t = now();
  const lines = [];
  const fr = await env.DB.prepare(
    "SELECT a.name, a.tag, a.last_seen, a.chapter, a.room, a.ingame FROM friends f JOIN accounts a ON a.id = f.b WHERE f.a = ? ORDER BY a.name_lc"
  ).bind(me.id).all();
  for (const r of fr.results) {
    const online = t - r.last_seen < ONLINE_SECONDS ? 1 : 0;
    lines.push(`F ${codeOf(r)} ${online} ${online && r.ingame ? r.chapter : 0} ${online && r.ingame && r.room ? r.room : "-"}`);
  }
  const inc = await env.DB.prepare("SELECT a.name, a.tag FROM requests q JOIN accounts a ON a.id = q.from_id WHERE q.to_id = ? ORDER BY q.created").bind(me.id).all();
  for (const r of inc.results) lines.push(`I ${codeOf(r)}`);
  const out = await env.DB.prepare("SELECT a.name, a.tag FROM requests q JOIN accounts a ON a.id = q.to_id WHERE q.from_id = ? ORDER BY q.created").bind(me.id).all();
  for (const r of out.results) lines.push(`O ${codeOf(r)}`);
  return text(["OK", ...lines].join("\n"));
}

async function areFriends(env, a, b) {
  return !!(await env.DB.prepare("SELECT 1 FROM friends WHERE a = ? AND b = ?").bind(a, b).first());
}
async function makeFriends(env, a, b) {
  const t = now();
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO friends (a, b, since) VALUES (?, ?, ?)").bind(a, b, t),
    env.DB.prepare("INSERT OR IGNORE INTO friends (a, b, since) VALUES (?, ?, ?)").bind(b, a, t),
    env.DB.prepare("DELETE FROM requests WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)").bind(a, b, b, a),
  ]);
}

async function sendRequest(env, me, form) {
  const to = await findByCode(env, form.get("code"));
  if (!to) return err("not_found", 404);
  if (to.id === me.id) return err("self");
  if (await areFriends(env, me.id, to.id)) return err("already");
  // they asked us already: this is an accept
  if (await env.DB.prepare("SELECT 1 FROM requests WHERE from_id = ? AND to_id = ?").bind(to.id, me.id).first()) {
    await makeFriends(env, me.id, to.id);
    return text("OK friends");
  }
  const pending = await env.DB.prepare("SELECT COUNT(*) AS n FROM requests WHERE from_id = ?").bind(me.id).first();
  const recent = await env.DB.prepare("SELECT COUNT(*) AS n FROM requests WHERE from_id = ? AND created > ?").bind(me.id, now() - 3600).first();
  const nfr = await env.DB.prepare("SELECT COUNT(*) AS n FROM friends WHERE a = ?").bind(me.id).first();
  if (pending.n >= MAX_PENDING_OUT || recent.n >= REQUESTS_PER_HOUR || nfr.n >= MAX_FRIENDS) return err("limit", 429);
  await env.DB.prepare("INSERT OR IGNORE INTO requests (from_id, to_id, created) VALUES (?, ?, ?)").bind(me.id, to.id, now()).run();
  return text("OK requested");
}

async function respond(env, me, form) {
  const from = await findByCode(env, form.get("code"));
  if (!from) return err("not_found", 404);
  const req = await env.DB.prepare("SELECT 1 FROM requests WHERE from_id = ? AND to_id = ?").bind(from.id, me.id).first();
  if (!req) return err("no_request", 404);
  if (form.get("accept") === "1") {
    await makeFriends(env, me.id, from.id);
    return text("OK friends");
  }
  await env.DB.prepare("DELETE FROM requests WHERE from_id = ? AND to_id = ?").bind(from.id, me.id).run();
  return text("OK declined");
}

// remove a friend, or take back an own request
async function remove(env, me, form) {
  const other = await findByCode(env, form.get("code"));
  if (!other) return err("not_found", 404);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM friends WHERE (a = ? AND b = ?) OR (a = ? AND b = ?)").bind(me.id, other.id, other.id, me.id),
    env.DB.prepare("DELETE FROM requests WHERE from_id = ? AND to_id = ?").bind(me.id, other.id),
  ]);
  return text("OK removed");
}

export async function handleFriends(request, env, path) {
  if (request.method !== "POST") return err("post_only", 405);
  if (!env.DB) return err("not_set_up", 503);
  const ua = request.headers.get("user-agent") || "";
  if (!ua.startsWith("PoppyCoopLauncher/")) return err("launcher_only", 403);
  const me = await caller(request, env);
  if (me.bad) return err("bad_auth", 401);
  let form;
  try {
    form = await request.formData();
  } catch {
    return err("bad_input");
  }
  if (path === "/v1/hello") return hello(env, me, form);
  if (!me.row) return err("not_registered", 401);       // everything else needs a hello first
  await env.DB.prepare("UPDATE accounts SET last_seen = ? WHERE id = ?").bind(now(), me.id).run();
  if (path === "/v1/list") return list(env, me);
  if (path === "/v1/request") return sendRequest(env, me, form);
  if (path === "/v1/respond") return respond(env, me, form);
  if (path === "/v1/remove") return remove(env, me, form);
  return err("not_found", 404);
}
