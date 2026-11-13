This is a TypeScript backend on Cloudflare Workers with a SQL database (D1) and SQL migrations. Check these on every change:

- Input from outside: every request body, query parameter and header is untrusted. Look for a missing type or range check, a number parsed
  without a `NaN` check, an unbounded string, array or page size, and a value that reaches SQL or a response without validation.
- SQL: values go in bound parameters, never in the query string. A changed query must match the current schema, with every migration in
  `migrations/` applied in order.
- Migrations: a migration runs against a database that holds data. A new `NOT NULL` column needs a default; a dropped or renamed column must
  not be read by code that is still deployed; a migration file that was already applied must never be edited.
- Awaiting: a promise that is not awaited is cut off when the response returns. Work that must outlive the response needs
  `ctx.waitUntil`.
- Worker limits: no state kept in module scope between requests, no long CPU loop over unbounded input, no unbounded fan-out of subrequests.
- Responses: status codes match the failure (4xx for a bad request, 5xx for a server fault); an error response leaks no stack trace, secret
  or SQL text; CORS headers are present on error paths too.
- Abuse: a write endpoint a game client calls can be called by anyone. Look for missing authentication, missing rate limiting, and a score,
  replay or analytics payload that is trusted without a server-side check.
- Client contract: the game client sends and reads these payloads. A renamed, removed or retyped field breaks clients already installed, which
  cannot be updated at once. A change like that needs a version check or backward compatibility.
