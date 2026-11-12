--!nonstrict
-- WSI.World: a living world on top of the agent player.
--
-- A game describes its world once: places, things characters can use, and
-- the characters themselves. World turns that into what each character sees
-- and can do, decides when a character needs a turn, and carries speech and
-- events between characters and human players. The game does not write a view
-- or an action per character. Who a character is comes from its story in the
-- White Sands web app.
--
--   local world = WSI.World.new(client, { name = "Sandy Shores", about = "A small beach town." })
--   world:addPlace("cafe", { description = "Mia's beach cafe", position = Vector3.new(40, 0, 10) })
--   world:addThing("espresso_machine", { place = "cafe", position = pos, activities = {
--       make_coffee = { description = "Make a coffee", seconds = 6, gives = "coffee" } } })
--   world:addCharacter({ id = "<character ID>", name = "Mia", body = WSI.RobloxBody.new({ ... }), home = "cafe" })
--   world:addPerson({ name = player.DisplayName, getPosition = function() ... end })
--   world:start()
--   world:say("Alex", "Hi Mia!")   -- a human player spoke
--
-- This module uses no Roblox API. A body is any table with:
--   getPosition() -> position        positions support a - b and .Magnitude
--   moveTo(position) -> boolean      yields until arrival; false if interrupted
--   stop()
--   say(text) -> string?             show the line; may return the filtered text
-- and optionally emote(name), face(position), setStatus(text), emotes = { "wave", ... }.

-- task is a global in Roblox. Under Lune, where the tests run, it is a library.
local task = task or (require :: any)("@lune/task")

local World = {}
World.__index = World

local Character = {}
Character.__index = Character

local DEFAULT_EMOTES = { "wave", "laugh", "cheer", "dance", "point", "shrug" }

local function clip(text: string, limit: number): string
	if #text <= limit then
		return text
	end
	return string.sub(text, 1, limit - 3) .. "..."
end

local function distance(a: any, b: any): number
	return (a - b).Magnitude
end

export type Activity = {
	description: string,
	-- How long it takes. Defaults to 5.
	seconds: number?,
	-- Shown while it runs, such as "making coffee". Defaults to the activity name.
	status: string?,
	-- Change to the character's needs when it finishes, such as { food = 40 }.
	effects: { [string]: number }?,
	-- An item the character is carrying afterwards.
	gives: string?,
	-- An item the character must carry. It is used up.
	needs: string?,
	-- Emote played while it runs.
	emote: string?,
	-- Called when it finishes, with the character and the thing.
	done: ((any, any) -> ())?,
}

export type Options = {
	name: string,
	-- One or two sentences about the world, for every character.
	about: string?,
	-- Extra rules of the game, in plain words.
	rules: string?,
	-- The time of day as text, such as "Tuesday 14:30, afternoon".
	clock: (() -> string)?,
	-- How far speech carries, and how far a character sees. Defaults 35 and 80.
	hearing: number?,
	sight: number?,
	-- A character with nothing to react to gets a turn about this often. Default 45.
	idleSeconds: number?,
	-- Idle turns are this many times rarer when no human is within activeRadius. Defaults 3 and 120.
	farSlowdown: number?,
	activeRadius: number?,
	-- A human who comes this close is noticed. Default 12. 0 turns it off.
	greetDistance: number?,
	-- Cap on turns per minute for the whole world. Default 30.
	turnsPerMinute: number?,
	-- Actions per turn, 1 to 4. Default 3.
	maxActions: number?,
	-- Needs every character has, such as { food = { perMinute = 3 } }. 100 is
	-- satisfied, 0 is desperate. perMinute is how fast it falls.
	needs: { [string]: { perMinute: number, start: number? } }?,
	-- Keep memory and relationships on the platform. Default true.
	memory: boolean?,
}

function World.new(client: any, options: Options)
	assert(client, "World.new: a WSI client is required")
	assert(type(options) == "table" and type(options.name) == "string", "World.new: options.name is required")
	return setmetatable({
		client = client,
		name = options.name,
		about = options.about or "",
		rules = options.rules or "",
		clock = options.clock,
		hearing = options.hearing or 35,
		sight = options.sight or 80,
		idleSeconds = options.idleSeconds or 45,
		farSlowdown = options.farSlowdown or 3,
		activeRadius = options.activeRadius or 120,
		greetDistance = if options.greetDistance == nil then 12 else options.greetDistance,
		turnsPerMinute = options.turnsPerMinute or 30,
		maxActions = options.maxActions or 3,
		needDefs = options.needs or {},
		memory = options.memory ~= false,
		places = {},
		placeOrder = {},
		things = {},
		thingOrder = {},
		characters = {},
		characterOrder = {},
		people = {},
		turnsUsed = 0,
		turnLog = {},
		_listeners = {},
		_running = false,
		_budget = 0,
		_budgetAt = os.clock(),
	}, World)
end

--- Listen for world events. Returns a function that unsubscribes. Event types:
--- speech { speaker, text, to }, status { character, status },
--- relationship { character, about, affinity, label, change, because },
--- memory { character, about, note }, action { character, action, args },
--- thinking { character, on }, give { from, to, item }, turn { character, result }.
function World:on(listener: (any) -> ()): () -> ()
	table.insert(self._listeners, listener)
	return function()
		local index = table.find(self._listeners, listener)
		if index then
			table.remove(self._listeners, index)
		end
	end
end

function World:_emit(event: any)
	for _, listener in table.clone(self._listeners) do
		task.spawn(listener, event)
	end
end

function World:addPlace(name: string, place: { description: string?, position: any, radius: number? })
	assert(not self.places[name], "place already exists: " .. name)
	self.places[name] = { name = name, description = place.description or "", position = place.position, radius = place.radius or 22 }
	table.insert(self.placeOrder, name)
end

function World:addThing(id: string, thing: { name: string?, place: string?, position: any, activities: { [string]: Activity } })
	assert(not self.things[id], "thing already exists: " .. id)
	self.things[id] = {
		id = id,
		name = thing.name or id,
		place = thing.place,
		position = thing.position,
		activities = thing.activities or {},
		usedBy = nil,
	}
	table.insert(self.thingOrder, id)
end

--- Add a human player. getPosition returns their position, or nil while they have no body.
function World:addPerson(person: { name: string, getPosition: () -> any, ref: any? })
	self.people[person.name] = { name = person.name, getPosition = person.getPosition, ref = person.ref, kind = "player", carrying = {} }
	return self.people[person.name]
end

function World:removePerson(name: string)
	self.people[name] = nil
end

function World:placeAt(position: any): string?
	local best, bestDistance = nil, math.huge
	for _, name in self.placeOrder do
		local place = self.places[name]
		local d = distance(place.position, position)
		if d <= place.radius and d < bestDistance then
			best, bestDistance = name, d
		end
	end
	return best
end

function World:_positionOf(name: string): any
	local character = self.characters[name]
	if character then
		return character.body:getPosition()
	end
	local person = self.people[name]
	if person then
		return person.getPosition()
	end
	return nil
end

-- Match a name the model wrote to someone in the world, ignoring case.
function World:_resolve(name: string?): string?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local lower = string.lower(name)
	for known in self.characters do
		if string.lower(known) == lower then
			return known
		end
	end
	for known in self.people do
		if string.lower(known) == lower then
			return known
		end
	end
	return nil
end

function World:_humanNear(position: any, range: number): boolean
	for _, person in self.people do
		local at = person.getPosition()
		if at and distance(at, position) <= range then
			return true
		end
	end
	return false
end

function World:guide(character: any): string
	local lines = {
		"You are a character who lives in " .. self.name .. ". " .. self.about,
		"You are not an assistant. You are a person with your own life, moods, and plans. Stay in character at all times.",
		"",
		"How you act:",
		"- You act only through tools. To speak, call say. Keep a line to one or two short sentences, the way people talk.",
		"- Each turn shows why you are acting now, who is near you, and what you can use where you are.",
		"- You can speak and then act in the same turn, for example say and then go_to.",
		"- go_to, approach and use take time. You are told when they finish. Do not repeat them while they are under way.",
		"- When someone speaks to you, answer them. When nothing needs doing, carry on with your day the way your story says, or call idle.",
		"- Do not repeat yourself. Check your recent events before you speak.",
		"- People you do not know are strangers. Treat people the way you feel about them.",
		"",
		"Places:",
	}
	for _, name in self.placeOrder do
		local place = self.places[name]
		local line = "- " .. name
		if place.description ~= "" then
			line ..= ": " .. place.description
		end
		if character.home == name then
			line ..= " (your home)"
		end
		table.insert(lines, line)
	end
	if next(self.needDefs) then
		table.insert(lines, "")
		table.insert(lines, "Your needs run from 0 (desperate) to 100 (satisfied) and fall over time. Look after them with the things around you.")
	end
	if self.rules ~= "" then
		table.insert(lines, "")
		table.insert(lines, self.rules)
	end
	return table.concat(lines, "\n")
end

----------------------------------------------------------------------------
-- Characters

function World:addCharacter(def: {
	id: string,
	name: string,
	body: any,
	home: string?,
	goal: string?,
	instructions: string?,
	carrying: { string }?,
	actions: { any }?,
})
	assert(type(def.name) == "string" and def.body, "addCharacter: name and body are required")
	assert(not self.characters[def.name], "character already exists: " .. def.name)
	local character = setmetatable({
		world = self,
		name = def.name,
		kind = "resident",
		body = def.body,
		home = def.home,
		status = nil,
		carrying = table.clone(def.carrying or {}),
		needs = {},
		_needWarned = {},
		_inbox = {},
		_wake = os.clock() + 2 + math.random() * 6,
		_task = 0,
		_greeted = {},
		_chat = { count = 0, resetAt = 0 },
		_using = nil,
		turns = 0,
		tokens = 0,
	}, Character)
	for need, spec in self.needDefs do
		character.needs[need] = spec.start or (55 + math.random(0, 35))
	end
	self.characters[def.name] = character
	table.insert(self.characterOrder, def.name)

	local instructions = self:guide(character)
	if def.instructions and def.instructions ~= "" then
		instructions ..= "\n\n" .. def.instructions
	end
	local agent, err = self.client:start({
		name = def.name,
		playerId = def.id,
		goal = def.goal,
		instructions = instructions,
		memory = self.memory,
		maxActions = self.maxActions,
		see = function()
			return character:_view()
		end,
		actions = character:_actions(def.actions),
	})
	if not agent then
		self.characters[def.name] = nil
		table.remove(self.characterOrder, table.find(self.characterOrder, def.name))
		return nil, err
	end
	character.agent = agent
	agent:on(function(event)
		if event.type == "relationship" and not event.error and event.args then
			self:_emit({
				type = "relationship",
				character = character.name,
				about = self:_resolve(event.args.about) or event.args.about,
				affinity = event.args.affinity,
				label = event.args.label,
				change = event.args.change,
				because = event.args.because,
			})
		elseif event.type == "memory" and not event.error and event.args then
			self:_emit({ type = "memory", character = character.name, about = event.args.about, note = event.args.note })
		elseif event.type == "action" then
			self:_emit({ type = "action", character = character.name, action = event.action, args = event.args })
		elseif event.type == "sessionLost" then
			warn("[WSI.World] " .. character.name .. " lost its session: " .. tostring(event.error))
		end
	end)
	return character
end

function Character:position(): any
	return self.body:getPosition()
end

function Character:place(): string?
	return self.world:placeAt(self:position())
end

function Character:setStatus(status: string?)
	self.status = status
	if self.body.setStatus then
		pcall(self.body.setStatus, self.body, status)
	end
	self.world:_emit({ type = "status", character = self.name, status = status })
end

--- Tell this character something happened. It goes into its memory and its
--- next view. turn = true asks for a turn; urgent = true asks for one now.
function Character:notice(text: string, options: { about: string?, turn: boolean?, urgent: boolean? }?)
	options = options or {}
	table.insert(self._inbox, text)
	while #self._inbox > 12 do
		table.remove(self._inbox, 1)
	end
	if self.agent then
		self.agent:observe(text, options.about)
	end
	if options.urgent then
		self:_wakeIn(0.2)
	elseif options.turn then
		self:_wakeIn(1.5)
	end
end

function Character:_wakeIn(seconds: number)
	local at = os.clock() + seconds
	if not self._wake or at < self._wake then
		self._wake = at
	end
end

-- How this character feels about someone, from the platform.
function Character:feelingFor(name: string): (number, string)
	local relationships = self.agent and self.agent:relationships() or {}
	local relationship = relationships[string.lower(name)]
	if relationship then
		return relationship.affinity, relationship.label
	end
	return 0, "stranger"
end

function Character:_view()
	local world = self.world
	local here = self:position()
	local place = world:placeAt(here)
	local why = self._inbox
	self._inbox = {}
	if #why == 0 then
		why = { "Nothing new has happened. Carry on with your day." }
	end

	local nearby = {}
	local function addNearby(name: string, kind: string, at: any, doing: string?)
		if not at then
			return
		end
		local d = distance(at, here)
		if d <= world.sight then
			local _, label = self:feelingFor(name)
			table.insert(nearby, {
				name = name,
				who = kind,
				steps_away = math.floor(d + 0.5),
				can_hear_you = d <= world.hearing,
				doing = doing,
				you_feel = label,
			})
		end
	end
	for _, name in world.characterOrder do
		local other = world.characters[name]
		if other and other ~= self then
			addNearby(name, "resident", other:position(), other.status)
		end
	end
	for name, person in world.people do
		addNearby(name, "player", person.getPosition(), nil)
	end
	table.sort(nearby, function(a, b)
		return a.steps_away < b.steps_away
	end)
	while #nearby > 8 do
		table.remove(nearby)
	end

	local things = {}
	for _, id in world.thingOrder do
		local thing = world.things[id]
		local d = distance(thing.position, here)
		if (place and thing.place == place) or d <= 30 then
			local activities = {}
			for activityName, activity in thing.activities do
				local text = activityName .. ": " .. activity.description
				if activity.needs then
					text ..= " (needs " .. activity.needs .. ")"
				end
				table.insert(activities, text)
			end
			table.sort(activities)
			table.insert(things, {
				thing = id,
				activities = activities,
				in_use_by = thing.usedBy and thing.usedBy ~= self.name and thing.usedBy or nil,
			})
		end
		if #things >= 12 then
			break
		end
	end

	local needs = nil
	if next(self.needs) then
		needs = {}
		for need, value in self.needs do
			needs[need] = math.floor(value)
		end
	end

	return {
		time = world.clock and world.clock() or nil,
		why_you_are_acting_now = why,
		you = {
			at = place or "outdoors, between places",
			doing = self.status or "nothing in particular",
			needs = needs,
			carrying = #self.carrying > 0 and self.carrying or nil,
		},
		people_nearby = nearby,
		things_here = things,
	}
end

-- Stop whatever the body is doing so a new movement can start.
function Character:_interrupt(): number
	self._task += 1
	if self._using then
		self._using.usedBy = nil
		self._using = nil
	end
	self.body:stop()
	return self._task
end

function Character:_has(item: string): number?
	return table.find(self.carrying, item)
end

function Character:_walk(token: number, goal: any, status: string): boolean
	self:setStatus(status)
	local reached = self.body:moveTo(goal)
	if self._task ~= token then
		return false
	end
	self:setStatus(nil)
	return reached ~= false
end

function Character:_actions(custom: { any }?)
	local world = self.world
	local self_ = self
	local emotes = self.body.emotes or DEFAULT_EMOTES
	local actions = {
		{
			name = "say",
			description = "Say one or two short sentences out loud. Set to when you are talking to one person.",
			params = {
				{ name = "text", type = "string", description = "What you say, in your own voice." },
				{ name = "to", type = "string", description = "Name of the person you are talking to. Empty to talk to everyone near you." },
			},
			run = function(text, to)
				text = clip(tostring(text or ""), 240)
				if text == "" then
					error("say needs some text", 0)
				end
				local target = world:_resolve(to)
				local shown = self_.body:say(text, target and world:_positionOf(target))
				if type(shown) == "string" and shown ~= "" then
					text = shown
				end
				local heard = world:_speech(self_.name, text, target)
				if heard == 0 then
					return { said = text, note = "Nobody was close enough to hear you." }
				end
				return { said = text }
			end,
		},
		{
			name = "go_to",
			description = "Walk to a place. You are told when you arrive.",
			params = { { name = "place", type = "string", enum = table.clone(world.placeOrder) } },
			run = function(placeName)
				local place = world.places[placeName]
				if not place then
					error("no such place: " .. tostring(placeName), 0)
				end
				if self_:place() == placeName and not self_.status then
					error("you are already at " .. placeName, 0)
				end
				local token = self_:_interrupt()
				task.spawn(function()
					if self_:_walk(token, place.position, "walking to " .. placeName) then
						self_:notice("You arrived at " .. placeName .. ".", { turn = true })
					elseif self_._task == token then
						self_:notice("You could not get to " .. placeName .. ".", { turn = true })
					end
				end)
				return { walking_to = placeName }
			end,
		},
		{
			name = "approach",
			description = "Walk up to someone you can see, to talk or do something together.",
			params = { { name = "person", type = "string" } },
			run = function(person)
				local name = world:_resolve(person)
				local at = name and world:_positionOf(name)
				if not name or not at or name == self_.name then
					error("you cannot see anyone called " .. tostring(person), 0)
				end
				if distance(at, self_:position()) > world.sight then
					error(name .. " is too far away to see", 0)
				end
				if distance(at, self_:position()) <= 7 then
					return { note = "You are already next to " .. name .. "." }
				end
				local token = self_:_interrupt()
				task.spawn(function()
					local goal = world:_positionOf(name) or at
					local offset = self_:position() - goal
					if offset.Magnitude > 0.1 then
						goal = goal + offset.Unit * 4
					end
					if self_:_walk(token, goal, "walking over to " .. name) then
						self_:notice("You walked up to " .. name .. ".", { turn = true })
					end
				end)
				return { walking_to = name }
			end,
		},
		{
			name = "use",
			description = "Do an activity with a thing listed in things_here. You walk to it first. You are told when you finish.",
			params = {
				{ name = "thing", type = "string" },
				{ name = "activity", type = "string" },
			},
			run = function(thingId, activityName)
				local thing = world.things[thingId]
				if not thing then
					error("there is no thing called " .. tostring(thingId), 0)
				end
				local activity = thing.activities[activityName]
				if not activity then
					local names = {}
					for name in thing.activities do
						table.insert(names, name)
					end
					table.sort(names)
					error(thingId .. " has no activity " .. tostring(activityName) .. ". It has: " .. table.concat(names, ", "), 0)
				end
				if thing.usedBy and thing.usedBy ~= self_.name then
					error(thing.usedBy .. " is using " .. thingId .. " right now", 0)
				end
				if activity.needs and not self_:_has(activity.needs) then
					error("you need " .. activity.needs .. " to do that", 0)
				end
				local token = self_:_interrupt()
				local seconds = activity.seconds or 5
				thing.usedBy = self_.name
				self_._using = thing
				task.spawn(function()
					if distance(thing.position, self_:position()) > 6 then
						if not self_:_walk(token, thing.position, "walking to " .. thing.name) then
							if self_._task == token then
								thing.usedBy = nil
								self_._using = nil
								self_:notice("You could not reach " .. thingId .. ".", { turn = true })
							end
							return
						end
					end
					if self_.body.face then
						pcall(self_.body.face, self_.body, thing.position)
					end
					self_:setStatus(activity.status or string.gsub(activityName, "_", " "))
					if activity.emote and self_.body.emote then
						pcall(self_.body.emote, self_.body, activity.emote)
					end
					task.wait(seconds)
					if self_._task ~= token then
						return
					end
					thing.usedBy = nil
					self_._using = nil
					self_:setStatus(nil)
					local outcome = {}
					if activity.needs then
						local index = self_:_has(activity.needs)
						if index then
							table.remove(self_.carrying, index)
						end
					end
					for need, change in activity.effects or {} do
						if self_.needs[need] then
							self_.needs[need] = math.clamp(self_.needs[need] + change, 0, 100)
							table.insert(outcome, need .. " is now " .. math.floor(self_.needs[need]))
						end
					end
					if activity.gives then
						table.insert(self_.carrying, activity.gives)
						table.insert(outcome, "you now carry " .. activity.gives)
					end
					if activity.done then
						task.spawn(activity.done, self_, thing)
					end
					local text = "You finished: " .. string.gsub(activityName, "_", " ") .. " at " .. thing.name
					if #outcome > 0 then
						text ..= " (" .. table.concat(outcome, ", ") .. ")"
					end
					self_:notice(text .. ".", { turn = true })
				end)
				return { started = activityName, takes_seconds = seconds }
			end,
		},
		{
			name = "give",
			description = "Give something you are carrying to someone next to you.",
			params = {
				{ name = "item", type = "string" },
				{ name = "to", type = "string" },
			},
			run = function(item, to)
				local index = self_:_has(item)
				if not index then
					error("you are not carrying " .. tostring(item), 0)
				end
				local name = world:_resolve(to)
				local at = name and world:_positionOf(name)
				if not name or not at then
					error("you cannot see anyone called " .. tostring(to), 0)
				end
				if distance(at, self_:position()) > 12 then
					error(name .. " is too far away. Use approach first.", 0)
				end
				table.remove(self_.carrying, index)
				local other = world.characters[name]
				if other then
					table.insert(other.carrying, item)
					other:notice(self_.name .. " gave you " .. item .. ".", { about = self_.name, urgent = true })
				else
					table.insert(world.people[name].carrying, item)
				end
				world:_emit({ type = "give", from = self_.name, to = name, item = item })
				return { gave = item, to = name }
			end,
		},
		{
			name = "emote",
			description = "Show a feeling with your body.",
			params = { { name = "emote", type = "string", enum = table.clone(emotes) } },
			run = function(name)
				if self_.body.emote then
					self_.body:emote(name)
				end
				world:_emit({ type = "emote", character = self_.name, emote = name })
				return { did = name }
			end,
		},
		{
			name = "idle",
			description = "Do nothing new for now and carry on as you are.",
			params = {},
			run = function()
				return { ok = true }
			end,
		},
	}
	for _, action in custom or {} do
		local run = action.run
		table.insert(actions, {
			name = action.name,
			description = action.description,
			params = action.params,
			run = function(...)
				return run(self_, ...)
			end,
		})
	end
	return actions
end

----------------------------------------------------------------------------
-- Speech and events

-- Carry a spoken line to everyone who can hear it. Returns how many heard it.
function World:_speech(speaker: string, text: string, to: string?): number
	local from = self:_positionOf(speaker)
	if not from then
		return 0
	end
	local speakerIsCharacter = self.characters[speaker] ~= nil
	local heard = 0
	for _, person in self.people do
		local at = person.getPosition()
		if person.name ~= speaker and at and distance(at, from) <= self.hearing then
			heard += 1
		end
	end

	-- A line with no addressee is taken by the closest resident in talking range.
	local closest, closestDistance = nil, 16
	if not to then
		for _, name in self.characterOrder do
			local other = self.characters[name]
			if other and name ~= speaker then
				local d = distance(other:position(), from)
				if d < closestDistance then
					closest, closestDistance = name, d
				end
			end
		end
	end

	for _, name in self.characterOrder do
		local other = self.characters[name]
		if other and name ~= speaker and distance(other:position(), from) <= self.hearing then
			heard += 1
			local addressed = to == name or (not to and closest == name)
			local line
			if addressed then
				line = string.format('%s said to you: "%s"', speaker, text)
			elseif to then
				line = string.format('%s said to %s: "%s"', speaker, to, text)
			else
				line = string.format('%s said: "%s"', speaker, text)
			end
			local turn = addressed
			-- Two residents talking stop after a few exchanges, so a chat
			-- cannot run forever. It opens again after a pause.
			if turn and speakerIsCharacter then
				local chat = other._chat
				if os.clock() > chat.resetAt then
					chat.count = 0
				end
				chat.count += 1
				chat.resetAt = os.clock() + 75
				if chat.count > 4 then
					turn = false
				end
			end
			if addressed and other.body.face and not other.status then
				pcall(other.body.face, other.body, from)
			end
			other:notice(line, { about = speaker, urgent = turn })
		end
	end
	self:_emit({ type = "speech", speaker = speaker, text = text, to = to })
	return heard
end

--- A human player said something. to is optional: without it the closest
--- resident in talking range takes it as said to them.
function World:say(speaker: string, text: string, to: string?)
	text = clip(text, 300)
	if text == "" or not self.people[speaker] then
		return 0
	end
	return self:_speech(speaker, text, self:_resolve(to))
end

--- Tell one character something happened, in plain words.
function World:tell(characterName: string, text: string, options: { about: string?, turn: boolean?, urgent: boolean? }?)
	local character = self.characters[characterName]
	if character then
		character:notice(text, options or { turn = true })
	end
end

--- Tell every character within range of a position that something happened.
function World:announce(text: string, position: any?, range: number?)
	for _, name in self.characterOrder do
		local character = self.characters[name]
		if character and (not position or distance(character:position(), position) <= (range or self.sight)) then
			character:notice(text, { turn = true })
		end
	end
end

--- A human player hands an item to a character.
function World:give(from: string, characterName: string, item: string): boolean
	local character = self.characters[characterName]
	if not character then
		return false
	end
	table.insert(character.carrying, item)
	character:notice(from .. " gave you " .. item .. ".", { about = from, urgent = true })
	self:_emit({ type = "give", from = from, to = characterName, item = item })
	return true
end

----------------------------------------------------------------------------
-- Scheduling

function World:_spend(): boolean
	local now = os.clock()
	self._budget = math.min(self.turnsPerMinute, self._budget + (now - self._budgetAt) * self.turnsPerMinute / 60)
	self._budgetAt = now
	if self._budget < 1 then
		return false
	end
	self._budget -= 1
	return true
end

function World:_idleDelay(character: any): number
	local delay = self.idleSeconds * (0.75 + math.random() * 0.5)
	if not self:_humanNear(character:position(), self.activeRadius) then
		delay *= self.farSlowdown
	end
	return delay
end

function World:_runTurn(character: any)
	character._wake = nil
	character._thinking = true
	self:_emit({ type = "thinking", character = character.name, on = true })
	local started = character.agent:requestTurn(function(result)
		character._thinking = false
		character.turns += 1
		self.turnsUsed += 1
		if result.usage then
			character.tokens += (result.usage.promptTokens or 0) + (result.usage.completionTokens or 0)
		end
		self:_emit({ type = "thinking", character = character.name, on = false })
		self:_emit({ type = "turn", character = character.name, result = result })
		if not result.ok then
			warn("[WSI.World] " .. character.name .. " turn failed: " .. tostring(result.error))
			character:_wakeIn(math.max(20, self.idleSeconds))
			return
		end
		if #character._inbox > 0 then
			character:_wakeIn(1)
		else
			character:_wakeIn(self:_idleDelay(character))
		end
	end)
	if not started then
		character._thinking = false
		character:_wakeIn(2)
	end
end

function World:_tick(dt: number)
	local now = os.clock()
	for _, name in self.characterOrder do
		local character = self.characters[name]
		if not character or not character.agent then
			continue
		end
		-- Needs fall over time. A need that gets low is worth a turn.
		for need, spec in self.needDefs do
			local value = math.max(0, character.needs[need] - spec.perMinute * dt / 60)
			character.needs[need] = value
			if value < 25 and not character._needWarned[need] then
				character._needWarned[need] = true
				character:notice("Your " .. need .. " is getting low (" .. math.floor(value) .. ").", { turn = true })
			elseif value > 50 then
				character._needWarned[need] = nil
			end
		end
		-- Notice a human who walks up.
		if self.greetDistance > 0 then
			local here = character:position()
			for personName, person in self.people do
				local at = person.getPosition()
				local close = at and distance(at, here) <= self.greetDistance
				local last = character._greeted[personName]
				if close and (not last or now - last > 150) then
					character._greeted[personName] = now
					if not last or now - last > 150 then
						character:notice(personName .. " walked up to you.", { about = personName, turn = true })
					end
				elseif close then
					character._greeted[personName] = now
				end
			end
		end
		-- A character that is walking or busy does not get idle turns, only
		-- turns for things that happened.
		local due = character._wake and now >= character._wake
		if due and not character.agent:isBusy() then
			if character.status and #character._inbox == 0 then
				character._wake = now + 5
			elseif self:_spend() then
				self:_runTurn(character)
			end
		end
	end
end

--- Start giving characters turns. Call it once, after adding the characters.
function World:start()
	if self._running then
		return
	end
	self._running = true
	self._budget = math.min(self.turnsPerMinute, 6)
	self._budgetAt = os.clock()
	task.spawn(function()
		local last = os.clock()
		while self._running do
			task.wait(0.5)
			local now = os.clock()
			local ok, err = pcall(self._tick, self, now - last)
			if not ok then
				warn("[WSI.World] tick failed: " .. tostring(err))
			end
			last = now
		end
	end)
end

--- Stop giving turns. Sessions stay open until the client closes.
function World:stop()
	self._running = false
end

return World
