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
	-- Several people can do it at the same time, and doing it at the same
	-- time as someone else is noticed as doing it together (dance, fish,
	-- drink a coffee). Default false: one user at a time.
	shared: boolean?,
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
	-- A character with no human within activeRadius waits this long before a
	-- turn for something it did itself (arrived, finished). Default 20. 0 turns it off.
	farDelay: number?,
	-- A human who comes this close is noticed. Default 12. 0 turns it off.
	greetDistance: number?,
	-- Cap on turns per minute for the whole world. Default 30.
	turnsPerMinute: number?,
	-- In a chat between two characters, each replies at most chatReplies times
	-- per chatPause seconds. Humans are always answered. Defaults 2 and 90.
	chatReplies: number?,
	chatPause: number?,
	-- Actions per turn, 1 to 4. Default 3.
	maxActions: number?,
	-- Needs every character has, such as { food = { perMinute = 3 } }. 100 is
	-- satisfied, 0 is desperate. perMinute is how fast it falls.
	needs: { [string]: { perMinute: number, start: number? } }?,
	-- Keep memory and relationships on the platform. Default true.
	memory: boolean?,
	-- No turns at all while no human is in the world, so an empty server
	-- spends nothing. Default true.
	pauseWhenEmpty: boolean?,
	-- After a failed turn, wait this long before the next try; each further
	-- failure in a row waits three times longer, up to idleSeconds. Default 3.
	retrySeconds: number?,
	-- How long follow keeps walking with someone. Default 120.
	followSeconds: number?,
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
		farDelay = options.farDelay or 20,
		chatReplies = options.chatReplies or 2,
		chatPause = options.chatPause or 90,
		maxActions = options.maxActions or 3,
		needDefs = options.needs or {},
		memory = options.memory ~= false,
		pauseWhenEmpty = options.pauseWhenEmpty ~= false,
		retrySeconds = options.retrySeconds or 3,
		followSeconds = options.followSeconds or 120,
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
--- thinking { character, on }, give { from, to, item }, turn { character, result },
--- together { character, person, thing, activity } when a character and a
--- player do a shared activity at the same time, invite { from, to, thing,
--- activity, place } when a character invites a player to do something,
--- follow { character, person, on } when a character starts or stops
--- walking with someone.
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
	local person = self.people[name]
	if person and person.doing then
		self:personActivity(name, nil)
	end
	self.people[name] = nil
end

local function activityText(thing: any, activityName: string): string
	local activity = thing.activities[activityName]
	return (activity and activity.status) or string.gsub(activityName, "_", " ")
end

--- A human player started (thingId, activityName) or stopped (nil) doing an
--- activity of a thing. Characters near them notice, and a character doing
--- the same shared activity is told they are doing it together.
function World:personActivity(name: string, thingId: string?, activityName: string?)
	local person = self.people[name]
	if not person then
		return
	end
	local previous = person.doing
	if previous and previous.thing == thingId and previous.activity == activityName then
		return
	end
	if previous then
		person.doing = nil
		local thing = self.things[previous.thing]
		if thing and thing._together then
			for key in table.clone(thing._together) do
				if string.find(key, "\0" .. name, 1, true) then
					thing._together[key] = nil
				end
			end
		end
	end
	if not thingId then
		return
	end
	local thing = self.things[thingId]
	assert(thing, "personActivity: no such thing " .. tostring(thingId))
	assert(thing.activities[activityName], "personActivity: " .. thingId .. " has no activity " .. tostring(activityName))
	person.doing = { thing = thingId, activity = activityName, since = os.clock() }
	local at = person.getPosition()
	local doing = activityText(thing, activityName)
	for _, characterName in self.characterOrder do
		local character = self.characters[characterName]
		local d = character and at and distance(character:position(), at)
		local same = character and character._doing and character._doing.thing == thingId and character._doing.activity == activityName
		if character and not same and d and d <= self.hearing then
			-- A free character gets a turn, so it can join in; a busy one sees
			-- it in its next view.
			character:notice(name .. " started " .. doing .. " at the " .. thing.name .. ".", { about = name, turn = not character.status })
		end
	end
	self:_checkTogether(thing)
end

-- A character and a person doing the same shared activity of a thing at the
-- same time are doing it together. Each pair is told once per activity.
function World:_checkTogether(thing: any)
	thing._together = thing._together or {}
	for _, characterName in self.characterOrder do
		local character = self.characters[characterName]
		local doing = character and character._doing
		local activity = doing and doing.thing == thing.id and thing.activities[doing.activity]
		if activity and activity.shared and doing.started then
			for personName, person in self.people do
				local other = person.doing
				if other and other.thing == thing.id and other.activity == doing.activity then
					local key = characterName .. "\0" .. personName
					if not thing._together[key] then
						thing._together[key] = true
						local text = activityText(thing, doing.activity)
						character:notice(string.format("You and %s are %s together at the %s.", personName, text, thing.name), { about = personName, turn = true })
						self:_emit({ type = "together", character = characterName, person = personName, thing = thing.id, activity = doing.activity })
					end
				end
			end
		end
	end
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
		"- You can speak and then act in the same turn, for example say and then go_to. When you agree to do something, do it in that same turn: say yes, then go_to or use.",
		"- go_to, approach and use take time. You are told when they finish. Do not repeat them while they are under way.",
		"- use walks you to the thing by itself. give walks you over to the person by itself.",
		"- Things marked shared can be done with other people at the same time. Doing them together is how friendships grow.",
		"- To do something with someone: invite them (you go and start it, they can join you), join what they are already doing, or follow them to walk along with them.",
		"- When you accept an invitation, say so, then do it in the same turn: use the thing they named, or follow them.",
		"- When you like someone and you are both free, you may invite them to do something you enjoy. Do not invite the same person again if they did not come.",
		"- A chat between neighbours is a few lines, then you both get on with your day. Do not answer a goodbye or a line that needs no answer.",
		"- If someone does not answer you, leave them be and get on with your day. Do not keep talking to a person who stays silent.",
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
		_doing = nil,
		_failures = 0,
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
		subgoals = false,
		ownInstructions = true,
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
		-- Nobody is watching a character far from every human, so its
		-- follow-up turns (arrived, finished an activity) can wait.
		local world = self.world
		if world.farDelay > 0 and not world:_humanNear(self:position(), world.activeRadius) then
			self:_wakeIn(world.farDelay)
		else
			self:_wakeIn(2.5)
		end
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
		local doing = nil
		if person.doing then
			local thing = world.things[person.doing.thing]
			doing = thing and (activityText(thing, person.doing.activity) .. " at the " .. thing.name) or nil
		end
		addNearby(name, "player", person.getPosition(), doing)
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
				if activity.shared then
					text ..= " (shared)"
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
		if self._using.usedBy == self.name then
			self._using.usedBy = nil
		end
		self._using = nil
	end
	if self._doing then
		self:_endDoing()
	end
	if self._following then
		local person = self._following
		self._following = nil
		self.world:_emit({ type = "follow", character = self.name, person = person, on = false })
	end
	self.body:stop()
	return self._task
end

function Character:_endDoing()
	local doing = self._doing
	self._doing = nil
	local thing = doing and self.world.things[doing.thing]
	if thing and thing._together then
		for key in table.clone(thing._together) do
			if string.sub(key, 1, #self.name + 1) == self.name .. "\0" then
				thing._together[key] = nil
			end
		end
	end
end

-- Who, among the humans, is doing the same activity of this thing right now.
function Character:_companions(thingId: string, activityName: string): { string }
	local names = {}
	for name, person in self.world.people do
		if person.doing and person.doing.thing == thingId and person.doing.activity == activityName then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

-- Walk to a thing and do one of its activities. Errors with a reason the
-- model can read when it cannot start.
function Character:_use(thingId: string, activityName: string)
	local world = self.world
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
	if not activity.shared and thing.usedBy and thing.usedBy ~= self.name then
		error(thing.usedBy .. " is using " .. thingId .. " right now", 0)
	end
	if activity.needs and not self:_has(activity.needs) then
		error("you need " .. activity.needs .. " to do that", 0)
	end
	local token = self:_interrupt()
	local seconds = activity.seconds or 5
	if not activity.shared then
		thing.usedBy = self.name
	end
	self._using = thing
	self._doing = { thing = thingId, activity = activityName, started = false }
	task.spawn(function()
		if distance(thing.position, self:position()) > 6 then
			if not self:_walk(token, thing.position, "walking to " .. thing.name) then
				if self._task == token then
					if thing.usedBy == self.name then
						thing.usedBy = nil
					end
					self._using = nil
					self:_endDoing()
					self:notice("You could not reach " .. thingId .. ".", { turn = true })
				end
				return
			end
		end
		if self._task ~= token then
			return
		end
		if self.body.face then
			pcall(self.body.face, self.body, thing.position)
		end
		self:setStatus(activity.status or string.gsub(activityName, "_", " "))
		if activity.emote and self.body.emote then
			pcall(self.body.emote, self.body, activity.emote, seconds)
		end
		self._doing.started = true
		world:_checkTogether(thing)
		task.wait(seconds)
		if self._task ~= token then
			return
		end
		local with = self:_companions(thingId, activityName)
		if thing.usedBy == self.name then
			thing.usedBy = nil
		end
		self._using = nil
		self:_endDoing()
		self:setStatus(nil)
		local outcome = {}
		if activity.needs then
			local index = self:_has(activity.needs)
			if index then
				table.remove(self.carrying, index)
			end
		end
		for need, change in activity.effects or {} do
			if self.needs[need] then
				self.needs[need] = math.clamp(self.needs[need] + change, 0, 100)
				table.insert(outcome, need .. " is now " .. math.floor(self.needs[need]))
			end
		end
		if activity.gives then
			table.insert(self.carrying, activity.gives)
			table.insert(outcome, "you now carry " .. activity.gives)
		end
		if activity.done then
			task.spawn(activity.done, self, thing)
		end
		local text = "You finished: " .. string.gsub(activityName, "_", " ") .. " at " .. thing.name
		if activity.shared and #with > 0 then
			text ..= ", together with " .. table.concat(with, " and ")
		end
		if #outcome > 0 then
			text ..= " (" .. table.concat(outcome, ", ") .. ")"
		end
		self:notice(text .. ".", { turn = true, about = with[1] })
	end)
	return { started = activityName, takes_seconds = seconds }
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
				return self_:_use(thingId, activityName)
			end,
		},
		{
			name = "join",
			description = "Join a player in the shared activity they are doing right now (see what they are doing in people_nearby).",
			params = { { name = "person", type = "string" } },
			run = function(person)
				local name = world:_resolve(person)
				local other = name and world.people[name]
				if not other then
					error("you cannot see anyone called " .. tostring(person), 0)
				end
				local at = other.getPosition()
				if not at or distance(at, self_:position()) > world.sight then
					error(name .. " is too far away to see", 0)
				end
				local doing = other.doing
				if not doing then
					error(name .. " is not doing anything you can join", 0)
				end
				local thing = world.things[doing.thing]
				local activity = thing and thing.activities[doing.activity]
				if not activity or not activity.shared then
					error(name .. " is doing something only one person can do", 0)
				end
				local result = self_:_use(doing.thing, doing.activity)
				result.with = name
				return result
			end,
		},
		{
			name = "follow",
			description = "Walk along with someone wherever they go, for a while. Use it when someone asks you to come with them. Any other movement stops it.",
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
				local token = self_:_interrupt()
				self_._following = name
				self_:setStatus("walking with " .. name)
				world:_emit({ type = "follow", character = self_.name, person = name, on = true })
				task.spawn(function()
					local started = os.clock()
					local lastPlace = world:placeAt(at)
					local settledPlace, settledAt = nil, 0
					while self_._task == token and os.clock() - started < world.followSeconds do
						local goal = world:_positionOf(name)
						if not goal then
							break
						end
						local here = self_:position()
						local gap = distance(goal, here)
						if gap > world.sight * 1.5 then
							self_._following = nil
							self_:setStatus(nil)
							world:_emit({ type = "follow", character = self_.name, person = name, on = false })
							self_:notice("You lost sight of " .. name .. ".", { about = name, turn = true })
							return
						end
						if gap > 7 then
							local offset = here - goal
							local target = goal + offset.Unit * 4
							if self_.body.walkToward and gap < 40 then
								self_.body:walkToward(target)
								task.wait(0.4)
							else
								self_.body:moveTo(target)
							end
						else
							task.wait(0.4)
						end
						-- Tell the follower once they have arrived somewhere together.
						local place = world:placeAt(goal)
						if place and place ~= lastPlace and gap <= 12 then
							if settledPlace ~= place then
								settledPlace, settledAt = place, os.clock()
							elseif os.clock() - settledAt > 2 then
								lastPlace = place
								self_:notice(string.format("You and %s arrived at %s together.", name, place), { about = name, turn = true })
							end
						end
					end
					if self_._task == token then
						self_._following = nil
						self_:setStatus(nil)
						world:_emit({ type = "follow", character = self_.name, person = name, on = false })
						self_:notice("You stopped walking with " .. name .. ".", { about = name, turn = true })
					end
				end)
				return { following = name, for_seconds = world.followSeconds }
			end,
		},
		{
			name = "invite",
			description = "Invite a player to do a shared activity with you. You go and start it at once; they can join you there.",
			params = {
				{ name = "person", type = "string" },
				{ name = "thing", type = "string" },
				{ name = "activity", type = "string" },
			},
			run = function(person, thingId, activityName)
				local name = world:_resolve(person)
				if not name or not world.people[name] then
					error("you cannot see a player called " .. tostring(person), 0)
				end
				local thing = world.things[thingId]
				local activity = thing and thing.activities[activityName]
				if not activity then
					error("there is no activity " .. tostring(activityName) .. " at " .. tostring(thingId), 0)
				end
				if not activity.shared then
					error(activityName .. " is not something you can do together", 0)
				end
				local result = self_:_use(thingId, activityName)
				world:_emit({ type = "invite", from = self_.name, to = name, thing = thingId, activity = activityName, place = thing.place, text = activityText(thing, activityName) })
				result.invited = name
				return result
			end,
		},
		{
			name = "give",
			description = "Give something you are carrying to someone. If they are not next to you, you walk over first.",
			params = {
				{ name = "item", type = "string" },
				{ name = "to", type = "string" },
			},
			run = function(item, to)
				if not self_:_has(item) then
					error("you are not carrying " .. tostring(item), 0)
				end
				local name = world:_resolve(to)
				local at = name and world:_positionOf(name)
				if not name or not at or name == self_.name then
					error("you cannot see anyone called " .. tostring(to), 0)
				end
				if distance(at, self_:position()) > world.sight then
					error(name .. " is too far away to see", 0)
				end
				local function handOver(): boolean
					local index = self_:_has(item)
					local now = world:_positionOf(name)
					if not index or not now or distance(now, self_:position()) > 12 then
						return false
					end
					table.remove(self_.carrying, index)
					local other = world.characters[name]
					if other then
						table.insert(other.carrying, item)
						other:notice(self_.name .. " gave you " .. item .. ".", { about = self_.name, urgent = true })
					elseif world.people[name] then
						table.insert(world.people[name].carrying, item)
					end
					world:_emit({ type = "give", from = self_.name, to = name, item = item })
					return true
				end
				if distance(at, self_:position()) <= 12 then
					handOver()
					return { gave = item, to = name }
				end
				local token = self_:_interrupt()
				task.spawn(function()
					local goal = world:_positionOf(name) or at
					local offset = self_:position() - goal
					if offset.Magnitude > 0.1 then
						goal = goal + offset.Unit * 4
					end
					if self_:_walk(token, goal, "taking " .. item .. " to " .. name) then
						if handOver() then
							self_:notice("You walked over and gave " .. item .. " to " .. name .. ".", { about = name, turn = true })
						else
							self_:notice("You walked over but could not give " .. item .. " to " .. name .. ".", { about = name, turn = true })
						end
					end
				end)
				return { walking_to = name, will_give = item }
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
					chat.resetAt = os.clock() + self.chatPause
				end
				chat.count += 1
				if chat.count > self.chatReplies then
					turn = false
				end
			end
			if addressed and other.body.face and not other.status then
				pcall(other.body.face, other.body, from)
			end
			-- A human gets an answer at once; a neighbour waits a breath.
			other:notice(line, { about = speaker, urgent = turn and not speakerIsCharacter, turn = turn })
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
			-- Retry soon: most failures are a vendor hiccup. Back off when they repeat.
			character._failures += 1
			local wait = math.min(self.retrySeconds * 3 ^ (character._failures - 1), math.max(self.idleSeconds, self.retrySeconds))
			warn(string.format("[WSI.World] %s turn failed (%d in a row), retrying in %.1fs: %s", character.name, character._failures, wait, tostring(result.error)))
			character:_wakeIn(wait)
			return
		end
		character._failures = 0
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
	-- An empty world spends nothing: no needs falling, no turns.
	if self.pauseWhenEmpty and next(self.people) == nil then
		return
	end
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
