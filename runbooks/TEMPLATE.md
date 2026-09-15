# Runbook — <failure mode>

One page per failure mode. Written to be followed at 3 a.m. by someone who did not build this.

**Severity:** <page | ticket>
**Owner:** <name>
**Last exercised:** <date of the game day that last proved this runbook works>

## Symptom

What the person holding the pager actually sees. The alert name, the dashboard panel that goes
red, the user-visible effect. Not the cause — the symptom.

## Verify

Confirm the alert is real before acting on it.

```bash
# commands that distinguish a genuine incident from a noisy alert
```

## Diagnose

| Check | Command or query | Meaning |
|-------|------------------|---------|
| | | |

Link the Grafana panel and the saved KQL query in `docs/kql/` rather than retyping them here.

## Remediate

Numbered, in order, with the least destructive step first.

1.
2.
3.

**Do not** — anything that looks helpful but makes it worse. Say why.

## Escalate

Who to wake, and after how long, if the steps above do not resolve it.

## Aftermath

- Record the timeline in `docs/gamedays.md` if this was an exercise, or open a postmortem in
  `docs/postmortems/` if it was real.
- Note the error budget consumed.
- If this runbook was wrong or slow, fix it now while the incident is fresh.
