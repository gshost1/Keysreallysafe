// Serves only checked-in marketing assets. Analytics and fonts never leave loopback.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../Site');
const files = new Set(fs.readdirSync(root));
http.createServer((req, res) => {
  const pathname = new URL(req.url, 'http://127.0.0.1').pathname;
  let name = pathname === '/' ? 'index.html' : pathname.slice(1);
  if (!path.extname(name)) name += '.html';
  if (!files.has(name)) { res.writeHead(404); return res.end('not found'); }
  if (name === 'posthog.js') { res.writeHead(200, { 'Content-Type': 'application/javascript' }); return res.end(''); }
  const ext = path.extname(name);
  const type = { '.html': 'text/html', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' }[ext] || 'text/plain';
  let body = fs.readFileSync(path.join(root, name));
  if (ext === '.html') body = Buffer.from(body.toString().replace(/<link[^>]+href="https:\/\/fonts[^>]+>/g, ''));
  res.writeHead(200, { 'Content-Type': type }); res.end(body);
}).listen(Number(process.env.KEYS_FIXTURE_PORT), '127.0.0.1');
