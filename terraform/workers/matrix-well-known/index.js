export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/.well-known/matrix/server") {
      return new Response(JSON.stringify({"m.server": "matrix.wyattau.com:443"}), {
        headers: {"Content-Type": "application/json; charset=utf-8"}
      });
    }
    return new Response("Not Found", {status: 404});
  }
};
