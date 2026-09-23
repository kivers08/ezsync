---
name: write-vitest-test
description: Use when adding or updating Vitest tests for this repo. Encodes vi.mock hoisting/ordering, mocking Drizzle/Postgres and axios/fetch, resetting mocks in beforeEach, asserting both return values and mock call arguments, and covering happy, error, and edge paths in TypeScript/ESM.
---

# Write a Vitest Test

Tests are TypeScript, live next to the code as `*.test.ts` (e.g.
`apps/api/src/services/jobber/clientService.test.ts`), and run with Vitest. Run one file
with `npx vitest run <file>`. External dependencies are mocked — no real network or DB.

## Mocking setup (ESM + `vi.mock`)

- `vi.mock('module', factory)` is **hoisted** to the top of the file by Vitest, so it runs
  before the `import` of the module under test — you do **not** need to order it manually
  the way CommonJS `jest.mock`-before-`require` required. But any value the factory
  references must be created inside the factory or via `vi.hoisted(() => ...)`, because the
  factory runs before top-level `const`s are initialized.
- **Postgres / Drizzle:** don't hit a real database. Mock the Drizzle client module the
  code under test imports (e.g. `packages/db/client.ts`) and stub the query-builder chain
  the function actually calls. Assert on the calls, not on a live DB.
- **HTTP:** mock `axios` (Jobber GraphQL, QBO REST) or `globalThis.fetch` per file. For
  fetch: `vi.spyOn(globalThis, 'fetch')`.
- **decimal.js is real** — never mock money math; assert exact string results.

```ts
import { vi } from 'vitest';

// Hoisted mock of the Drizzle client the module imports.
const { mockDb } = vi.hoisted(() => ({ mockDb: { select: vi.fn(), insert: vi.fn() } }));
vi.mock('@ezsync/db/client', () => ({ db: mockDb }));
```

## Conventions

- `vi.resetAllMocks()` (or per-mock `.mockReset()`) in `beforeEach` to prevent cross-test
  bleed. Use `vi.stubEnv('JOBBER_API_VERSION', '2025-04-16')` for env the code reads, and
  `vi.unstubAllEnvs()` in `afterEach`.
- Assert **both** the resolved value **and** that the mock was called with the right args
  (URL, GraphQL variables, headers, tenant id).
- Cover **happy, error, and edge** paths. For Jobber that means a `userErrors` case; for
  HTTP a rejected / `errors` response; edge cases include empty pages, `null` money
  columns (`?? 0`), and duplicate webhook deliveries.
- **Multi-tenant:** where the function takes a `tenantId`, assert it is threaded into the
  query / request — a test that never checks tenant scoping can't catch a data-leak bug.
- Before finishing a test, be able to name the specific production bug or branch it would
  catch — if you can't, the assertion is too weak.
- Derive expected values by hand as literals, never by calling the function under test (or
  a shared helper) to compute what you then assert against.
- For async/timing-sensitive code, poll for the real condition or use `vi.useFakeTimers()`
  + `vi.advanceTimersByTimeAsync(...)` — never guess a fixed `setTimeout` delay.

## Template

```ts
// apps/api/src/services/jobber/clientService.test.ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

vi.mock('axios', () => ({ default: { post: vi.fn() } }));

import axios from 'axios';
import { editClient } from './clientService.js';

describe('editClient', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    vi.stubEnv('JOBBER_API_VERSION', '2025-04-16');
  });
  afterEach(() => vi.unstubAllEnvs());

  it('returns the entity on success', async () => {
    vi.mocked(axios.post).mockResolvedValueOnce({
      data: { data: { clientEdit: { client: { id: 'c_1' }, userErrors: [] } } },
    });

    const result = await editClient('tenant_1', 'c_1', { name: 'Acme' });

    expect(result).toEqual({ id: 'c_1' });
    expect(axios.post).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({ variables: expect.objectContaining({ id: 'c_1' }) }),
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: expect.stringContaining('Bearer') }),
      }),
    );
  });

  it('throws on userErrors', async () => {
    vi.mocked(axios.post).mockResolvedValueOnce({
      data: { data: { clientEdit: { client: null, userErrors: [{ message: 'bad' }] } } },
    });

    await expect(editClient('tenant_1', 'c_1', {})).rejects.toThrow(/bad/);
  });
});
```

## Before you finish

- Run only the file you wrote or touched: `npx vitest run <file>` (or
  `npx vitest run -t "<test name>"`). Never run the full suite locally — CI runs lint +
  typecheck + the full Vitest suite after push (`.claude/rules/testing-verification.md`).
