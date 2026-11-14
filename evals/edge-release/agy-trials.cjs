// Subscription-only, serial AGY trials against captured MCP results. Each invocation starts a new conversation.
const fs = require("node:fs");
const path = require("node:path");
const {spawnSync} = require("node:child_process");
const {createHash} = require("node:crypto");
const spec = require("./oracle.json");
const [oldPath,newPath,out] = process.argv.slice(2).map(v=>path.resolve(v));
const model="gemini-3.8-flash-low";
const env={...process.env};
for(const k of ["GEMINI_API_KEY","GOOGLE_API_KEY","AGY_ADC_AUTH","GOOGLE_APPLICATION_CREDENTIALS","GOOGLE_GENAI_USE_VERTEXAI"]) delete env[k];
const cfg=path.join(process.env.HOME,".gemini/antigravity-cli/settings.json");
if(fs.existsSync(cfg)&&JSON.parse(fs.readFileSync(cfg)).modelProvider) throw Error("Require default signed-in provider");
fs.mkdirSync(out,{recursive:true});
const selectedQuestion=process.env.JOESPROXY_BENCH_QUESTION;
if(selectedQuestion && !Object.hasOwn(spec.questions,selectedQuestion)) throw Error("Unknown question");
const questions=Object.entries(spec.questions).filter(([q])=>!selectedQuestion || q===selectedQuestion);
for(const [q,ask] of questions) for(let pair=0;pair<5;pair++) for(const arm of (pair%2?[1,0]:[0,1])){
  const file=[oldPath,newPath][arm];
  if (!fs.existsSync(file)) { console.log("Awaiting version evidence"); process.exit(0); }
  const packet=JSON.parse(fs.readFileSync(file)),calls=packet[q];
  if(packet.version!==["1.9.0","1.9.1"][arm]) throw Error("Version mismatch");
  const name=[q,pair,packet.version].join("-"), dir=path.join(out,name), receipt=dir+".receipt.json";
  if(fs.existsSync(receipt)) continue;
  fs.mkdirSync(dir);
  const agents=path.join(dir,".agents"),audit=dir+".calls.jsonl";
  fs.mkdirSync(agents);
  fs.writeFileSync(path.join(agents,"mcp_config.json"),JSON.stringify({mcpServers:{jpbench191flash:{command:process.execPath,args:[path.join(__dirname,"replay.cjs"),file,q,audit]}}}));
  const recipe=calls.filter(c=>!c.arguments.cursor).map(c=>({name:c.tool,arguments:q==="example"&&c.tool==="session_summary"?{sessionID:"<first matching ID from search>"}:c.arguments}));
  const fields=Object.keys(spec.expected[q]);
  const prompt=ask+" Use call_mcp_tool with ServerName jpbench191flash for each listed ToolName and Arguments and the recorded workflow below. Use exact arguments. Follow nextCursor until exhausted except limit-one lookup; substitute the observed ID for placeholders. Use no filesystem, terminal, browser, or other tools. Return a single JSON object with fields "+fields.join(", ")+". State incomplete if evidence is unavailable. Workflow: "+JSON.stringify(recipe);
  const start=Date.now();
  const r=spawnSync("agy",["--sandbox","--model",model,"--output-format","json","--print-timeout","150s","-p",prompt],{cwd:dir,env,encoding:"utf8",maxBuffer:8*1024*1024,timeout:180000});
  fs.writeFileSync(dir+".stdout",r.stdout||""); fs.writeFileSync(dir+".stderr",r.stderr||"");
  let result={},answer=null;
  try{result=JSON.parse(r.stdout);const body=result.response.match(/\x60{3}json\s*([\s\S]*?)\x60{3}/i)?.[1]??result.response;answer=JSON.parse(body.trim());}catch{}
  const observed=fs.existsSync(audit)?fs.readFileSync(audit,"utf8").trim().split("\n").filter(Boolean).map(JSON.parse):[];
  const matched=observed.length===calls.length && observed.every((v,i)=>v.matched&&v.index===i&&v.name===calls[i].tool);
  const expected={...spec.expected[q]};
  if(q==="example") expected.exampleID=calls.at(-1).arguments.sessionID;
  const exact=answer!==null && Object.entries(expected).every(([k,v])=>answer[k]===v);
  const row={question:q,pair,version:packet.version,model,elapsedMs:Date.now()-start,exitCode:r.status,status:result.status??null,usage:result.usage??null,matchedAll:matched,calls:observed,exactAnswer:exact,answer,text:result.response??null,packetSHA256:createHash("sha256").update(fs.readFileSync(file)).digest("hex")};
  fs.writeFileSync(receipt,JSON.stringify(row,null,2));
  console.log(name,result.status,observed.length,matched,exact,result.usage?.total_tokens);
  if(r.status!==0 || !result.usage?.total_tokens || !observed.length) throw Error("Inspect receipt for missing usage, quota, authentication, or MCP wiring before continuing");
}
