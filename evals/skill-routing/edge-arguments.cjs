// Run on the model worker with the same exported skill and provider as the naming trial.
const base = require('./promptfooconfig.cjs');
const questions = [
  {
    question: 'Which endpoints failed between 2026-01-01T10:00:00Z and 2026-01-01T10:05:00Z? Count them and identify the slowest failure in each.',
    tool: 'sessions_search',
    args: {statusClass: 'error', deduplicateBy: 'endpoint', endpointExample: 'slowest',
      startedAfter: '2026-01-01T10:00:00Z', startedBefore: '2026-01-01T10:05:00Z'},
  },
  {
    question: 'Which images downloaded from different URLs contained identical file bytes?',
    tool: 'audit_cache_efficiency', args: {includeImageIdentity: true},
  },
  {
    question: 'Read the text printed on the captured artwork with session ID 00000000-0000-4000-8000-000000000149. I only need the text.',
    tool: 'visual_asset_inspection', args: {sessionID: '00000000-0000-4000-8000-000000000149', view: {mode: 'ocr'}},
  },
  {
    question: 'Show only the upper left quarter of that same captured artwork, session ID 00000000-0000-4000-8000-000000000149, at a maximum edge of 128 pixels.',
    tool: 'visual_asset_inspection', args: {sessionID: '00000000-0000-4000-8000-000000000149',
      view: {mode: 'preview', crop: [0, 0, 0.5, 0.5], maxEdge: 128}},
  },
  {
    question: 'Wait up to five seconds for two new GET requests. Tell me how many arrived.',
    tool: 'capture_wait', args: {count: 2, seconds: 5, method: 'GET'},
  },
];
const instruction = 'Return one JSON object with tool and arguments for the first evidence read. Assume an enrolled client with its catalog already discovered.';
const prompts = base.prompts.map(prompt => ({...prompt, raw: prompt.raw.replace(
  'Assume an enrolled client with its catalog already discovered. Return only the MCP tool name for the first evidence read.', instruction)}));

// Additional optional arguments are allowed; score every required argument including crop coordinates.
function includesValue(actual, expected) {
  if (Array.isArray(expected)) return Array.isArray(actual) && actual.length === expected.length &&
    expected.every((item, i) => includesValue(actual[i], item));
  if (expected !== null && typeof expected === 'object') return actual !== null && typeof actual === 'object' &&
    Object.entries(expected).every(([key, value]) => includesValue(actual[key], value));
  return actual === expected;
}
module.exports = {...base, description: 'Post-1.9.1 edge tool and argument routing', prompts,
  tests: questions.map(({question, tool, args}) => ({vars: {question}, assert: [{type: 'javascript',
    value: output => {
      try {
        const result = typeof output === 'string' ? JSON.parse(output) : output;
        return result.tool === tool && includesValue(result.arguments, args);
      } catch { return false; }
    }}]}))};
