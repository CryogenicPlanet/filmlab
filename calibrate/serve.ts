// Serves chart.html and a shared "current page" so the capture script can flip pages on any screen (Mac or iPhone).
// GET /page -> current page; POST /page/<n> sets it.
const chart = Bun.file(`${import.meta.dir}/chart.html`);
const state = { page: 1 };
const server = Bun.serve({
  port: Number(process.env.PORT ?? 8799),
  hostname: "0.0.0.0",
  fetch(req): Response {
    const { pathname } = new URL(req.url);
    const set = pathname.match(/^\/page\/(\d+)$/);
    if (set && req.method === "POST") {
      state.page = Number(set[1]);
      return new Response(String(state.page));
    }
    if (pathname === "/page") return new Response(String(state.page), { headers: { "cache-control": "no-store" } });
    return new Response(chart, { headers: { "content-type": "text/html; charset=utf-8" } });
  },
});
console.log(`chart on http://${process.env.HOST_IP ?? "localhost"}:${server.port}/`);
