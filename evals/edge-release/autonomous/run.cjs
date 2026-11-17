// Run each version serially with real JoesProxy MCP dispatch. Alternate case order between arms.
const fs=require("node:fs"), path=require("node:path"), http=require("node:http"), crypto=require("node:crypto");
const {spawn,spawnSync}=require("node:child_process");
const [xct,out,ver,round]=process.argv.slice(2);
const histogram=round!==undefined;
if(histogram&&!/^[0-4]$/.test(round))throw Error("Invalid paired round");
const spec=histogram?require("./histogram.json"):require("./cases.json");
const serverName=histogram?"jphist400":"jpdebug191";
const root=path.resolve(out),key=crypto.randomBytes(32).toString("hex");
const env={...process.env};
for(const k of ["GEMINI_API_KEY","GOOGLE_API_KEY","AGY_ADC_AUTH","GOOGLE_APPLICATION_CREDENTIALS","GOOGLE_GENAI_USE_VERTEXAI"]) delete env[k];
const settings=JSON.parse(fs.readFileSync(path.join(env.HOME,".gemini/antigravity-cli/settings.json")));
if(settings.modelProvider) throw Error("Require signed-in subscription");
fs.mkdirSync(root,{recursive:true});
const allowed=histogram?["sessions_list","sessions_search","session_summary","capture_calculate"]:["sessions_list","sessions_search","session_summary","response_evidence_brief","investigation_compare_brief"];
if(histogram)env.TEST_RUNNER_JP_BENCH_SCENARIO="histogram";
let waiting,active,queue=[],audit=[],agentKey,ready,failed;
const started=new Promise(r=>ready=r);
function dispatch(){
  if(!waiting||!queue.length)return;
  active=queue.shift();waiting.end(JSON.stringify(active.cmd));waiting=null;
}
function send(cmd){return new Promise(resolve=>{queue.push({cmd,resolve});dispatch()})}
const server=http.createServer(async(req,res)=>{
  const host=req.url==="/host";
  if(req.method!=="POST" || (!host && req.url!=="/agent") || req.headers["x-trial-key"]!==(host?key:agentKey)){res.writeHead(403).end();return}
  try{
    let raw="";for await(const part of req){raw+=part;if(raw.length>2000000)throw Error("size")}
    const msg=JSON.parse(raw);
    if(host){
      if(active){active.resolve(msg);active=null}else if(msg.version===ver)ready(msg);
      waiting=res;dispatch();
      const timer=setTimeout(()=>{if(waiting===res){waiting=null;res.end('{"action":"idle"}')}},10000);
      res.on("close",()=>clearTimeout(timer));return;
    }
    if(msg.action!=="list" && !(msg.action==="call" && allowed.includes(msg.name)))throw Error("unsupported");
    const ans=await send(msg);
    if(msg.action==="call")audit.push({name:msg.name,arguments:msg.arguments,ok:!ans.error,answerSHA256:crypto.createHash("sha256").update(JSON.stringify(ans)).digest("hex"),error:ans.error?.reason??null});
    res.end(JSON.stringify(ans));
  }catch{res.writeHead(400).end()}
});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
function child(cmd,args,opts) {
  const p=spawn(cmd,args,opts);
  return {p,done:new Promise(resolve=>{p.on("error",()=>resolve(127));p.on("close",resolve)})};
}
async function run(){
  await new Promise(r=>server.listen(0,"127.0.0.1",r));
  const port=server.address().port;
  const log=fs.openSync(path.join(root,ver+".host.log"),"ax");
  const host=child("xcodebuild",["test-without-building","-xctestrun",path.resolve(xct),"-only-testing:JoesProxyTests/MCPResponseDisclosureIntegrationTests/testAutonomousToolHost","-destination","platform=macOS","-parallel-testing-enabled","NO","-test-timeouts-enabled","YES","-maximum-test-execution-time-allowance","3600","-resultBundlePath",path.join(root,ver+".xcresult")],{env:{...env,TEST_RUNNER_JP_BENCH_PORT:String(port),TEST_RUNNER_JP_BENCH_KEY:key},stdio:["ignore",log,log]});
  try{
    let identity=await Promise.race([started,host.done.then(()=>null),delay(120000).then(()=>null)]);
    if(!identity || identity.build!==(ver==="1.9.0"?"23":"25"))throw Error("Host did not confirm expected build");
    for(let rep=histogram?Number(round):0;rep<(histogram?Number(round)+1:3);rep++)for(let k=0;k<spec.cases.length;k++){
      const c=spec.cases[(k+rep+(ver==="1.9.0"?0:2))%spec.cases.length];
      const name=ver+"-"+c.id+"-"+rep,dir=path.join(root,name);
      fs.mkdirSync(dir);agentKey=crypto.randomBytes(24).toString("hex");
      const bodies=[c.before,c.after].map((s,i)=>s===null?null:JSON.stringify({settings:{...s,updatedAt:"2026-01-0"+(i+1)+"T00:00:00Z"}}));
      await send({action:"reset",bodies});
      const defs=await send({action:"list"});
      if(defs.tools?.length!==allowed.length)throw Error("Discovery mismatch: "+JSON.stringify(defs.tools?.map(t=>t.name)));
      fs.mkdirSync(path.join(dir,".agents"));fs.writeFileSync(path.join(dir,".agents/mcp_config.json"),JSON.stringify({mcpServers:{[serverName]:{command:process.execPath,args:[path.join(__dirname,"bridge.cjs"),String(port),agentKey]}}}),{mode:0o600});
      audit=[];
      const stdout=fs.openSync(dir+".events","wx"),stderr=fs.openSync(dir+".stderr","wx");
      const start=Date.now();
      const agy=child("agy",["--sandbox","--model",spec.model,"--output-format","stream-json","--print-timeout","150s","-p",spec.prompt],{cwd:dir,env,stdio:["ignore",stdout,stderr]});
      const t=setTimeout(()=>agy.p.kill("SIGTERM"),165000);
      const code=await agy.done;clearTimeout(t);fs.closeSync(stdout);fs.closeSync(stderr);
      const events=fs.readFileSync(dir+".events","utf8").trim().split("\n").flatMap(v=>{try{return [JSON.parse(v)]}catch{return []}});
      const result=events.filter(e=>e.event==="result").at(-1)?.result??{};
      const actions=events.filter(e=>e.step_update?.step_type==="tool"&&e.step_update.state==="ACTIVE").map(e=>e.step_update.tool_name);
      const receipt={version:ver,build:identity.build,case:c.id,rep,model:events.find(e=>e.init)?.init?.model,code,status:result.status,usage:result.usage,answer:result.response??"",actions,calls:audit,elapsedMs:Date.now()-start};
      fs.writeFileSync(dir+".receipt.json",JSON.stringify(receipt,null,2));
      console.log(name,code,audit.map(a=>a.name).join(","),receipt.usage?.total_tokens);
      agentKey=null;
      if(!result.usage?.total_tokens)throw Error("Missing usage or subscription exhausted; retained attempt");
    }
  }finally{
    queue.push({cmd:{action:"stop"},resolve:()=>{}});dispatch();
    const t=setTimeout(()=>host.p.kill("SIGINT"),30000);const status=await host.done;clearTimeout(t);
    fs.closeSync(log);server.close();if(status!==0)process.exitCode=1;
  }
}
run().then(()=>process.exit(process.exitCode??0)).catch(e=>{console.error(e.message);process.exit(1)});
