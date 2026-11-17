const fs=require("node:fs"), path=require("node:path"), spec=require("./histogram.json");
const [root,guidedFile]=process.argv.slice(2);
const expected=spec.expected,rows=[];
for(let rep=0;rep<5;rep++)for(const version of ["1.9.0","1.9.1"]){
 const stem=path.join(root,"pair-"+rep,version+"-window400-"+rep);
 const r=JSON.parse(fs.readFileSync(stem+".receipt.json"));
 if(r.version!==version||r.rep!==rep||r.model!==spec.model)throw Error("Trial identity mismatch");
 const text=r.answer??"";
 let answer=null;try{answer=JSON.parse(text.match(/\x60{3}(?:json)?\s*(\{[\s\S]*?\})\s*\x60{3}/i)?.[1]??text.slice(text.indexOf("{"),text.lastIndexOf("}")+1))}catch{}
 const correct=r.status==="SUCCESS"&&r.calls.some(c=>c.ok)&&answer!==null&&Object.keys(answer).length===6&&Object.entries(expected).every(([k,v])=>answer[k]===v);
 const events=fs.readFileSync(stem+".events","utf8").trim().split("\n").map(JSON.parse);
 const extra=events.map(e=>e.step_update).filter(s=>s?.state==="ACTIVE"&&s.step_type==="tool"&&s.tool_name!=="call_mcp_tool"&&!(s.tool_name==="read_file"&&s.tool_info?.parameters?.Path?.includes("/mcp/jphist400/"))).map(s=>s.tool_name);
 rows.push({version,rep,correct,answer,usage:r.usage,status:r.status,elapsedMs:r.elapsedMs,calls:r.calls,extra});
}
const med=a=>{const s=[...a].sort((x,y)=>x-y);return (s[Math.floor((s.length-1)/2)]+s[Math.floor(s.length/2)])/2};
function summarize(rows){
 const arms=["1.9.0","1.9.1"].map(v=>{const a=rows.filter(r=>r.version===v),t=a.map(r=>r.usage.total_tokens);return {version:v,correct:a.filter(r=>r.correct).length,n:a.length,median:med(t),range:[Math.min(...t),Math.max(...t)],total:t.reduce((x,y)=>x+y),calls:a.map(r=>r.calls.length)}});
 const pairs=rows.filter(r=>r.version==="1.9.0"&&r.correct).flatMap(r=>{const s=rows.find(s=>s.version==="1.9.1"&&s.rep===r.rep&&s.correct);return s?[(1-s.usage.total_tokens/r.usage.total_tokens)*100]:[]});
 return {arms,eligiblePairs:pairs.length,pairedReductionPercent:pairs.length?med(pairs):null};
}
const guided=JSON.parse(fs.readFileSync(guidedFile)).filter(r=>r.rows===400);
console.log(JSON.stringify({autonomous:summarize(rows),guided:summarize(guided),trials:rows},null,2));
