# WSI-Luau

White Sands agent player for Roblox. Your game describes an NPC in Luau: what it can see and what it can do. The White Sands platform runs the model and picks one action per turn. The model and its API keys stay on the platform, so the game only holds a platform key.

It speaks protocol version 1, the same contract as the Node, Python, .NET and C++ SDKs. It connects to `wss://api.whitesandsint.com` with Roblox's built-in WebSocket client (`HttpService:CreateWebStreamClient`), so you don't need a bridge server.

## Setup

1. Turn on **File → Experience Settings → Security → Allow HTTP Requests**.
2. Put the module in `ServerScriptService` as a ModuleScript named `WSI`, with `Json` as its child. You can copy `src/` in by hand, sync it with Rojo (`default.project.json`), or install it with Wally (`wally.toml`).
3. Create a platform key in the White Sands web app. Store it where only the server can read it, such as a `StringValue` at `ServerStorage.WSIPlatformKey`.

WSI runs on the server only. Requiring it from a LocalScript raises an error.

> Roblox Secrets (`HttpService:GetSecret`) can't hold the key yet. A Secret can only go into HTTP headers and URLs, and the platform reads the key from the first WebSocket message. Anyone with edit access to the place can read a key stored in `ServerStorage`, so use one key per game and revoke it if it leaks.

## Usage

```lua
local WSI = require(game.ServerScriptService.WSI)

local client = WSI.new({ platformKey = game.ServerStorage.WSIPlatformKey.Value })

local agent, err = client:start({
	name = "Guide",
	goal = "Greet players and answer their questions.",
	see = function()
		return { players = nearbyPlayers(), heard = recentChat() }
	end,
	actions = {
		{
			name = "say",
			description = "Say one short line in a speech bubble.",
			params = { { name = "text", type = "string" } },
			run = function(text)
				showBubble(text)
				return { said = text }
			end,
		},
		{
			name = "walk_to",
			description = "Walk to a place.",
			params = { { name = "place", type = "string", enum = { "spawn", "shop" } } },
			run = function(place)
				walkTo(place)
			end,
		},
	},
})
assert(agent, err)
-- On failure start also returns a code: "AUTH" for a bad or revoked key,
-- "PROTOCOL" for an unsupported version, nil for a network failure.

-- Yields until the platform has played one action.
local result = agent:turn()
-- { ok = true, action = "say", args = { text = "Hi!" }, result = { said = "Hi!" }, attempts = 1, usage = {...} }
```

### `see`

`see` returns the NPC's view as a table. It must be JSON-safe. A `Vector3` becomes `{x, y, z}`, a `CFrame` becomes its position, and an `EnumItem` or `Instance` becomes its name. Keep the view small: it's sent to the model on every turn, so its size sets your token cost.

The SDK adds a `done` list with the NPC's last 20 actions (`doneLimit` changes this, and `0` turns it off).

### Actions

| Field | |
| --- | --- |
| `name` | Tool name. `see` and `wait` are reserved. |
| `description` | Tells the model when to use it. |
| `params` | List of `{ name, type, description?, optional?, enum? }`. `type` is `string`, `number`, `integer` or `boolean`. |
| `run` | Gets the arguments in `params` order, then the whole args table. Return a JSON-safe value, or nothing for `{ ok = true }`. |

To reject an action, call `error("reason", 0)`. The platform shows the reason to the model, and the model gets one retry. Arguments are checked against `params` before `run` is called.

Return from `run` quickly. While `run` is running the turn is still open, so start long behaviour (walking, following) and return. Report when it finishes on the next turn.

### Turns

The game decides when the NPC acts. The platform decides what it does.

| Call | |
| --- | --- |
| `agent:turn(timeout?)` | Grants one turn and yields until it's played. Returns a result with `ok`, `action`, `args`, `result`, `error`, `attempts` and `usage`. It doesn't throw. A failed turn has `ok = false`. The timeout defaults to 60 seconds. |
| `agent:requestTurn(callback?)` | Same, but returns at once. Returns `false` if a turn is already running. |
| `agent:isBusy()` | `true` while a turn is running. |
| `agent:subgoals()` | Subgoals the model added this session. |
| `agent:on(fn)` | Events: `action`, `retry`, `subgoal`, `turnFailed` and `sessionLost`. Returns an unsubscribe function. |
| `agent:stop()` | Ends the session and yields until the platform confirms it. Returns `true`, or `false` and an error. |

### Several characters on one key

Roblox allows at most 4 WebSocket clients per game server, so don't create one client per NPC. Use one client, and give each NPC's session the **character ID** of its character with `playerId`. Copy the IDs from the Players page in the web app. Each session then runs on that character's model and persona, and its usage is charged to that character:

```lua
local client = WSI.new({ platformKey = key })
local bruno = client:start({ name = "Bruno", playerId = "3f6c2d1e-8b7a-4c5d-9e0f-1a2b3c4d5e6f", goal = "...", see = seeBruno, actions = brunoActions })
local zora = client:start({ name = "Madame Zora", playerId = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", goal = "...", see = seeZora, actions = zoraActions })
```

- The character must be on the same account as the key, and in the same game when the key's own character belongs to one.
- The ID never changes, so renaming a character in the web app doesn't break the game.
- If the ID doesn't match, `start` returns `nil` and an error that lists the characters this key can use, with their IDs.

Trigger turns from game events, such as a player chatting nearby, walking up, or a task finishing. Avoid triggering them on a timer. That way an idle server costs nothing.

### Memory, relationships, and several actions per turn

```lua
local agent = client:start({ name = "Mia", playerId = id, memory = true, maxActions = 3, see = see, actions = actions })
agent:observe('Alex said to you: "Morning!"', "Alex") -- kept in memory, does not start a turn
agent:relationships() -- { alex = { about = "Alex", affinity = 12, label = "acquaintance", note = "brought me coffee" } }
```

With `memory = true` the platform keeps what the character saw, did, and chose to remember, and how it feels about each person, between sessions and servers. `agent:on` also reports `memory` and `relationship` events. With `maxActions` above 1, a turn can play several actions (say, then walk); `result.steps` lists them.

### WSI.World

`WSI.World` builds a living world on top of this, so a game does not write a view or actions per character. Describe places, things with activities, and characters; World works out what each character sees, gives it `say`, `go_to`, `approach`, `use`, `give`, `emote` and `idle`, carries speech between characters and players, and decides when a character needs a turn. `WSI.RobloxBody` is a ready body: an R15 rig with pathfinding, emotes, a filtered speech bubble, and a status line.

```lua
local world = WSI.World.new(client, { name = "Sandy Shores", about = "A small beach town.", needs = { food = { perMinute = 2 } } })
world:addPlace("cafe", { description = "Mia's cafe", position = Vector3.new(60, 0, 0) })
world:addThing("espresso_machine", { place = "cafe", position = Vector3.new(64, 0, -4), activities = {
	make_coffee = { description = "Make a coffee", seconds = 6, gives = "coffee" },
} })
world:addCharacter({ id = miaCharacterId, name = "Mia", home = "cafe", body = WSI.RobloxBody.new({ name = "Mia", position = Vector3.new(60, 0, 4) }) })
world:addPerson({ name = player.DisplayName, getPosition = function() return rootPosition(player) end })
world:on(function(event) --[[ speech, relationship, status, give, thinking, turn ]] end)
world:start()

player.Chatted:Connect(function(message) world:say(player.DisplayName, message) end)
```

Who each character is comes from its story in the web app. `src/World.luau` documents the options, and `tests/World.spec.luau` runs it under Lune.

### Client

| Option | Default | |
| --- | --- | --- |
| `platformKey` | required | `pk_...` from the web app. |
| `platformUrl` | `wss://api.whitesandsint.com` | Point this at a self-hosted platform. |
| `instructions` | SDK default | Replaces the base agent instructions. Per-NPC `instructions` are appended to it. |
| `doneLimit` | `20` | Actions kept in each view's `done` list. |
| `turnTimeout` | `60` | Seconds. |
| `onEvent` | | Receives every agent's events, plus `disconnected`, `reconnected` and `connectionLost`. |
| `debug` | `false` | Prints connection and turn details. |

One client holds one connection for any number of NPCs. A dropped connection reconnects with backoff and resumes sessions within 30 seconds, then emits `reconnected`. A session the platform can't resume emits `sessionLost` and is ended, so its `turn()` fails at once. The client closes itself on server shutdown.

`client:connect()` logs in without starting a session. `start()` calls it for you. It returns `ok, error, code`, with the same codes as `start`.

## Contract test

The platform's SDK contract scenario (`platform/contract/README.md` in the Platform repo) runs against this SDK in Platform CI. It runs under [Lune](https://github.com/lune-org/lune), with a small stand-in for the Roblox APIs the SDK uses. To run it locally against a checkout of this repo:

```bash
DATABASE_URL=postgres://... WSI_LUAU_SRC=$PWD \
  path/to/Platform/platform/contract/run.sh -- path/to/Platform/platform/e2e/luau/run.sh
```

## Example

`examples/Guide.server.luau` is a Guide NPC for a spawn area. It:

- hears chat within 40 studs and greets players who walk up
- replies in a filtered speech bubble
- follows a player, stays put, walks to named places with pathfinding, and jumps

It plays a turn only when something happens.

Roblox requires text shown to players to be filtered. The example passes everything the NPC says through `TextService:FilterStringAsync`. Do the same in your own NPCs.
