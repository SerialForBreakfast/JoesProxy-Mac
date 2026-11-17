// Fixed-workflow subscription benchmark. No API keys, network fallback or automatic retries.
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const [oldFile,newFile,output] = process.argv.slice(2).map(x => path.resolve(x));
const spec = require("./oracle.json");
const cli = process.env.CODEX_BENCH_CLI;
if (!cli) throw Error("Set CODEX_BENCH_CLI to the subscription-authenticated executable.");
const env = {...process.env};
for (const name of ["OPENAI_API_KEY","CODEX_API_KEY","OPENAI_BASE_URL"]) delete env[name];
const auth = spawnSync(cli,["login","status"],{env,encoding:"utf8"});
if (auth.status !== 0 || !/Logged in using ChatGPT/.test(auth.stdout + auth.stderr)) throw Error("ChatGPT subscription login required");
fs.mkdirSync(output,{recursive:true});
const runner = path.join(__dirname,"replay.cjs");
const digest = v => crypto.createHash("sha256").update(v).digest("hex");
for (const [question,ask] of Object.entries(spec.questions)) {
  for (let i=0;i<spec.pairsPerQuestion;i++) for (const filename of i%2 ? [newFile,oldFile] : [oldFile,newFile]) {
    const bytes = fs.readFileSync(filename);
    const packet = JSON.parse(bytes);
    const calls = packet[question];
    const trial = path.join(output,question+"-"+i+"-"+packet.version);
    if (fs.existsSync(trial+".receipt.json")) continue;
    if (fs.existsSync(trial+".attempt.json")) throw Error("Unclosed attempt: "+trial);
    const audit = trial+".calls.jsonl";
    const events = trial+".events.jsonl";
    const started = Date.now();
    const attempt = {question,pair:i,version:packet.version,model:spec.model,packetSHA256:digest(bytes),started};
    fs.writeFileSync(trial+".attempt.json",JSON.stringify(attempt),{flag:"wx"});
    const args = ["exec","--ignore-user-config","--ephemeral","--skip-git-repo-check","--json","-s","read-only","-m",spec.model,
      "-c",'forced_login_method="chatgpt"',"-c",'model_reasoning_effort="low"',"-c","mcp_servers.fixture.command="+JSON.stringify(process.execPath),
      "-c","mcp_servers.fixture.args="+JSON.stringify([runner,filename,question,audit]),"-c","mcp_servers.fixture.required=true",
      "-c","mcp_servers.fixture.enabled_tools="+JSON.stringify([...new Set(calls.map(v=>v.tool))]),"-"];
    const recipe = calls.filter(c=>!c.arguments.cursor).map(({tool,arguments:a})=>({tool,arguments:question==="example"&&tool==="session_summary"?{sessionID:"<ID of the first matching 502 in the previous search>"}:a}));
    const prompt = ask+"\nUse the synthetic fixture MCP tools following this workflow. For a paged search, repeat with its returned nextCursor until all pages are covered, except a limit-one example lookup. Substitute an observed identifier for any placeholder. Return one concise JSON answer. If a call fails, report the failure.\n"+JSON.stringify(recipe);
    const result = spawnSync(cli,args,{input:prompt,encoding:"utf8",env,cwd:output,timeout:180000,maxBuffer:16*1024*1024});
    fs.writeFileSync(events,result.stdout ?? "");
    fs.writeFileSync(trial+".stderr.log",result.stderr ?? "");
    const lines=(result.stdout ?? "").trim().split("\n").filter(Boolean).map(v=>{try{return JSON.parse(v)}catch{return {type:"invalid_event"}}});
    const turns=lines.filter(e=>e.type==="turn.completed");
    const usage=turns.length && turns.every(x=>Number.isFinite(x.usage?.input_tokens)&&Number.isFinite(x.usage?.output_tokens)) ?
      turns.reduce((t,e)=>({input:t.input+e.usage.input_tokens,output:t.output+e.usage.output_tokens,cached:t.cached+(e.usage.cached_input_tokens??0)}),{input:0,output:0,cached:0}):null;
    const observed=fs.existsSync(audit)?fs.readFileSync(audit,"utf8").trim().split("\n").filter(Boolean).map(JSON.parse):[];
    const answer=lines.filter(v=>v.item?.type==="agent_message").at(-1)?.item.text ?? "";
    const receipt={...attempt,elapsedMs:Date.now()-started,exitCode:result.status,signal:result.signal,usage,totalTokens:usage?usage.input+usage.output:null,
      attempts:observed.length,matchedAll:observed.length===calls.length&&observed.every(v=>v.matched),answer,grading:"pending independent oracle review"};
    fs.writeFileSync(trial+".receipt.json",JSON.stringify(receipt,null,2));
    if (!usage || result.status!==0) throw Error("Incomplete subscription trial. Inspect preserved receipt before resuming.");
  }
}
