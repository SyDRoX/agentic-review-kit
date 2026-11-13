This is a Python backend. Check these on every change:

- Input from outside: request bodies, query parameters and file contents are untrusted. Look for a missing type or range check, an unbounded
  size, and a value that reaches SQL, a shell command, a file path or a template without validation.
- Async code: a blocking call (file or network I/O without `await`, `time.sleep`, a long pure-Python loop) inside `async def` stalls every
  other request on the event loop. A coroutine that is called but not awaited never runs.
- Mutable defaults and shared state: a list or dict default argument is shared between calls; module-level state is shared between requests
  and between worker threads.
- Errors: a bare `except` or `except Exception` that swallows the error hides the failure; a resource opened without `with` leaks on the
  error path.
- Database: values go in bound parameters. A transaction that spans an `await` or an outside call can hold a lock for a long time. A migration
  runs against a database that holds data.
- Types: `Optional` values used without a `None` check; a `dict.get` result used as if the key always exists.
- Client contract: a renamed, removed or retyped field in a response or a request model breaks clients that are already deployed.
