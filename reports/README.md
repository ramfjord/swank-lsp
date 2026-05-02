# Per-phase agent reports

Each agent that implements a phase writes a short report here:

- **Estimate (before starting):** LoC, files, subsystems, wall time.
- **Actual (after finishing):** same fields.
- **What surprised:** anything that broke an assumption from the plan.
- **Architectural simplifications:** could the next phase collapse
  scaffolding from this one? Could this phase have been smaller with
  a different framing?
- **Open seams:** anything left as a TODO that the next phase or
  reviewer should know about.

These exist so the supervisor doesn't have to re-derive context
between phases, and so future-us can see the actual shape of the
work, not the planned shape.
