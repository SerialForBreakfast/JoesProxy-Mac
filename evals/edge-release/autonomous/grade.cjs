const fs=require("node:fs"),path=require("node:path");
const spec=require("./cases.json"),dir=process.argv[2];
const ids=["10000000-0000-4000-8000-000000000001","10000000-0000-4000-8000-000000000002"];
const rows=fs.readdirSync(dir).filter(s=>s.endsWith(".receipt.json")).map(file=>{
  const r=JSON.parse(fs.readFileSync(path.join(dir,file)));
  const c=spec.cases.find(v=>v.id===r.case);
  let a=null;
  try{a=JSON.parse(r.answer.match(/\x60{3}(?:json)?\s*(\{[\s\S]*?\})\s*\x60{3}/i)?.[1]??r.answer.slice(r.answer.indexOf("{"),r.answer.lastIndexOf("}")+1))}catch{}
  const leaf=typeof a?.field==="string"?a.field.split(/[./]/).at(-1):null;
  const events=fs.readFileSync(path.join(dir,file.replace(".receipt.json",".events")),"utf8").trim().split("\n").map(JSON.parse);
  const actionEvents=events.map(e=>e.step_update).filter(s=>s?.state==="ACTIVE" && s.step_type==="tool");
  const other=actionEvents.filter(s=>{
    if(s.tool_name==="call_mcp_tool") return s.tool_info?.parameters?.ServerName!=="jpdebug191";
    if(s.tool_name==="read_file") return !/^.*\/mcp\/jpdebug191\/[a-z_]+\.json$/.test(s.tool_info?.parameters?.Path??"");
    return true;
  }).map(s=>s.tool_name);
  const cite=Array.isArray(a?.requestIDs)&&ids.every(id=>a.requestIDs.includes(id))&&a.requestIDs.length===2;
  const correct=cite && a.verdict===c.verdict && (c.verdict==="changed" ? leaf===c.field && a.before===c.left && a.after===c.right :
    a.field===null && a.before===null && a.after===null) && r.calls.some(v=>v.ok);
  return {...r,grade:{correct:Boolean(correct),cited:cite,otherToolAttempts:other},parsed:a};
});
console.log(JSON.stringify({revision:spec.revision,rows},null,2));
