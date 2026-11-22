// poppycoop-api (Cloudflare Worker): crash reports -> Discord, and the launcher's friends.
//   POST /report        crash report (reports.js)       needs secret DISCORD_WEBHOOK
//   POST /v1/...        friends (friends.js)            needs D1 database binding DB
import { handleReport } from "./reports.js";
import { handleFriends } from "./friends.js";

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    try {
      if (path === "/report") return await handleReport(request, env);
      if (path.startsWith("/v1/")) return await handleFriends(request, env, path);
      return new Response("PoppyCoop API\n", { status: 404 });
    } catch (e) {
      return new Response("E server_error\n", { status: 500 });
    }
  },
};
