// An MCP adapter to the isolated test host. Arguments are forwarded unmodified.
const readline=require("node:readline");
const [port,key]=process.argv.slice(2);
async function invoke(cmd) {
  const r=await fetch("http://127.0.0.1:"+port+"/agent",{method:"POST",headers:{"X-Trial-Key":key},body:JSON.stringify(cmd)});
  if(!r.ok) throw Error("Trial host status "+r.status);
  return r.json();
}
async function handle(m) {
  if(m.method==="initialize") return {protocolVersion:m.params.protocolVersion,capabilities:{tools:{}},serverInfo:{name:"jpdebug191",version:"1"}};
  if(m.method==="ping") return {};
  if(m.method==="tools/list") return invoke({action:"list"});
  if(m.method==="tools/call"){
    const r=await invoke({action:"call",name:m.params.name,arguments:m.params.arguments??{}});
    return {content:[{type:"text",text:JSON.stringify(r.answer??r.error)}],isError:Boolean(r.error)};
  }
  throw Error("Unsupported method");
}
readline.createInterface({input:process.stdin}).on("line",async line=>{
  const m=JSON.parse(line); if(m.id===undefined)return;
  try{console.log(JSON.stringify({jsonrpc:"2.0",id:m.id,result:await handle(m)}))}
  catch(e){console.log(JSON.stringify({jsonrpc:"2.0",id:m.id,error:{code:-32603,message:e.message}}))}
});
