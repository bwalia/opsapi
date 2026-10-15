---
title: Hiring
pages: /dashboard/ats
api: /api/v2/ats
modules: ats_jobs, ats_candidates, ats_interviews, ats_kits, ats_reports, ats_settings
tools:
suggestions: Which candidates are waiting for review? | Show the pipeline for my open jobs | Which interviews finished this week?
readonly: false
---
# Hiring
Track jobs and candidates through a hiring pipeline, and run AI first-round interviews from an approved interview kit. A person always makes the decision; the AI only interviews and drafts an evaluation.

## Concepts
- A **job** has a pipeline of **applications** (a candidate applied to a job). Stages: applied -> screening -> interview -> review -> offer -> hired, or rejected (with a reason).
- An **interview kit** is the question set and scoring rubric for a job. It can be written by hand or generated from a job description, and must be **approved** before it can be used for interviews.
- An **interview** sends the candidate a private link. When they finish, an evaluation is drafted; a reviewer reads the transcript and records the decision. A link can be revoked.
- Reports show fairness (stage outcomes by group) and the audit trail.

## Using the page
- /dashboard/ats: overview of open jobs, interviews waiting for review and recent activity.
- /dashboard/ats/jobs and /dashboard/ats/jobs/{uuid}: jobs, their pipeline, moving or rejecting applications.
- /dashboard/ats/candidates and /dashboard/ats/candidates/{uuid}: candidates, notes, export of their data.
- /dashboard/ats/kits and /dashboard/ats/kits/{uuid}: interview kits, validation, approval.
- /dashboard/ats/interviews and /dashboard/ats/interviews/{uuid}: interviews, transcript, evaluation, review.
- /dashboard/ats/reports and /dashboard/ats/settings: fairness and audit reports; settings, API tokens and activation.

## Rules
- Never reject a candidate, move a stage, approve a kit or record an interview decision unless the user asks for that exact change.
- Resolve jobs, candidates and interviews by name with a list call first; never invent uuids.
- Candidate data is personal: summarise it, don't paste transcripts or notes in bulk.
- Don't judge candidates on protected characteristics; base answers on the kit's rubric and the recorded evaluation.

## API
- `GET /api/v2/ats/overview` — counts and recent activity
- `GET /api/v2/ats/jobs` — list jobs
- `POST /api/v2/ats/jobs` — create a job
- `GET /api/v2/ats/jobs/{uuid}` — one job
- `PUT /api/v2/ats/jobs/{uuid}` — change a job
- `DELETE /api/v2/ats/jobs/{uuid}` — delete a job
- `GET /api/v2/ats/jobs/{uuid}/pipeline` — the job's applications by stage
- `GET /api/v2/ats/candidates` — list candidates
- `POST /api/v2/ats/candidates` — add a candidate
- `GET /api/v2/ats/candidates/{uuid}` — one candidate with applications and notes
- `PUT /api/v2/ats/candidates/{uuid}` — change a candidate
- `DELETE /api/v2/ats/candidates/{uuid}` — delete a candidate
- `GET /api/v2/ats/candidates/{uuid}/export` — export a candidate's data
- `POST /api/v2/ats/candidates/{uuid}/notes` — add a note
- `POST /api/v2/ats/applications {job_uuid*, candidate_uuid*, stage}` — add a candidate to a job
- `POST /api/v2/ats/applications/{uuid}/stage {stage*}` — move an application to a stage
- `POST /api/v2/ats/applications/{uuid}/reject {reason}` — reject an application
- `GET /api/v2/ats/kits` — list interview kits
- `POST /api/v2/ats/kits` — create a kit
- `POST /api/v2/ats/kits/generate {job_description*, job_uuid, language}` — draft a kit with AI
- `GET /api/v2/ats/kits/{uuid}` — one kit
- `PUT /api/v2/ats/kits/{uuid}` — change a kit
- `DELETE /api/v2/ats/kits/{uuid}` — delete a kit
- `GET /api/v2/ats/kits/{uuid}/validate` — check a kit for problems
- `POST /api/v2/ats/kits/{uuid}/approve` — approve a kit for interviews
- `GET /api/v2/ats/interviews` — list interviews
- `POST /api/v2/ats/interviews` — invite a candidate to an interview
- `GET /api/v2/ats/interviews/{uuid}` — one interview with transcript and evaluation
- `POST /api/v2/ats/interviews/{uuid}/evaluate` — (re)run the evaluation
- `POST /api/v2/ats/interviews/{uuid}/review` — record the reviewer's decision
- `POST /api/v2/ats/interviews/{uuid}/revoke` — revoke the interview link
- `GET /api/v2/ats/reports/fairness` — fairness report
- `GET /api/v2/ats/audit` — hiring audit trail
- `GET /api/v2/ats/settings` — hiring settings
- `PUT /api/v2/ats/settings` — change hiring settings
