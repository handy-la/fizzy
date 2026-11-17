# Handy #2464 — the per-minute representation limit test crossing a minute

Test: `test/integration/active_storage_representation_admission_test.rb`,
"one identity is limited in how many new representations it asks for" (from Handy #968).
Change: the test pins the clock with `travel_to Time.current.beginning_of_minute` before its
requests. Production code (`lib/rails_ext/active_storage_representation_admission.rb`) and
`PROCESSINGS_PER_MINUTE` are unchanged.

## Authoring answers

1. **Contract:** one identity starts at most `PROCESSINGS_PER_MINUTE` new processings per window;
   the next one answers 429 (`RepresentationAdmission.within_rate?`, seen through the
   representation controller).
2. **Regression:** unchanged from #968 — raising or dropping the limit makes request 31 answer 302.
   The flake was the opposite: with the real clock, a run that crossed a wall-clock minute
   (`Time.current.to_i / 1.minute`) started a new count, so request 31 answered 302 with the
   code correct (fizzy-custom-test, sha e4a38d2f, 2026-11-17 18:45 UTC; passed on retry).
3. **Coverage:** no other test covers the rate; this is a fix of the existing case, not a new one.
4. **Seam:** none. `travel_to` is ActiveSupport's time helper; no production access point added.

## RED / GREEN evidence

Base: fizzy-custom `e4a38d2fe3621268773ca16a487653fdcde901cc` (the incident's sha), fix absent.
Directory: `fizzy-custom/`. Environment: Ruby 4.0.9 (mise install first in `PATH`, `GEM_HOME` and
`GEM_PATH` unset), `SAAS=false BUNDLE_GEMFILE=Gemfile`.

- **RED (sensitivity probe on the base test):** the base version of the file plus a temporary
  `travel 1.minute if size == 14` inside the request loop, which moves the clock past a minute
  after request 15.
  Command: `SAAS=false BUNDLE_GEMFILE=Gemfile bin/rails test test/integration/active_storage_representation_admission_test.rb -i "/one identity/"`.
  Exit 1: `Expected response to be a <429: too_many_requests>, but was a <302: Found>` at the
  31st request — the incident's symptom.
- **GREEN (fix, whole file, run 3 times + once more after review):**
  `SAAS=false BUNDLE_GEMFILE=Gemfile bin/rails test test/integration/active_storage_representation_admission_test.rb`.
  Exit 0 each time: `7 tests, 71 assertions, 0 failures, 0 errors`.
- **GREEN with a real crossing:** the fix plus a temporary `sleep` at request 15 until 0.5 s past the
  next real wall-clock minute, same `-i "/one identity/"` command: exit 0,
  `1 tests, 35 assertions, 0 failures` — the frozen clock ignores the wall clock.

Both probes were temporary and are not in the commit.

## Explicit RED exception

- **Impediment:** the incident needs the 30 requests to straddle a real minute boundary, which a
  normal run does by chance only; it is not reproducible on demand.
- **Incident evidence:** fizzy-custom-test, sha e4a38d2f, 2026-11-17 18:45 UTC, 429 expected, 302
  received, 31.69 s; the same job and sha passed at 18:57 UTC.
- **Contract still checked:** request 31 within one window answers 429; after `travel 1.minute` a new
  window serves again.
- **Untested risk:** with the clock frozen the test no longer exercises a real wall-clock boundary
  inside one run, so a production defect that only shows when the window changes mid-burst (for
  example a wrong window computation) is covered only by the final `travel 1.minute` step.
- **Alternative validation:** the two probes above (simulated crossing RED on the base, real crossing
  GREEN on the fix).
