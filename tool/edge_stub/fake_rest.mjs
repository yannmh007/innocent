// A stand-in PostgREST for booting an edge function locally. It records
// every call (method, path, body, whether an apikey came) to a JSON file and
// answers from a routes file: [{"method":"GET","prefix":"/rest/v1/titles?","status":200,"body":[]}, ...]
// — first match wins. Unmatched: GET 200 [], POST 201, PATCH/DELETE 204.
//
//   node tool/edge_stub/fake_rest.mjs <calls.json> <port> [routes.json]
import { createServer } from 'node:http';
import { readFileSync, writeFileSync } from 'node:fs';

const [out, port, routesFile] = process.argv.slice(2);
const routes = routesFile ? JSON.parse(readFileSync(routesFile, 'utf8')) : [];
const calls = [];
createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => { raw += c; });
  req.on('end', () => {
    let body = null;
    try { body = raw ? JSON.parse(raw) : null; } catch { body = raw; }
    calls.push({ m: req.method, u: req.url, body, apikey: !!req.headers.apikey });
    writeFileSync(out, JSON.stringify(calls, null, 1));
    const r = routes.find((x) => x.method === req.method && req.url.startsWith(x.prefix));
    const status = r ? r.status : (req.method === 'GET' ? 200 : req.method === 'POST' ? 201 : 204);
    const resBody = r ? r.body : (req.method === 'GET' ? [] : undefined);
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(resBody === undefined ? '' : JSON.stringify(resBody));
  });
}).listen(Number(port), '127.0.0.1');
