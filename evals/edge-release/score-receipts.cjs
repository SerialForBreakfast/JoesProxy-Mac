// Offline review of subscription trials. Human answer grades are keyed to the exact receipt.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const spec = require("./oracle.json");

function distribution(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a,b) => a-b);
  const mid = Math.floor(sorted.length / 2);
  return {n: sorted.length, min: sorted[0], median: (sorted[mid] + sorted[Math.floor((sorted.length-1)/2)]) / 2, max: sorted.at(-1)};
}

function review(directory, grades = {}) {
  const results = {};
  for (const question of Object.keys(spec.questions)) {
    const pairs = [];
    for (let pair = 0; pair < spec.pairsPerQuestion; pair++) {
      const arms = ["1.9.0","1.9.1"].map(version => {
        const base = path.join(directory, [question,pair,version].join("-"));
        if (!fs.existsSync(base+".receipt.json")) {
          return {status:fs.existsSync(base+".attempt.json") ? "interrupted" : "pending"};
        }
        const bytes = fs.readFileSync(base+".receipt.json");
        const hash = crypto.createHash("sha256").update(bytes).digest("hex");
        const r = JSON.parse(bytes);
        if (r.version !== version || r.pair !== pair || r.question !== question || r.model !== spec.model)
          throw Error("Receipt identity mismatch: "+path.basename(base));
        const u = r.usage;
        const count = n => Number.isSafeInteger(n) && n >= 0;
        const measured = u && count(u.input) && count(u.output) && count(r.totalTokens) && r.totalTokens === u.input+u.output;
        const grade = grades[hash];
        const status = r.exitCode !== 0 || !r.matchedAll || !measured ? "incomplete" :
          grade === true ? "correct" : grade === false ? "incorrect" : "awaiting_grade";
        return {status,hash,tokens:measured ? r.totalTokens : null};
      });
      pairs.push(arms);
    }
    const correct = pairs.filter(arms=>arms.every(a=>a.status==="correct"));
    results[question] = {
      plannedPairs:pairs.length, correctPairs:correct.length,
      arms:Object.fromEntries(["1.9.0","1.9.1"].map((version,i)=>{
        const rows=pairs.map(p=>p[i]);
        return [version,{statuses:rows.reduce((m,r)=>({...m,[r.status]:(m[r.status]??0)+1}),{}),
          allMeasuredTokens:distribution(rows.filter(r=>r.tokens!=null).map(r=>r.tokens))}];
      })),
      pairedTokenDifference:distribution(correct.map(([old,next])=>old.tokens-next.tokens)),
      pairs
    };
  }
  return results;
}
if(require.main===module){
  const [dir,grades]=process.argv.slice(2);
  if(!dir || !fs.statSync(dir).isDirectory()) throw Error("Supply a trial directory and optional independently reviewed grades JSON");
  console.log(JSON.stringify(review(dir,grades ? JSON.parse(fs.readFileSync(grades)) : {}),null,2));
}
module.exports={review,distribution};
