#!/usr/bin/env node
import { performance } from 'node:perf_hooks';
import { OptimizerEngine } from '../Plugins/jev-optimizer/dist/index.js';

let source = '';
process.stdin.setEncoding('utf8');
for await (const chunk of process.stdin) source += chunk;
const items = JSON.parse(source);
const asker = { async ask(_state, questions) {
  const answers = Object.fromEntries(Object.keys(questions).map((name) => [
    name, { noul: name.startsWith('suitable_') || name === 'worth_retain' ? 0.98 : 0.02 },
  ]));
  return { answers, usage: { input_tokens: 101, output_tokens: 7 }, cost_usd: 0.002 };
}};
const engine = new OptimizerEngine({ asker });
const output = [];
for (const item of items) {
  const started = performance.now();
  const result = await engine.handle(item.input);
  output.push({ case_id: item.case_id, result, latency_ms: performance.now() - started });
}
process.stdout.write(`${JSON.stringify(output)}\n`);
