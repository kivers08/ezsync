---
paths:
  - "apps/web/**"
---

# Client-Side View Logic — Flag Untestable React in Review

Client logic in `apps/web` lives in React components. Behaviour that only runs in the
browser — effect hooks, event handlers, third-party SDK callbacks (Square Web Payments,
etc.), and anything gated on `window`/DOM state — is easy to leave outside the Vitest
suite's reach. The review pass, not CI, is the gate on that logic.

- **Green CI is not sign-off** for a change to browser-only component logic. If a change
  touches an effect, an event handler, or an external-SDK callback that no test exercises,
  flag it as review-critical and say so out loud — a passing suite proves nothing about
  code the suite never runs.
- **Prefer extracting testable logic out of the component.** Pull pure logic (formatting,
  money math via decimal.js, validation, state transitions) into plain functions in the
  component's module or `packages/shared` so Vitest can cover it directly; leave only the
  thin render/wiring layer untested. The more logic that lives in the untestable shell,
  the more the review pass has to carry.
- **When fixing an initialization or async race, confirm EVERY exit path settles** what
  the waiter awaits — throws before the happy path included. Prefer a promise guaranteed
  to settle (resolve/reject in a `finally` covering every throwing statement) over a flag
  that might never be set. The failure mode is a hang with no error, so nothing surfaces
  it except tracing the paths.
