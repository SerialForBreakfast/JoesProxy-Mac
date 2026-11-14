def row($i; $path; $status; $body):
  ("1970-01-01T00:00:00Z" | fromdateiso8601) + $i | todateiso8601 as $time |
  {id:("00000000-0000-4000-8000-"+(("000000000000"+($i|tostring))[-12:])),
   request:{method:"GET",scheme:"http",inspectionKind:"plain",host:"edge.example.test",port:80,path:$path,headers:[]},
   state:(if $status==null then "pending" else "completed" end),
   timing:({startedAt:$time} + (if $status==null then {} else {completedAt:$time} end))}
   + (if $status==null then {} else ($body|tojson) as $text |
       {response:{statusCode:$status,headers:[{name:"Content-Type",value:"application/json"}],
         bodyData:($text|@base64),bodySize:($text|utf8bytelength),source:"upstream"}} end);
{schemaVersion:2,exportedAt:"2026-11-13T12:00:00Z",appVersion:"1.9.1",proxyPort:9090,recordingFidelity:"fullRecording",
 sessions:([range(0;301) as $i | row($i;"/app/status.json";(if $i==299 then null else 502 end);{case:$i,error:"synthetic upstream unavailable"})]
 + [row(301;"/settings";200;{settings:{featureEnabled:false,updatedAt:"2026-01-01T00:00:00Z"}}),
    row(302;"/settings";200;{settings:{featureEnabled:true,updatedAt:"2026-01-02T00:00:00Z"}})])}
 | .sessionCount=(.sessions|length)
