const http = require("http");
const req = http.request({ hostname: "127.0.0.1", port: 5000, path: "/api/biomes", method: "GET", headers: { "X-API-Key": "jx1CHKYfWFAs2JFddJQfaA", "Connection": "close" } }, (res) => {
  console.log("status", res.statusCode);
  let body = "";
  res.on("data", (c) => body += c.toString());
  res.on("end", () => console.log("body", body.slice(0, 200)));
});
req.on("error", (err) => { console.error("node-error", err.code, err.message); process.exitCode = 1; });
req.end();
