// Offline grading and an opt-in Ollama runner for the worker. Uses only Node built-ins.
const fs = require('node:fs');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const path = require('node:path');
const {isDeepStrictEqual} = require('node:util');

const arms = ['ordinary', 'compact'];
const system = 'Read this single JoesProxy search page. A page has items or rows keyed by columns. A null cell means the field is absent. Answer for the supplied page only. Return only JSON with failureIDs (HTTP status 400–599, in capture order), unknownStatusCount (rows with absent status), hasMore (boolean), and retentionWarning (boolean indicating the page warns about retention).';
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const settings = {temperature: 0, seed: 23, num_ctx: 16384, num_predict: 512};

function evidence(page) {
  if (Array.isArray(page.items)) return page.items;
  assert(Array.isArray(page.columns) && Array.isArray(page.rows));
  return page.rows.map(row => {
    assert.equal(row.length, page.columns.length);
    return Object.fromEntries(page.columns.flatMap((key, i) => row[i] === null ? [] : [[key, row[i]]]));
  });
}

function verify(cases) {
  assert.equal(cases.length, 4);
  assert.equal(new Set(cases.map(c => c.id)).size, cases.length);
  for (const c of cases) {
    assert.deepEqual(evidence(c.ordinary), evidence(c.compact));
    for (const arm of arms) {
      const page = c[arm], rows = evidence(page);
      assert.deepEqual({
        failureIDs: rows.filter(r => r.statusCode >= 400 && r.statusCode <= 599).map(r => r.id),
        unknownStatusCount: rows.filter(r => r.statusCode == null).length,
        hasMore: page.hasMore, retentionWarning: /retention/i.test(page.captureWarning || ''),
      }, c.expected);
    }
  }
}

function schedule(cases) {
  const jobs = [];
  for (let round = 0; round < 2; round++) {
    const ordered = round ? [...cases].reverse() : cases;
    for (const c of ordered) {
      const index = cases.indexOf(c);
      const pair = (round + index) % 2 ? [...arms].reverse() : arms;
      for (const arm of pair) jobs.push({round, id: c.id, arm});
    }
  }
  return jobs;
}

function usage(reply) {
  const counts = [reply.prompt_eval_count, reply.eval_count];
  if (!counts.every(n => Number.isSafeInteger(n) && n >= 0) || counts[0] === 0) return null;
  return {input: counts[0], output: counts[1], total: counts[0] + counts[1]};
}

function grade(answer, expected) {
  try { return isDeepStrictEqual(JSON.parse(answer), expected); }
  catch { return false; }
}

function summarize(cases, attempts, fixtureHash) {
  const jobs = schedule(cases);
  assert(attempts.length <= jobs.length);
  const totals = Object.fromEntries(arms.map(a => [a, {attempts: 0, correct: 0, input: 0, output: 0, tokens: 0, missingUsage: 0}]));
  const pairs = new Map();
  const grades = [];
  const identity = attempts[0]?.identity;
  for (const [i, a] of attempts.entries()) {
    assert.deepEqual(a.job, jobs[i]);
    assert.deepEqual(a.identity, identity);
    assert.equal(a.fixtureHash, fixtureHash);
    const c = cases.find(c => c.id === a.job.id);
    const ok = !a.error && a.doneReason !== 'length' && grade(a.answer, c.expected);
    const count = usage(a);
    grades.push({...a.job, exact: ok, usage: count, error: a.error ?? null});
    const arm = totals[a.job.arm];
    arm.attempts++;
    if (ok) arm.correct++;
    if (count) {
      arm.input += count.input;
      arm.output += count.output;
      arm.tokens += count.total;
    }
    else arm.missingUsage++;
    const key = a.job.round + '/' + c.id;
    if (!pairs.has(key)) pairs.set(key, {});
    pairs.get(key)[a.job.arm] = {ok, count};
  }
  for (const arm of Object.values(totals)) {
    arm.accuracy = arm.attempts ? arm.correct / arm.attempts : null;
    arm.tokensPerCorrectAnswer = arm.correct && !arm.missingUsage ? arm.tokens / arm.correct : null;
  }
  const exactPairs = [...pairs.entries()].flatMap(([id, p]) =>
    p.ordinary?.ok && p.compact?.ok && p.ordinary.count && p.compact.count ?
      [{id, ordinary: p.ordinary.count, compact: p.compact.count,
        totalTokenReduction: 1 - p.compact.count.total / p.ordinary.count.total}] : []);
  return {identity, fixtureHash, plannedAttempts: jobs.length, recordedAttempts: attempts.length,
    complete: jobs.length === attempts.length, totals, grades, exactPairs};
}

async function run(cases, fixtureHash, output) {
  const base = process.env.OLLAMA_BASE_URL, model = process.env.JOESPROXY_EVAL_MODEL;
  assert(base && model && output, 'Set OLLAMA_BASE_URL and JOESPROXY_EVAL_MODEL and supply a fresh output path.');
  const tagsReply = await fetch(new URL('/api/tags', base), {signal: AbortSignal.timeout(15000)});
  assert(tagsReply.ok, 'Cannot read installed model list');
  const tag = (await tagsReply.json()).models.find(m => m.name === model);
  assert(tag?.digest, 'Select the exact tag of an already installed model.');
  const identity = {model, digest: tag.digest, settings, systemSHA256: hash(system)};
  const fd = fs.openSync(output, 'wx');
  try {
    for (const job of schedule(cases)) {
      const page = cases.find(c => c.id === job.id)[job.arm];
      const content = JSON.stringify(page);
      const record = {job, identity, fixtureHash, pageSHA256: hash(content)};
      const start = Date.now();
      try {
        const http = await fetch(new URL('/api/chat', base), {method: 'POST',
          signal: AbortSignal.timeout(180000), headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({model, options: settings, stream: false, format: 'json',
            messages: [{role: 'system', content: system}, {role: 'user', content}]})});
        assert(http.ok, 'Worker returned HTTP ' + http.status);
        const reply = await http.json();
        Object.assign(record, {answer: reply.message?.content ?? '', prompt_eval_count: reply.prompt_eval_count,
          eval_count: reply.eval_count, doneReason: reply.done_reason, returnedModel: reply.model});
        assert(reply.done && reply.model === model, 'Incomplete reply or changed model');
        assert(usage(reply), 'Missing provider token usage');
        assert(reply.prompt_eval_count + settings.num_predict < settings.num_ctx, 'Possible context truncation');
      } catch (error) { record.error = error.message; }
      record.elapsedMs = Date.now() - start;
      fs.writeSync(fd, JSON.stringify(record) + '\n');
      if (record.error) throw Error(record.error + '; retained partial receipt, stopping.');
    }
  } finally { fs.closeSync(fd); }
}

async function main() {
  const [mode, file = path.join(__dirname, 'pages.json'), output] = process.argv.slice(2);
  const bytes = fs.readFileSync(file), fixtureHash = hash(bytes), cases = JSON.parse(bytes);
  verify(cases);
  if (mode === 'verify') {
    // Exercise the grader without a model. An incorrect attempt still contributes to cost.
    const attempts = schedule(cases).map(job => ({job, identity: {}, fixtureHash, prompt_eval_count: 10,
      eval_count: 2, answer: JSON.stringify(cases.find(c => c.id === job.id).expected)}));
    attempts[0].answer = '{}';
    const summary = summarize(cases, attempts, fixtureHash);
    assert.equal(summary.exactPairs.length, 7);
    assert.equal(summary.totals.ordinary.tokensPerCorrectAnswer, 96 / 7);
    delete attempts[0].prompt_eval_count;
    assert.equal(summarize(cases, attempts, fixtureHash).totals.ordinary.tokensPerCorrectAnswer, null);
    console.log('Verified 4 page oracles, 16 scheduled attempts, and grading controls.');
    return;
  }
  if (mode === 'run') await run(cases, fixtureHash, output);
  else assert.equal(mode, 'score');
  const attempts = fs.readFileSync(output, 'utf8').split('\n').filter(Boolean).map(s => JSON.parse(s));
  console.log(JSON.stringify(summarize(cases, attempts, fixtureHash), null, 2));
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
