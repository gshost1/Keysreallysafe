// `npm test`: runs the suite and also fails it when workerd reports an
// unhandled rejection. Such a rejection fails no test by itself, it only prints
// "Uncaught (in promise)", and docs/relay.md promises a suite without one.
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const vitest = fileURLToPath(new URL("../node_modules/vitest/vitest.mjs", import.meta.url));
const child = spawn(process.execPath, [vitest, "run", ...process.argv.slice(2)], {
  cwd: fileURLToPath(new URL("..", import.meta.url)),
  stdio: ["inherit", "pipe", "pipe"],
});

const NEEDLE = "Uncaught (in promise)";
const output = { stdout: "", stderr: "" };
for (const name of ["stdout", "stderr"]) {
  child[name].on("data", (chunk) => {
    process[name].write(chunk);
    output[name] += chunk.toString("utf8");
  });
}

child.on("close", (code, signal) => {
  const seen = (output.stdout + "\n" + output.stderr).split(NEEDLE).length - 1;
  if (seen > 0) {
    process.stderr.write(`\nrelay tests: workerd reported ${seen} unhandled rejection(s) ("${NEEDLE}"); see above\n`);
    process.exit(1);
  }
  process.exit(code ?? (signal ? 1 : 0));
});
