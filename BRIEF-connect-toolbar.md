# Connecting the toolbar to Maestro

Brief for the coding agent. Five tasks. Four are wiring and verification; only
the last one is a feature.

Every file and line below was read, not guessed. Verify before you change.

---

## Where things stand

The toolbar is a native macOS app (and a Python twin for Windows) that already
speaks to the API. What it calls today:

| Trigger | Call |
| --- | --- |
| Review flyout opens | `GET /sales/actions?status=pending` |
| ✓ | `PATCH /sales/actions/{id}` `{"status":"done"}` |
| Dismiss | `PATCH /sales/actions/{id}` `{"status":"dismissed"}` |
| Send the email | `POST /sales/actions/{id}/send` |
| The line at the bottom of a card | `POST /sales/actions/{id}/instruct` |
| A recording finishes | `POST /meetings/ingest` (via `push.sh`) |
| Capture box | none — appends to `~/Recordings/captures.md` |

Server side, already on `main` (commit `3f6c94c`, merged in PR #172):

- `services/connectors/main.py:88` `_machine_owner()`
- `services/connectors/main.py:117` the machine-token check inside `current_user`
- `services/connectors/main.py:1795` `@app.post("/meetings/ingest")`
- `services/meeting/run.py` public aliases: `already_analyzed`, `upsert_meeting`,
  `emit_meeting_signal`, `persist_meeting_tasks`
- `tests/test_meetings_ingest.py` — 10 tests

Nothing works end to end yet, because of tasks 1 to 3.

---

## Task 1 — Is that code actually running?

Being on `main` is not being deployed.

```sh
curl -s localhost:8001/openapi.json | python3 -c \
  "import json,sys; print('meetings/ingest' in json.load(sys.stdin)['paths'])"
```

If `False`, the service is running an older commit. Deploy `main` the way this
service is normally deployed — find that, do not invent a new mechanism.

**Done when** the command prints `True` and `tests/test_meetings_ingest.py`
passes on the deployed commit.

---

## Task 2 — The machine token

`current_user` verifies a Cognito ID token, which expires in about an hour and
is refreshed through an httpOnly cookie. A menu bar app can hold neither. That
is why `_machine_owner` exists, and it is inert until the environment variable
is set.

Find where this service's environment comes from — AWS Secrets Manager is used
elsewhere in the repo (`shared/secrets.py`), so check there first, then the
systemd unit or compose file. Add:

```
MAESTRO_MACHINE_TOKENS=<email>:<secret>,<email2>:<secret2>
```

**You do not generate or store the secret values.** Sandra generates them with
`python3 -c "import secrets;print(secrets.token_urlsafe(32))"` and puts them in
place herself. Your job is to make the variable reach the process and to say
exactly where you wired it.

One pair per person. The token is the identity: every row carries `owner`, so a
shared token would record one person's approvals under another's name and train
the learning signals against the wrong person.

**Done when** a request with a machine token in `Authorization: Bearer` returns
that owner's data, and a wrong token returns 401. Never log the token, never
print it in an error, never commit it.

---

## Task 3 — Settle the hostname

The clients are configured for `https://maestro-agent.duckdns.org`. The
certificates on the EC2 box are for `api.advertisable.ai` and
`api-adbot.advertisable.ai`.

Work out which hostname actually terminates at this service now — read the
nginx config and the certbot list, do not assume. Report the answer. If duckdns
is legacy, the `api` value in these two files has to change:

- `~/Desktop/MaestroBar/maestro-bar.json` (macOS)
- `~/Desktop/MaestroBarWin/bar.json` (Windows)

**Done when** you can state which hostname is correct and why, with the config
line that proves it.

---

## Task 4 — Prove it end to end

With 1 to 3 done, from the laptop:

```sh
~/.maestro/bin/push.sh ~/Recordings/<any recording>.m4a
```

Then confirm, in order:

1. a row in `meetings` with `status='analyzed'` and the transcript stored
2. a row in `signals` with `source='meeting'` and `weight=3.0`
3. rows in `meeting_tasks` with `status='proposed'`, one per consensus item
4. within five minutes, commitments in the graph from that meeting

Push the same file twice and confirm nothing duplicates — `external_id` is the
guard.

Anything already waiting in `~/Recordings/unsent` goes with `flush.sh`.

**Done when** all four are true and the second push changes nothing.

---

## Task 5 — The missing link: an accepted task becomes a Linear issue

This is the only real gap. The chain is:

```
brainstorm → record → transcribe → /meetings/ingest → meeting_tasks
   → you accept it in the toolbar → ??? → Linear → resolver → PR
```

`meeting_tasks.linear_url` exists as a column and every query selects it, but
**nothing in the codebase ever writes it**. Accepting a task marks it accepted
and stops there. Meanwhile `resolver/` is fully implemented and waits for
issues carrying the `auto-resolve` label.

### What to build

In `services/connectors/main.py`, `meeting_task_accept` (around line 1588)
currently does one thing:

```python
ok = await meeting_store.set_task_status(user, task_id, "accepted")
```

After that succeeds, create the Linear issue and store its URL.

Put the Linear call in `resolver/linear.py`, which already holds
`LINEAR_API_TOKEN` and a working `_gql` helper. Add alongside
`fetch_auto_resolve_issues`:

```python
async def create_issue(title: str, description: str, *,
                       label: str | None = None) -> dict | None:
    """Create an issue on the configured team, optionally labelled. Returns
    {id, identifier, url} or None."""
```

It needs `config.LINEAR_TEAM_ID` (already defined, `resolver/config.py:37`) and
the label id for `config.AUTORESOLVE_LABEL` (`resolver/config.py:38`), which
means a lookup or create of the label by name. `maestro-agent/src/linear.ts`
has `findOrCreateLabels` and `createIssue` doing exactly this in TypeScript —
read it and mirror the mutation rather than reinventing the shape.

Then in `services/meeting/store.py`, add:

```python
async def set_task_linear_url(owner: str, task_id: str, url: str) -> bool:
```

### Rules for it

- **The Linear call must not be able to fail the accept.** If Linear is down,
  the task is still accepted and the response says the issue could not be
  created. Wrap it, never let it raise through the endpoint.
- **Idempotent.** A task that already has a `linear_url` does not get a second
  issue. Check before creating.
- **The label is a decision, not a default.** Applying `auto-resolve`
  immediately hands the ticket to an agent that will write code and open a PR.
  Make it opt-in: an `auto_resolve: bool = False` field on the accept request,
  so a person chooses. The toolbar can then offer it as a separate menu item.
- The issue body should carry the evidence: the task description, the
  `consensus` quote, and a link back to the meeting. That quote is the reason
  the task exists and the resolver reads the description as its instructions.

### Tests

In `tests/`, with Linear stubbed:

1. accepting a task creates one issue and stores its URL
2. accepting a task that already has a `linear_url` creates nothing
3. a Linear failure still accepts the task and reports the failure
4. `auto_resolve=False` creates the issue without the label
5. `auto_resolve=True` applies the label

**Done when** accepting a task in the toolbar produces a Linear issue whose URL
comes back on the card, and with `auto_resolve` on, the resolver picks it up.

---

## Two things you will trip over

**The graph extractor truncates.** `services/graph/extract.py` cuts its input
at `MAX_TEXT = 9000` characters, summary first. That is about fifteen minutes
of speech, and the end of a brainstorm is where the decisions get made. Raise
it or extract in windows before concluding the extractor is bad at brainstorms.
Measure the change on the same transcript rather than guessing.

**Macedonian.** `signals.tsv` is built with `to_tsvector('english', ...)`, so
Cyrillic lands as raw tokens with no stemming. Semantic retrieval is unaffected
because it runs on the embedding. Do not "fix" it without measuring; just know
it before someone reports that search is weak.

---

## Guardrails

- Work on your own branch, off current `main`.
- **Stage and commit only the files you changed.** Never `git add -A`, never
  `git commit -a`. The index is shared across branch switches, and that is
  exactly how the ingest endpoint ended up inside a commit about draft PRs.
- One commit per task, with a message that describes what that commit does.
- No secrets in the repo, in logs, or in error messages.
- Import existing functions instead of reimplementing them. If a function needs
  to be public, drop the underscore in the same commit rather than copying it.
- If a task turns out to be wrong or already done, say so and stop. Do not
  build around a false premise.
