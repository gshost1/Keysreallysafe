#!/usr/bin/env node
import { performance } from 'node:perf_hooks';
import { OptimizerEngine } from '../Plugins/jev-optimizer/dist/index.js';

let source = '';
process.stdin.setEncoding('utf8');
for await (const chunk of process.stdin) source += chunk;
const items = JSON.parse(source);
// A case may name candidates its deterministic mock evaluator declines.
let unsuitable = new Set();
const asker = { async ask(state, questions) {
  const declined = (name) => name.startsWith('suitable_') &&
    unsuitable.has(state?.candidates?.[Number(name.slice(9))]?.candidate?.id);
  const answers = Object.fromEntries(Object.keys(questions).map((name) => [
    name, { noul: (name.startsWith('suitable_') || name === 'worth_retain') && !declined(name) ? 0.98 : 0.02 },
  ]));
  return { answers, usage: { input_tokens: 101, output_tokens: 7 }, cost_usd: 0.002 };
}};
const engine = new OptimizerEngine({ asker });
const output = [];
for (const item of items) {
  unsuitable = new Set(Array.isArray(item.mock?.unsuitable_ids) ? item.mock.unsuitable_ids : []);
  const started = performance.now();
  const result = await engine.handle(item.input);
  output.push({ case_id: item.case_id, result, latency_ms: performance.now() - started });
}
process.stdout.write(`${JSON.stringify(output)}\n`);
