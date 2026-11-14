const fs=require("node:fs"),path=require("node:path");
const root=process.env.TIKTOKEN_PATH;
if(require(path.join(root,"package.json")).version!=="1.0.20")throw Error("Unexpected tokenizer version");
const enc=require(root).get_encoding("o200k_base");
const tokens=v=>enc.encode(JSON.stringify(v),[],[]).length;
const packets=process.argv.slice(2).map(f=>JSON.parse(fs.readFileSync(f)));
if(packets.map(p=>p.version).join("/")!=="1.9.0/1.9.1")throw Error("Wrong version pair");
const results=packets[0].windows.map((w,i)=>{
  const newWindow=packets[1].windows[i];
  if(w.offset!==newWindow.offset||w.rows!==newWindow.rows||JSON.stringify(w.oracle)!==JSON.stringify(newWindow.oracle))throw Error("Windows differ");
  const arms=[w,newWindow].map(({calls})=>({calls:calls.length,tokens:calls.reduce((n,c)=>n+tokens({name:c.tool,arguments:c.arguments})+tokens(c.answer),0)}));
  return {rows:w.rows,offset:w.offset,oracle:w.oracle,arms,reduction:1-arms[1].tokens/arms[0].tokens};
});
console.log(JSON.stringify({encoding:"o200k_base",version:"1.0.20",scope:"one copy of each canonical tool call and structured answer; warm transcript",results},null,2));
enc.free();
