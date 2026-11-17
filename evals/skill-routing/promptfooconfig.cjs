const fs = require('node:fs');
const path = require('node:path');

const base = process.env.OLLAMA_BASE_URL;
const model = process.env.JOESPROXY_EVAL_MODEL;
if (!base || !model) throw new Error('Set OLLAMA_BASE_URL and JOESPROXY_EVAL_MODEL to an existing local model.');
const skill = process.env.JOESPROXY_SKILL_DIR || path.resolve(__dirname, '../../.agents/skills/joesproxy-mcp-diagnostics');
const guide = fs.readFileSync(path.join(skill, 'references/efficient-reads.md'), 'utf8');
const cases = [
  ['Count retained requests by HTTP status between two known timestamps.', 'capture_calculate'],
  ['Find the latest retained requests with a 5xx response, grouped by endpoint.', 'sessions_search'],
  ['I have a response session ID. Show just two fields for each item in its JSON collection.', 'response_evidence_brief'],
  ['Compare two explicit baseline and candidate session selections for changes in JSON values.', 'investigation_compare_brief'],
  ['With an already shared saved JSON snapshot and revision, compute two numeric aggregates.', 'artifact_calculate'],
  ['After the capture marker, which requests almost matched my override?', 'capture_activity_since_marker'],
];
const task = 'Assume an enrolled client with its catalog already discovered. Return only the MCP tool name for the first evidence read.\n{{question}}';
module.exports = {
  description: 'Paired synthetic routing trial, unaided versus exported efficiency reference',
  providers: [{id: 'ollama:chat:' + model, config: {temperature: 0, num_predict: 96}}],
  prompts: [{label: 'unaided', raw: task}, {label: 'skill-reference', raw: guide + '\n\n' + task}],
  tests: cases.map(([question, expected]) => ({vars: {question}, assert: [{type: 'equals', value: expected}]})),
};
