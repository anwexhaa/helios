# Postmortem - <short description>

**Date:** <yyyy-mm-dd>
**Duration:** <first impact to full recovery>
**Error budget consumed:** <minutes, and what share of the 28-day budget>
**Author:** <name>

## Summary

Two or three sentences. What broke, who it affected, how long it lasted. Someone who was not
involved should be able to read only this and know whether to read the rest.

## Impact

What users experienced, in their terms. Not "the pod crashlooped" but "job submissions were
refused for 14 minutes".

Quantified where possible: requests failed, jobs delayed, budget spent.

## Timeline

All times in one timezone, stated. Include when things were *noticed*, not only when they
happened — the gap between the two is usually the most actionable thing in the document.

| Time | Event |
|------|-------|
| | |

## Root cause

What actually caused it, followed far enough to be useful. "Redis ran out of memory" is a
symptom; "Redis had no memory limit and a retry storm filled it" is a cause.

Prefer contributing factors to a single root cause. Most incidents have several, and picking one
usually means picking the one nearest the person who touched it last.

## What went well

Genuinely. Detection that worked, a runbook that was right, a rollback that was fast. Systems
that only get examined when they fail get tuned in one direction.

## What went badly

Alerts that fired late or not at all. Runbooks that were wrong. Dashboards that did not show the
thing that mattered.

## Where we got lucky

The part most often skipped and most often the most valuable. What would have made this much
worse, and simply did not happen this time.

## Action items

Specific and owned. "Improve monitoring" is not an action item.

| Action | Type | Owner | Done |
|--------|------|-------|------|
| | prevent / detect / mitigate | | |

## Blameless

This document explains a system that allowed an outcome, not a person who caused one. If a
human action contributed, the question is what made that action reasonable at the time — the
information available, the tooling, the pressure. A postmortem that concludes someone should
have been more careful has found nothing that stops it happening again.
