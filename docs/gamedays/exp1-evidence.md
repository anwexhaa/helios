# Experiment 1 evidence - worker pod kill

Injected 12:37:52Z. Chaos Mesh pod-kill, gracePeriod unset (default 0 = immediate).
Victim: orion-worker-77d6d75fb4-znhlk. Load: 8,999 jobs submitted by k6 at 30/s.

## Census after the queue drained and every worker was idle

```
dead_letter=0
delayed=0
done=8995
queued=0
running=4
```

## The stuck records

```
{"id": "72c4340a-2b43-4610-acbb-f9b4d038327d", "task_name": "slow_task", "payload": {"duration": 2}, "priority": 5, "max_retries": 2, "attempt": 0, "status": "running", "submit_time": "2026-09-16T12:34:26.110937", "next_retry_time": "2026-09-16T12:34:26.110944", "error": null}
{"id": "524adebd-0b60-4734-8700-481e7e1a7fe3", "task_name": "slow_task", "payload": {"duration": 2}, "priority": 5, "max_retries": 2, "attempt": 0, "status": "running", "submit_time": "2026-09-16T12:34:26.151721", "next_retry_time": "2026-09-16T12:34:26.151728", "error": null}
{"id": "91d02bbb-800c-41f7-9643-73c8d96b880e", "task_name": "slow_task", "payload": {"duration": 2}, "priority": 5, "max_retries": 2, "attempt": 0, "status": "running", "submit_time": "2026-09-16T12:34:26.061613", "next_retry_time": "2026-09-16T12:34:26.061621", "error": null}
{"id": "04bbc460-88a9-4a75-877d-a0912135629b", "task_name": "slow_task", "payload": {"duration": 2}, "priority": 5, "max_retries": 2, "attempt": 0, "status": "running", "submit_time": "2026-09-16T12:34:26.011283", "next_retry_time": "2026-09-16T12:34:26.011291", "error": null}
```
