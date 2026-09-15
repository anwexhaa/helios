# pipelines

Azure DevOps multi-stage pipeline definitions.

Lands in Phase 2: build, test, then promotion through helios-dev and helios-test into
helios-prod behind a manual approval check, with an automatic rollback when the post-deploy
smoke test fails.
