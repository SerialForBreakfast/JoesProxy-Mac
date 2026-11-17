// Guided subscription confirmation on the shifted 400-row window and the largest window.
// Replay authentic version-specific MCP responses, preserving failed attempts in the denominator.
const fs=require("node:fs"),path=require("node:path"),{spawnSync}=require("node:child_process");
const [oldFile,newFile,out]=process.argv.slice(2).map(v=>path.resolve(v));
const env={...process.env};
for(const k of ["GEMINI_API_KEY","GOOGLE_API_KEY","AGY_ADC_AUTH","GOOGLE_APPLICATION_CREDENTIALS","GOOGLE_GENAI_USE_VERTEXAI"])delete env[k];
const settings=JSON.parse(fs.readFileSync(path.join(env.HOME,".gemini/antigravity-cli/settings.json")));
if(settings.modelProvider)throw Error("Subscription account required");
fs.mkdirSync(out,{recursive:true});
for(const index of [5,4])for(let rep=0;rep<3;rep++)for(const arm of rep%2?[1,0]:[0,1]){
 const packet=JSON.parse(fs.readFileSync([oldFile,newFile][arm])),w=packet.windows[index];
 const name=[w.rows,rep,packet.version].join("-"),dir=path.join(out,name),audit=dir+".audit",receipt=dir+".json";
 if(fs.existsSync(receipt))continue;
 const data=dir+".packet",calls=w.calls;
 fs.writeFileSync(data,JSON.stringify({discovery:packet.discovery,count:calls}),{flag:"wx"});
 fs.mkdirSync(path.join(dir,".agents"),{recursive:true});
 fs.writeFileSync(path.join(dir,".agents/mcp_config.json"),JSON.stringify({mcpServers:{jpscale191:{command:process.execPath,args:[path.resolve(__dirname,"../replay.cjs"),data,"count",audit]}}}));
 const c=calls[0];
 const prompt="Using only the synthetic jpscale191 MCP server, give exact counts by HTTP status, including missing, in the specified video segment request window. Use "+c.tool+" with these arguments: "+JSON.stringify(c.arguments)+". If the result is paged, keep these arguments and pass each returned nextCursor as cursor until exhausted. Return only a JSON object mapping status code or missing to its integer count. If unable to establish the counts, report incomplete.";
 const start=Date.now();
 const r=spawnSync("agy",["--sandbox","--model","gemini-3.8-flash-low","--print-timeout","180s","--output-format","json","-p",prompt],{cwd:dir,env,encoding:"utf8",timeout:200000,maxBuffer:16*1024*1024});
 fs.writeFileSync(dir+".raw",r.stdout??"");fs.writeFileSync(dir+".stderr",r.stderr??"");
 let result={},answer=null;
 try{result=JSON.parse(r.stdout);answer=JSON.parse(result.response.match(/\x60{3}(?:json)?\s*(\{[\s\S]*?\})\s*\x60{3}/i)?.[1]??result.response.slice(result.response.indexOf("{"),result.response.lastIndexOf("}")+1));}catch{}
 const seen=fs.existsSync(audit)?fs.readFileSync(audit,"utf8").trim().split("\n").filter(Boolean).map(JSON.parse):[];
 const matched=seen.length===calls.length&&seen.every((v,i)=>v.index===i&&v.name===calls[i].tool&&v.matched);
 const correct=!!answer&&Object.keys(answer).length===Object.keys(w.oracle).length&&Object.entries(w.oracle).every(([k,v])=>answer[k]===v);
 fs.writeFileSync(receipt,JSON.stringify({version:packet.version,rows:w.rows,offset:w.offset,rep,matched,correct,answer,usage:result.usage??null,exit:r.status,status:result.status??null,elapsedMs:Date.now()-start,calls:seen},null,2));
 console.log(name,matched,correct,result.usage?.total_tokens);
 if(!result.usage?.total_tokens || !seen.length)throw Error("Missing MCP calls or usage; inspect retained attempt");
}
