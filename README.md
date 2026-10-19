# Trading Signal Bridge

A Python and MQL5 bridge for relaying trading signals between a local server and MetaTrader clients.

## Features

- HTTP endpoints accept master-side signal messages.
- A TCP path relays updates to connected clients.
- MQL5 expert-advisor source implements master/slave integrations.

## Stack

Python · FastAPI · TCP/HTTP · SQLite · MQL5 · MetaTrader 5

The Python database module persists local signal/server state. Client execution occurs inside MetaTrader.

## Getting started

Inspect requirements.txt and the message protocol. Python syntax inspection is independent of MetaTrader; do not attach the EAs to a live account to review the source.

## How it works

```text
Master EA signal → Python HTTP/TCP bridge → connected slave EA → configured trading terminal
```

## Current limitations

Slave expert advisors can execute real trades when attached to a configured terminal. No terminal, server or order was started. MQL5 compilation requires MetaEditor and was not performed.

## License

No open-source license has been granted. Redistribution terms remain to be defined.
