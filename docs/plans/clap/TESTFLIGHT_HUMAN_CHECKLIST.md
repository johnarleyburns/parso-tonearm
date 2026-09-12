# Owner checklist — AFTER TestFlight availability

Copied verbatim from `IMPLEMENT_CLAP_PLAN.md` §12, as instructed by §11 C09.
Results are intentionally left blank — the coding agent must not invent
human relevance scores. The owner does not need to do this before code
completion/push/upload; do this only once the build is actually in
TestFlight.

> As of this writing (see `docs/plans/clap/IMPLEMENTATION_STATUS.md`), C02–C09
> have not been implemented, so there is no build to TestFlight yet. This
> checklist is staged for when that work lands.

Record build/device/OS, approximate library size, model download status and
initial indexed count. Use DRM-free music you own, starting with 50–100
varied familiar tracks; then use your real collection. Musical quality
assessment is separate from whether iOS happens to grant background time.

1. Import a folder. Confirm tracks immediately appear in the ordinary
   library and importing/indexing show separate real progress. Scroll and
   play music during import; report any freezes or audio interruptions.
2. Allow model download and indexing. Confirm completed count rises,
   pending falls and no second library/import is required. Open several
   results and verify they play the same imported tracks.
3. Pause, close and reopen. Pause must persist. Resume, leave the app,
   later reopen: previously completed work remains and remaining work
   resumes. Try one force-quit; do not expect iOS to run it while
   force-quit, but progress must survive reopening.
4. Leave the phone charging with the app backgrounded overnight. Record
   count before/after and displayed scheduling reason. No progress alone
   does not prove a defect because scheduling is discretionary; include
   diagnostics. Check that device warmth and battery behavior are
   acceptable during foreground indexing.
5. Try 10–15 short sound descriptions appropriate to YOUR collection, e.g.
   "gentle acoustic guitar," "fast distorted guitars," "slow atmospheric
   electronic," "bright danceable synths," and "sparse piano." Before each
   search, note 1–3 tracks you expect if you know them. Judge the top 10 as
   good/plausible/wrong and whether an expected track appears. Do not
   expect every example to match a collection lacking that sound.
6. Select 5 familiar reference tracks and use More like this. Judge the
   top 10 for useful sonic similarity. Reference itself should be absent;
   same-artist tracks are allowed. Note whether results are useful beyond
   title/artist matching.
7. Repeat searches scoped to one source and with BPM/key filters. Check
   every shown result obeys hard filters; missing musical metadata must not
   be guessed. Clear text but keep filters: it should still work without a
   text model.
8. Try More like/Less like refinements. Judge whether they help,
   understanding they are soft preferences, not guaranteed exclusions of
   vocals or other content.
9. Import additional tracks, replace one audio file, remove a source, and
   reopen the app. Confirm new work appears, replaced audio reindexes and
   deleted tracks disappear from results. Missing remote/local files should
   show a reason and recover when access returns.
10. Repeat a few queries while indexing is ongoing and after it completes.
    Record latency perceived as instant/acceptable/slow, relevance changes
    and any stale-scope results. Export redacted diagnostics for failures.

## Suggested decision rubric (owner evaluation only)

No data loss/UI freezes/hard-filter violations; useful results in at least
7 of 10 representative text queries and 4 of 5 similarity queries. These
are product targets, not claimed current results. If mechanics pass but
relevance disappoints, report examples and versions for a later
scoring/model iteration; do not retroactively label synthetic recall as
relevance validation.

## Results (fill in after TestFlight)

- Build / device / OS:
- Approximate library size:
- Model download status:
- Initial indexed count:

1.
2.
3.
4.
5.
6.
7.
8.
9.
10.
