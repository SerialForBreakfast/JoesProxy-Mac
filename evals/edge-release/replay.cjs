// Serve only the synthetic, recorded responses for one paired trial, in workflow order.
const fs = require("node:fs");
const readline = require("node:readline");
const [file, question, audit] = process.argv.slice(2);
const packet = JSON.parse(fs.readFileSync(file));
const calls = packet[question];
if (!Array.isArray(calls) || !calls.length) throw Error("Missing workflow");
let index = 0;
const uniqueTools = [...new Set(calls.map(c => c.tool))];
const definitions = uniqueTools.map(name => {
  const tool = packet.discovery.find(t => t.name === name);
  if (!tool) throw Error("Missing recorded tool definition: " + name);
  return tool;
});
const canonical = value => Array.isArray(value) ? value.map(canonical) :
  value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map(k => [k,canonical(value[k])])) : value;
function handle(message) {
  if (message.method === "initialize") return {protocolVersion:message.params.protocolVersion,capabilities:{tools:{}},serverInfo:{name:"synthetic-replay",version:"1"}};
  if (message.method === "tools/list") return {tools:definitions};
  if (message.method === "ping") return {};
  if (message.method !== "tools/call") throw Error("Unsupported operation");
  const expected = calls[index];
  const match = expected && expected.tool === message.params.name &&
    JSON.stringify(canonical(expected.arguments)) === JSON.stringify(canonical(message.params.arguments ?? {}));
  fs.appendFileSync(audit,JSON.stringify({index,name:message.params.name,matched:Boolean(match)})+"\n");
  if (!match) return {isError:true,content:[{type:"text",text:"No recording for this call at this step."}]};
  index++;
  return {content:[{type:"text",text:JSON.stringify(expected.answer)}]};
}
readline.createInterface({input:process.stdin}).on("line",line=>{
  const m = JSON.parse(line);
  if (m.id === undefined) return;
  try { console.log(JSON.stringify({jsonrpc:"2.0",id:m.id,result:handle(m)})); }
  catch (e) { console.log(JSON.stringify({jsonrpc:"2.0",id:m.id,error:{code:-32601,message:e.message}})); }
});
