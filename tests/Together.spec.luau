--!nonstrict
-- Checks doing things together in WSI.World: shared activities, join,
-- invite, follow, give from a distance, the empty-world pause and turn retry.
--   lune run tests/Together.spec.luau
local task = require("@lune/task")
local World = require("../src/World")

local function vec(x, z)
	local v = { X = x, Z = z }
	return setmetatable(v, {
		__sub = function(a, b)
			local d = vec(a.X - b.X, a.Z - b.Z)
			d.Magnitude = math.sqrt(d.X * d.X + d.Z * d.Z)
			d.Unit = d.Magnitude > 0 and vec(d.X / d.Magnitude, d.Z / d.Magnitude) or d
			return d
		end,
		__add = function(a, b)
			return vec(a.X + b.X, a.Z + b.Z)
		end,
		__mul = function(a, k)
			return vec(a.X * k, a.Z * k)
		end,
	})
end

local function newBody(x, z)
	local body = { at = vec(x, z), said = {}, emotes = {} }
	function body:getPosition()
		return self.at
	end
	function body:moveTo(goal)
		task.wait(0.05)
		self.at = goal
		return true
	end
	function body:walkToward(goal)
		self.at = goal
	end
	function body:stop() end
	function body:say(text)
		table.insert(self.said, text)
		return text
	end
	function body:emote(name, seconds)
		table.insert(self.emotes, { name, seconds })
	end
	return body
end

-- A fake client: the test calls actions directly, and turns can be made to fail.
local function newClient()
	local client = { defs = {}, observed = {}, agents = {}, fail = 0 }
	function client:start(def)
		client.defs[def.name] = def
		client.observed[def.name] = {}
		local agent = { busy = false, turns = 0 }
		function agent:isBusy()
			return self.busy
		end
		function agent:observe(text)
			table.insert(client.observed[def.name], text)
		end
		function agent:relationships()
			return {}
		end
		function agent:on() end
		function agent:requestTurn(callback)
			self.turns += 1
			task.spawn(function()
				if client.fail > 0 then
					client.fail -= 1
					callback({ ok = false, error = "vendor reset" })
				else
					callback({ ok = true })
				end
			end)
			return true
		end
		client.agents[def.name] = agent
		return agent
	end
	return client
end

local function action(client, character, name)
	for _, a in client.defs[character].actions do
		if a.name == name then
			return a.run
		end
	end
	error("no action " .. name)
end

local function check(condition, message)
	if not condition then
		error(message, 0)
	end
end

local function observed(client, name, text)
	for _, line in client.observed[name] do
		if string.find(line, text, 1, true) then
			return true
		end
	end
	return false
end

local client = newClient()
local world = World.new(client, { name = "Test Town", idleSeconds = 600, retrySeconds = 0.2, followSeconds = 1.5 })
world:addPlace("plaza", { position = vec(0, 0), radius = 20 })
world:addPlace("pier", { position = vec(100, 0), radius = 20 })
world:addThing("boombox", { place = "plaza", position = vec(2, 0), activities = {
	dance = { description = "Dance", seconds = 0.4, shared = true, emote = "dance", effects = {} },
} })
world:addThing("bed", { place = "plaza", position = vec(-5, 0), activities = {
	sleep = { description = "Sleep", seconds = 0.2 },
} })
world:addThing("rod", { place = "pier", position = vec(100, 0), activities = {
	fish = { description = "Fish", seconds = 0.3, shared = true, gives = "fish" },
} })
local junoBody, finnBody = newBody(0, 5), newBody(60, 0)
local juno = world:addCharacter({ id = "juno", name = "Juno", body = junoBody })
local finn = world:addCharacter({ id = "finn", name = "Finn", body = finnBody })
local alexAt = vec(1, 1)
world:addPerson({ name = "Alex", getPosition = function()
	return alexAt
end })
local events = {}
world:on(function(event)
	table.insert(events, event)
end)
local function sawEvent(kind)
	for _, e in events do
		if e.type == kind then
			return e
		end
	end
	return nil
end

check(string.find(client.defs.Juno.instructions, "invite them", 1, true), "guide explains doing things together")

-- A player starts dancing; Juno joins and they dance together.
world:personActivity("Alex", "boombox", "dance")
check(observed(client, "Juno", "Alex started dancing at the boombox") or observed(client, "Juno", "Alex started dance at the boombox"), "a nearby character sees the player start: " .. table.concat(client.observed.Juno, " | "))
action(client, "Juno", "join")("Alex")
task.wait(0.15)
check(observed(client, "Juno", "You and Alex are dance together at the boombox."), "together is noticed: " .. table.concat(client.observed.Juno, " | "))
local together = sawEvent("together")
check(together and together.character == "Juno" and together.person == "Alex" and together.activity == "dance", "together event reaches the game")
check(junoBody.emotes[1][1] == "dance" and junoBody.emotes[1][2] == 0.4, "shared emote loops for the activity")
task.wait(0.5)
check(observed(client, "Juno", "together with Alex"), "finish names the companion")

-- join refuses when there is nothing to join.
world:personActivity("Alex", nil)
check(not pcall(action(client, "Juno", "join"), "Alex"), "join needs the player to be doing something")
-- only shared things can be invited to.
check(not pcall(action(client, "Juno", "invite"), "Alex", "bed", "sleep"), "invite needs a shared activity")

-- Finn invites Alex fishing: he goes and starts; Alex arrives and joins.
local result = action(client, "Finn", "invite")("Alex", "rod", "fish")
check(result.invited == "Alex", "invite returns who was invited")
local invite = sawEvent("invite")
check(invite and invite.from == "Finn" and invite.to == "Alex" and invite.thing == "rod" and invite.place == "pier", "invite event reaches the game")
task.wait(0.15)
alexAt = vec(99, 1)
world:personActivity("Alex", "rod", "fish")
task.wait(0.05)
check(observed(client, "Finn", "You and Alex are fish together at the rod."), "the invited player joining is together: " .. table.concat(client.observed.Finn, " | "))
task.wait(0.4)
check(table.find(finn.carrying, "fish"), "Finn caught a fish")
world:personActivity("Alex", nil)

-- give walks over by itself.
alexAt = vec(70, 0)
local gave = action(client, "Finn", "give")("fish", "Alex")
check(gave.walking_to == "Alex", "give from a distance walks over")
task.wait(0.2)
check(table.find(world.people.Alex.carrying, "fish"), "the item arrived")
check(observed(client, "Finn", "You walked over and gave fish to Alex."), "walk-and-give is noticed")

-- follow walks along and notices arriving somewhere together.
alexAt = vec(40, 0)
local followed = action(client, "Juno", "follow")("Alex")
check(followed.following == "Alex", "follow starts")
task.wait(0.5)
check((junoBody.at - alexAt).Magnitude < 8, "follower keeps up")
alexAt = vec(0, 0)
task.wait(3.2)
check(observed(client, "Juno", "arrived at plaza together") or observed(client, "Juno", "You stopped walking with Alex."), "follow reports: " .. table.concat(client.observed.Juno, " | "))
check(observed(client, "Juno", "You stopped walking with Alex."), "follow ends after followSeconds")

-- Turn failures retry soon, then back off.
world:start()
client.fail = 2
local before = client.agents.Juno.turns
juno:notice("test: act", { urgent = true })
task.wait(2.5)
check(client.agents.Juno.turns >= before + 3, "a failed turn is retried quickly, got " .. (client.agents.Juno.turns - before))
check(juno._failures == 0, "success resets the failure count")

-- No humans, no turns.
world:removePerson("Alex")
local frozen = client.agents.Finn.turns
finn:notice("test: act", { urgent = true })
task.wait(1.2)
check(client.agents.Finn.turns == frozen, "an empty world takes no turns")
world:stop()
print("Together.spec: ok")
