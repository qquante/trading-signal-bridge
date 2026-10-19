# Trading Signal Bridge

> **Local private review:** publication is paused. See [security review and remaining release conditions](docs/SECURITY_REVIEW.md). Local fixes have not been pushed.


A Python and MQL5 bridge for relaying trading signals between a local server and MetaTrader clients.

![review](https://img.shields.io/badge/review-private-374151) ![primary](https://img.shields.io/badge/primary-Python-2563EB) [![LinkedIn](https://img.shields.io/badge/LinkedIn-Douglas%20Silva-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/in/douglas-silva-data-analyst/)

[Overview](#overview) · [Architecture](#architecture) · [Setup](#setup) · [Validation](#validation) · [Roadmap](#roadmap) · [Review notes](docs/REVIEW.md)

## Overview

- HTTP endpoints accept master-side signal messages.
- A TCP path relays updates to connected clients.
- MQL5 expert-advisor source implements master/slave integrations.

**Technology:** Python · FastAPI · TCP/HTTP · SQLite · MQL5 · MetaTrader 5

**Persistence and data:** The Python database module persists local signal/server state. Client execution occurs inside MetaTrader.

## Architecture

```text
Master EA signal → Python HTTP/TCP bridge → connected slave EA → configured trading terminal
```

| Location | Review focus |
| --- | --- |
| [`mt5_copy_server.py`](mt5_copy_server.py) | Source/configuration inspected for scope and structure |
| [`webhook_server.py`](webhook_server.py) | Source/configuration inspected for scope and structure |
| [`database.py`](database.py) | Source/configuration inspected for scope and structure |
| [`SniperGold.mq5`](SniperGold.mq5) | Source/configuration inspected for scope and structure |
| [`SlaveTrader.mq5`](SlaveTrader.mq5) | Source/configuration inspected for scope and structure |

Internal package and module names are retained where changing them would affect imports or compatibility. This descriptive repository name does not imply a completed package/API migration.

## Setup

Inspect requirements.txt and the message protocol. Python syntax inspection is independent of MetaTrader; do not attach the EAs to a live account to review the source.

Start from an isolated environment. Use `.env.example` when present and inspect the configuration loader: an example file is not necessarily loaded automatically. Runtime databases, real account sessions and private credentials are not bundled. Live integration prerequisites are separate from local tests.

## Validation

Static parsing checked 4 Python files and 0 strict JSON files. Python syntax errors: 0; JSON errors: 0. No functional test/build result is claimed for this preparation.

Available test scripts are inventoried in [the review notes](docs/REVIEW.md). Choose offline checks before operating any integration.

These results apply to the selected checks on the preparation copy. They do not establish deployment readiness, full coverage, live provider availability or measured performance. CI definitions, when present under `docs/ci-templates/`, are inactive review templates; no remote CI badge is claimed.

## Limits and current status

Slave expert advisors can execute real trades when attached to a configured terminal. No terminal, server or order was started. MQL5 compilation requires MetaEditor and was not performed.

This private snapshot is for code and portfolio review. Generated runtime material and unreviewed binary assets may be excluded. [Review notes](docs/REVIEW.md) record preparation scope, findings and outstanding validation.

## Roadmap

- [ ] Create fixture-only protocol tests for message parsing and replay.
- [ ] Review authentication, sizing and duplicate-signal handling.
- [ ] Compile and validate only in a separate demo-account environment.

## History and attribution

No recoverable original Git history was verified for this snapshot. Import and preparation commits use their actual current dates; filesystem timestamps are not treated as development dates.

No open-source license is granted by this preparation. A license and attribution review is required before public redistribution.

## Maintainer and feedback

Douglas de Oliveira Silva · [GitHub](https://github.com/qquante) · [LinkedIn](https://www.linkedin.com/in/douglas-silva-data-analyst/)

For this private review, report reproducible issues with a minimal fixture and the exact check output. Keep account data, credentials and generated sensitive reports out of issues and commits. Existing contribution guidelines apply where present.

**Topics:** `python`, `mql5`, `metatrader5`, `fastapi`, `tcp`, `automation`, `trading-tools`
