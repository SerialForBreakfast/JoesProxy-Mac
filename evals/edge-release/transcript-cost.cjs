// Count model-visible JSON once, retaining discovery separately from the tool exchange.
const fs = require("node:fs");
const crypto = require("node:crypto");
const path = require("node:path");
const tokenizerRoot = process.env.TIKTOKEN_PATH;
if (!tokenizerRoot || require(path.join(tokenizerRoot, "package.json")).version !== "1.0.20") {
  throw new Error("Set TIKTOKEN_PATH to an existing tiktoken 1.0.20 installation.");
}
const encoding = require(tokenizerRoot).get_encoding("o200k_base");
const file = fs.readFileSync(process.argv[2]);
const fixture = JSON.parse(file);
const count = value => encoding.encode(JSON.stringify(value), [], []).length;
const rows = [];
function measure(question, arm, calls, discovery) {
  const warm = calls.reduce((n, call) => n + count({name:call.tool, arguments:call.arguments}) + count(call.answer), 0);
  rows.push({question,arm,calls:calls.length,warm,discovery,cold:discovery === null ? null : discovery + warm});
}
if (fixture.baseline && fixture.candidate) {
  for (const [arm,messages] of Object.entries(fixture)) {
    const calls = messages.map(message => {
      const request = JSON.parse(message.request).params;
      const data = JSON.parse(message.response).result.structuredContent;
      return {tool:request.name, arguments:request.arguments, answer:data.payload ?? data};
    });
    measure("count", arm, calls.slice(0,arm === "baseline" ? 8 : 1), null);
    measure("example", arm, calls, null);
  }
} else {
  const discovery = count(fixture.discovery);
  for (const name of ["count","example","comparison"]) measure(name,fixture.version,fixture[name],discovery);
}
encoding.free();
console.log(JSON.stringify({encoding:"o200k_base",packageVersion:"1.0.20",metric:"canonical JSON tool arguments and structured answers; excludes provider framing and repeated context",fixtureSHA256:crypto.createHash("sha256").update(file).digest("hex"),rows},null,2));
