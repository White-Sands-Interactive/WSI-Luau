# Changelog

## 0.2.0

- `client:start{}` takes an optional `playerId`: the character ID from the web app's Players page. One key and one connection can now run several characters, each on its own model and persona. Roblox allows at most 4 WebSocket clients per game server, so a game with more NPCs than that needs this. It needs a platform with WSI-211; an older platform ignores `playerId` and uses the key's own character.

## 0.1.0

First release of the Roblox SDK. It speaks protocol version 1, like the Node, Python, .NET and C++ SDKs.

- Connects to `wss://api.whitesandsint.com` with Roblox's built-in WebSocket client (`HttpService:CreateWebStreamClient`). No bridge server is needed.
- Agents are described in Luau: `client:start({ name, goal, see, actions })`. This matches the shape of the Luanti `wsi_npc` mod.
- Each action declares typed params (`string`, `number`, `integer`, `boolean`, optional, `enum`). Arguments are checked before `run` is called.
- `agent:turn()` yields until the turn is played. `agent:requestTurn()` returns at once and takes a callback.
- Each view gets a `done` list of the last 20 actions, kept in memory per session.
- Subgoals the model adds are tracked and available from `agent:subgoals()`.
- Heartbeat, reconnect with backoff, and session resume within 30 seconds.
- The client closes itself on server shutdown.
- Includes an example Guide NPC (`examples/Guide.server.luau`). It talks, follows, stays, jumps and walks to places with pathfinding. It plays a turn only when something happens.

### Tested

Tested in Roblox Studio playtests against the hosted platform:

- logging in, and the error for a rejected key
- starting a session
- greeting, chat-triggered turns, and an action that finishes on a later turn

### Not yet tested

- live Roblox servers, as opposed to Studio
- reconnect and resume after a dropped connection
- several NPCs on one client

There are no automated tests yet.

### Known limits

- The platform key can't be kept in Roblox Secrets yet, because the platform reads it from the `hello` message (WSI-209).
- `doneLimit` keeps actions in memory only. Other SDKs keep them in SQLite.
