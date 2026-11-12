--!nonstrict
-- Checks WSI.World with a fake client and fake bodies, under Lune:
--   lune run tests/World.spec.luau
local task = require("@lune/task")
local World = require("../src/World")

local function vec(x, z)
	local v = { X = x, Z = z }
	return setmetatable(v, {
		__sub = function(a, b)
			local d = vec(a.X - b.X, a.Z - b.Z)
			d.Magnitude = math.sqrt(d.X * d.X + d.Z * d.Z)
			d.Unit = d
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
	local body = { at = vec(x, z), said = {}, moves = 0 }
	function body:getPosition()
		return self.at
	end
	function body:moveTo(goal)
		self.moves += 1
		task.wait(0.05)
		self.at = goal
		return true
	end
	function body:stop() end
	function body:say(text)
		table.insert(self.said, text)
		return text
	end
	return body
end

-- A client whose agents play a scripted list of actions, one per turn.
local function newClient(scripts)
	local client = { defs = {}, observed = {} }
	function client:start(def)
		client.defs[def.name] = def
		client.observed[def.name] = {}
		local agent = { busy = false, turns = 0, views = {} }
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
			if self.busy then
				return false
			end
			self.busy = true
			task.spawn(function()
				self.turns += 1
				table.insert(self.views, def.see())
				local step = table.remove(scripts[def.name] or {}, 1) or { "idle" }
				local result = { ok = true, action = step[1] }
				for _, action in def.actions do
					if action.name == step[1] then
						local ok, value = pcall(action.run, table.unpack(step, 2))
						result.ok, result.result, result.error = ok, ok and value or nil, not ok and value or nil
					end
				end
				self.busy = false
				callback(result)
			end)
			return true
		end
		client.agents = client.agents or {}
		client.agents[def.name] = agent
		return agent
	end
	return client
end

local function check(condition, message)
	if not condition then
		error(message, 0)
	end
end

local client = newClient({
	Mia = { { "say", "Hi Alex!", "Alex" }, { "use", "stove", "cook" }, { "go_to", "beach" } },
	Finn = { { "idle" } },
})
local world = World.new(client, {
	name = "Test Town",
	idleSeconds = 600,
	needs = { food = { perMinute = 1, start = 40 } },
})
world:addPlace("cafe", { description = "A cafe", position = vec(0, 0) })
world:addPlace("beach", { description = "The beach", position = vec(200, 0) })
world:addThing("stove", { place = "cafe", position = vec(2, 0), activities = {
	cook = { description = "Cook a meal", seconds = 0.2, effects = { food = 50 }, gives = "meal" },
} })
local miaBody, finnBody = newBody(0, 0), newBody(300, 0)
local mia = world:addCharacter({ id = "mia-id", name = "Mia", body = miaBody, home = "cafe" })
local finn = world:addCharacter({ id = "finn-id", name = "Finn", body = finnBody })
mia._wake, finn._wake = nil, nil
local alexAt = vec(60, 0)
world:addPerson({ name = "Alex", getPosition = function()
	return alexAt
end })
local speech = {}
world:on(function(event)
	if event.type == "speech" then
		table.insert(speech, event)
	end
end)
world:start()

check(string.find(client.defs.Mia.instructions, "cafe: A cafe (your home)", 1, true), "guide lists places and home")
check(client.defs.Mia.memory == true and client.defs.Mia.maxActions == 3, "sessions use memory and several actions")

-- Out of earshot: nobody hears, nobody gets a turn.
check(world:say("Alex", "Anyone there?") == 0, "speech out of range is not heard")
task.wait(0.8)
check(client.agents.Mia.turns == 0, "no turn without a reason")

-- Walking up is noticed; speaking gives the closest resident a turn.
alexAt = vec(5, 0)
task.wait(0.8)
check(table.find(client.observed.Mia, "Alex walked up to you."), "arrival is noticed")
world:say("Alex", "Hello!")
task.wait(2.5)
check(client.agents.Mia.turns >= 1, "Mia took a turn")
local view = client.agents.Mia.views[1]
check(view.you.at == "cafe", "view knows the place")
check(view.people_nearby[1].name == "Alex" and view.people_nearby[1].who == "player", "view lists Alex")
check(view.things_here[1].thing == "stove", "view lists the stove")
local sawHello = false
for _, line in view.why_you_are_acting_now do
	sawHello = sawHello or line == 'Alex said to you: "Hello!"'
end
check(sawHello, "the reason for the turn is in the view")
check(miaBody.said[1] == "Hi Alex!", "Mia spoke")
check(speech[#speech].speaker == "Mia" and speech[#speech].to == "Alex", "speech event reaches the game")
check(client.agents.Finn.turns == 0, "a far resident is not disturbed")

-- Next turn she cooks; the result arrives as a new reason to act.
mia:notice("test: act again", { urgent = true })
task.wait(2)
check(table.find(mia.carrying, "meal"), "activity gives an item")
check(mia.needs.food > 85, "activity raises the need, got " .. mia.needs.food)
check(table.find(client.observed.Mia, "You finished: cook at stove (food is now 89, you now carry meal)."), "finish is observed: " .. table.concat(client.observed.Mia, " | "))
task.wait(2.5)
check(mia:place() == "beach", "go_to walked to the beach")
world:stop()
print("World.spec: ok")
