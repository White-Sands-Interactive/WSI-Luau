--!nonstrict
-- White Sands agent player for Roblox. Server only.
--
-- The game opens one WebSocket to the platform, logs in with a platform key,
-- and serves each NPC's see() and actions as MCP tools. The platform holds the
-- model and picks one action per turn. The game decides when a turn happens.
--
--   local WSI = require(ServerScriptService.WSI)
--   local client = WSI.new({ platformKey = key })
--   local agent = client:start({ name = "Guide", goal = "...", see = see, actions = { ... } })
--   local result = agent:turn()

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Json = require(script.Json)

local WSI = {}
WSI.Json = Json
WSI.SDK_VERSION = "0.2.0"
WSI.PROTOCOL_VERSION = 1
WSI.DEFAULT_URL = "wss://api.whitesandsint.com"

local MCP_PROTOCOL_VERSION = "2025-06-18"
local HEARTBEAT_SECONDS = 15
local PONG_TIMEOUT_SECONDS = 10
local RESUME_GRACE_SECONDS = 30
local MAX_RECONNECT_ATTEMPTS = 8
local SESSION_REPLY_TIMEOUT = 15
local DEFAULT_TURN_TIMEOUT = 60
local DEFAULT_DONE_LIMIT = 20

local SEE_DESCRIPTION = "Read the current game view for this player. Prefer wait, which returns this after the game grants a turn."
local WAIT_DESCRIPTION = "Block until the game calls turn() for this session, then return the current see() view."

WSI.DEFAULT_INSTRUCTIONS = table.concat({
	"You are a remote game agent. Tools are provided by the game.",
	"On every turn: call wait first. It blocks until the game grants your turn and then returns the current view from see.",
	"After wait returns, call exactly one action tool (not see, not wait).",
	"The view's done list is what this character has already called in this session, oldest first. Use it when choosing the next action.",
	"If an action tool returns an error, retry once with a corrected action. A second failure ends the turn as failed.",
}, "\n")

export type ParamType = "string" | "number" | "integer" | "boolean"

export type Param = {
	name: string,
	type: ParamType,
	description: string?,
	optional: boolean?,
	enum: { string }?,
}

export type Action = {
	name: string,
	description: string?,
	params: { Param }?,
	-- Arguments arrive in params order, then the whole args table last.
	-- Return a JSON-safe value. Call error("reason", 0) to reject the action.
	run: (...any) -> any,
}

export type AgentDefinition = {
	name: string,
	-- Character to play, by its character ID from the web app. Lets one key and
	-- one connection run several characters. Omit it to use the key's own character.
	playerId: string?,
	goal: string?,
	instructions: string?,
	see: () -> any,
	actions: { Action },
}

export type TurnResult = {
	ok: boolean,
	action: string?,
	args: { [string]: any }?,
	result: any,
	error: string?,
	attempts: number,
	usage: { promptTokens: number, completionTokens: number }?,
}

export type Event = {
	type: string,
	sessionId: string?,
	action: string?,
	args: { [string]: any }?,
	error: string?,
}

export type ClientOptions = {
	platformKey: string,
	platformUrl: string?,
	-- Replaces the default agent instructions for every session.
	instructions: string?,
	-- How many recent actions each view carries in its done list. 0 turns it off.
	doneLimit: number?,
	turnTimeout: number?,
	onEvent: ((Event) -> ())?,
	-- Print connection and turn details to the output window.
	debug: boolean?,
}

-- One waiting thread, resumed once with (ok, value).
type Waiter = { thread: thread, done: boolean }

local function newWaiter(): Waiter
	return { thread = coroutine.running(), done = false }
end

local function settle(waiter: Waiter?, ok: boolean, value: any)
	if waiter and not waiter.done then
		waiter.done = true
		task.spawn(waiter.thread, ok, value)
	end
end

-- Yield until settle() is called, or until timeout seconds pass.
local function await(waiter: Waiter, timeout: number?, timeoutMessage: string?): (boolean, any)
	if timeout then
		task.delay(timeout, function()
			settle(waiter, false, timeoutMessage or "timed out")
		end)
	end
	return coroutine.yield()
end

local function errorText(err: any): string
	local text = tostring(err)
	-- Drop the "Script:12: " prefix Roblox adds when error() is called with a level.
	return (text:gsub("^[^\n]-:%d+: ", ""))
end

----------------------------------------------------------------------------
-- Tools

local function paramSchema(param: Param): { [string]: any }
	local schema: { [string]: any } = { type = param.type }
	if param.description then
		schema.description = param.description
	end
	if param.enum then
		schema.enum = param.enum
	end
	return schema
end

local function toolDescriptor(name: string, description: string, params: { Param }): { [string]: any }
	local properties = Json.object()
	local required = {}
	for _, param in params do
		properties[param.name] = paramSchema(param)
		if not param.optional then
			table.insert(required, param.name)
		end
	end
	local schema: { [string]: any } = Json.object({ type = "object", properties = properties })
	if #required > 0 then
		schema.required = required
	end
	return { name = name, description = description, inputSchema = schema }
end

local function checkArgs(args: { [string]: any }, params: { Param }): string?
	local problems = {}
	for _, param in params do
		local value = args[param.name]
		if value == nil then
			if not param.optional then
				table.insert(problems, param.name .. ": required")
			end
			continue
		end
		local kind = type(value)
		local ok
		if param.type == "integer" then
			ok = kind == "number" and value % 1 == 0
		else
			ok = kind == param.type
		end
		if not ok then
			table.insert(problems, param.name .. ": expected " .. param.type)
		elseif param.enum and not table.find(param.enum, value) then
			table.insert(problems, param.name .. ": must be one of " .. table.concat(param.enum, ", "))
		end
	end
	if #problems == 0 then
		return nil
	end
	return table.concat(problems, "; ")
end

local function validateDefinition(def: AgentDefinition)
	assert(type(def) == "table", "start: definition must be a table")
	assert(type(def.name) == "string" and def.name ~= "", "start: name is required")
	assert(def.playerId == nil or (type(def.playerId) == "string" and def.playerId ~= ""), "start: playerId must be a non-empty string")
	assert(type(def.see) == "function", "start: see must be a function")
	assert(type(def.actions) == "table" and #def.actions > 0, "start: actions must list at least one action")
	local seen = {}
	for _, action in def.actions do
		assert(type(action.name) == "string" and action.name ~= "", "start: each action needs a name")
		assert(action.name ~= "see" and action.name ~= "wait", "start: \"" .. action.name .. "\" is reserved")
		assert(not seen[action.name], "start: duplicate action \"" .. action.name .. "\"")
		assert(type(action.run) == "function", "start: action \"" .. action.name .. "\" needs a run function")
		seen[action.name] = true
		for _, param in action.params or {} do
			assert(type(param.name) == "string" and param.name ~= "", "start: a param of \"" .. action.name .. "\" has no name")
			assert(
				param.type == "string" or param.type == "number" or param.type == "integer" or param.type == "boolean",
				"start: param \"" .. param.name .. "\" has unsupported type \"" .. tostring(param.type) .. "\""
			)
		end
	end
end

----------------------------------------------------------------------------
-- Agent: one session, one NPC

local Agent = {}
Agent.__index = Agent

export type Agent = typeof(setmetatable(
	{} :: {
		sessionId: string,
		name: string,
		_token: string,
		_client: any,
		_def: AgentDefinition,
		_tools: { { [string]: any } },
		_done: { { [string]: any } },
		_subgoals: { { id: string, objective: string, progress: { string } } },
		_released: boolean,
		_waitWaiter: Waiter?,
		_turnWaiter: Waiter?,
		_busy: boolean,
		_stopped: boolean,
		_listeners: { (Event) -> () },
	},
	Agent
))

local function newAgent(client: any, def: AgentDefinition): Agent
	local tools = { toolDescriptor("see", SEE_DESCRIPTION, {}), toolDescriptor("wait", WAIT_DESCRIPTION, {}) }
	for _, action in def.actions do
		table.insert(tools, toolDescriptor(action.name, action.description or ("Action: " .. action.name), action.params or {}))
	end
	return setmetatable({
		sessionId = HttpService:GenerateGUID(false),
		name = def.name,
		_token = HttpService:GenerateGUID(false),
		_client = client,
		_def = def,
		_tools = tools,
		_done = {},
		_subgoals = {},
		_released = false,
		_waitWaiter = nil,
		_turnWaiter = nil,
		_busy = false,
		_stopped = false,
		_listeners = {},
	}, Agent)
end

function Agent._view(self: Agent): any
	local view = self._def.see()
	local limit = self._client._doneLimit
	if limit <= 0 then
		return view
	end
	-- A dictionary view gets a done field. Anything else is wrapped.
	if type(view) == "table" and #view == 0 then
		local copy = table.clone(view)
		copy.done = self._done
		return copy
	end
	return { view = view, done = self._done }
end

function Agent._record(self: Agent, entry: { [string]: any })
	table.insert(self._done, entry)
	local limit = self._client._doneLimit
	while #self._done > limit do
		table.remove(self._done, 1)
	end
end

-- Called by the platform's wait tool. Yields until turn() releases it.
function Agent._waitForTurn(self: Agent): boolean
	if self._released then
		self._released = false
		return true
	end
	if self._stopped then
		return false
	end
	local waiter = newWaiter()
	self._waitWaiter = waiter
	local ok = await(waiter)
	self._released = false
	return ok
end

function Agent._callTool(self: Agent, name: string, args: { [string]: any }): (boolean, any)
	if name == "see" then
		return pcall(self._view, self)
	end
	if name == "wait" then
		if not self:_waitForTurn() then
			return false, "session stopped"
		end
		return pcall(self._view, self)
	end
	local action: Action? = nil
	for _, candidate in self._def.actions do
		if candidate.name == name then
			action = candidate
			break
		end
	end
	if not action then
		return false, "unknown tool: " .. name
	end
	local params = action.params or {}
	local problem = checkArgs(args, params)
	if problem then
		self:_record({ action = name, args = args, ok = false, error = problem })
		return false, problem
	end
	local positional = table.create(#params + 1)
	for i, param in params do
		positional[i] = args[param.name]
	end
	positional[#params + 1] = args
	local ok, result = pcall(action.run, table.unpack(positional, 1, #params + 1))
	if ok then
		self:_record({ action = name, args = args, ok = true })
		if result == nil then
			result = { ok = true }
		end
		return true, result
	end
	local message = errorText(result)
	self:_record({ action = name, args = args, ok = false, error = message })
	return false, message
end

function Agent._handleMcp(self: Agent, message: any)
	if type(message) ~= "table" or type(message.method) ~= "string" or message.id == nil then
		return
	end
	local id = message.id
	local method: string = message.method
	local params = type(message.params) == "table" and message.params or {}
	local function reply(result: any)
		self._client:_send({ type = "mcp", sessionId = self.sessionId, message = { jsonrpc = "2.0", id = id, result = result } })
	end
	if method == "initialize" then
		reply({
			protocolVersion = type(params.protocolVersion) == "string" and params.protocolVersion or MCP_PROTOCOL_VERSION,
			capabilities = { tools = Json.object() },
			serverInfo = { name = "agent-player:" .. self.name, version = WSI.SDK_VERSION },
		})
	elseif method == "ping" then
		reply(Json.object())
	elseif method == "tools/list" then
		reply({ tools = self._tools })
	elseif method == "tools/call" then
		local args = type(params.arguments) == "table" and params.arguments or {}
		local ok, value = self:_callTool(tostring(params.name), args)
		local payload = ok and value or { error = value }
		local encodedOk, text = pcall(Json.encode, payload)
		if not encodedOk then
			ok, text = false, Json.encode({ error = "result is not JSON-safe: " .. errorText(text) })
		end
		reply({ isError = not ok, content = { { type = "text", text = text } } })
	else
		self._client:_send({
			type = "mcp",
			sessionId = self.sessionId,
			message = { jsonrpc = "2.0", id = id, error = { code = -32601, message = "method not found: " .. method } },
		})
	end
end

function Agent._applySubgoal(self: Agent, action: string?, args: { [string]: any }?)
	if not args then
		return
	end
	if action == "add_subgoal" and args.id then
		table.insert(self._subgoals, { id = tostring(args.id), objective = tostring(args.objective or ""), progress = {} })
		return
	end
	for i, subgoal in self._subgoals do
		if subgoal.id == tostring(args.id) then
			if action == "complete_subgoal" then
				table.remove(self._subgoals, i)
			elseif action == "update_subgoal" then
				table.insert(subgoal.progress, tostring(args.progress or ""))
				if #subgoal.progress > 5 then
					table.remove(subgoal.progress, 1)
				end
			end
			return
		end
	end
end

function Agent._emit(self: Agent, event: Event)
	for _, listener in table.clone(self._listeners) do
		task.spawn(listener, event)
	end
	self._client:_emit(event)
end

function Agent._completeTurn(self: Agent, report: { [string]: any })
	local waiter = self._turnWaiter
	self._turnWaiter = nil
	settle(waiter, true, report)
end

--- Grant one turn and yield until the platform has played it.
--- Returns a TurnResult. A failed turn returns ok = false with error set; it does not throw.
function Agent.turn(self: Agent, timeout: number?): TurnResult
	if self._stopped then
		return { ok = false, error = "session stopped", attempts = 0 }
	end
	if self._busy then
		return { ok = false, error = "a turn is already in progress for this agent", attempts = 0 }
	end
	self._busy = true
	local waiter = newWaiter()
	self._turnWaiter = waiter
	self._released = true
	local release = self._waitWaiter
	self._waitWaiter = nil
	settle(release, true, nil)
	local ok, report = await(waiter, timeout or self._client._turnTimeout, "turn timed out")
	self._busy = false
	if self._turnWaiter == waiter then
		self._turnWaiter = nil
	end
	if not ok then
		return { ok = false, error = tostring(report), attempts = 0 }
	end
	return {
		ok = report.ok == true,
		action = report.action,
		args = report.args,
		result = report.result,
		error = report.error,
		attempts = report.attempts or 0,
		usage = report.usage,
	}
end

--- Ask for a turn without yielding. Returns false if a turn is already running.
--- The optional callback receives the TurnResult.
function Agent.requestTurn(self: Agent, callback: ((TurnResult) -> ())?): boolean
	if self._busy or self._stopped then
		return false
	end
	task.spawn(function()
		local result = self:turn()
		if callback then
			callback(result)
		end
	end)
	return true
end

--- True while a turn is being played.
function Agent.isBusy(self: Agent): boolean
	return self._busy
end

--- Active subgoals the model has added this session.
function Agent.subgoals(self: Agent): { { id: string, objective: string, progress: { string } } }
	return table.clone(self._subgoals)
end

--- Listen for action, retry, subgoal and turnFailed events. Returns a function that unsubscribes.
function Agent.on(self: Agent, listener: (Event) -> ()): () -> ()
	table.insert(self._listeners, listener)
	return function()
		local index = table.find(self._listeners, listener)
		if index then
			table.remove(self._listeners, index)
		end
	end
end

--- End the session. Safe to call twice.
function Agent.stop(self: Agent)
	if self._stopped then
		return
	end
	self._stopped = true
	settle(self._waitWaiter, false, "session stopped")
	self._waitWaiter = nil
	self:_completeTurn({ ok = false, error = "session stopped" })
	self._client:_stopSession(self)
end

----------------------------------------------------------------------------
-- Client: one connection, many agents

local Client = {}
Client.__index = Client

export type Client = typeof(setmetatable(
	{} :: {
		accountName: string?,
		_url: string,
		_key: string,
		_clientId: string,
		_instructions: string,
		_doneLimit: number,
		_turnTimeout: number,
		_onEvent: ((Event) -> ())?,
		_debug: boolean,
		_socket: any,
		_open: boolean,
		_closed: boolean,
		_everConnected: boolean,
		_reconnecting: boolean,
		_reconnectAttempt: number,
		_connectWaiters: { Waiter },
		_connecting: boolean,
		_sessions: { [string]: Agent },
		_replyWaiters: { [string]: Waiter },
		_outbox: { any },
		_pendingPong: string?,
		_heartbeat: thread?,
	},
	Client
))

--- Create a client. Nothing connects until the first start().
function WSI.new(options: ClientOptions): Client
	assert(RunService:IsServer(), "WSI runs on the server only. Require it from a Script, not a LocalScript.")
	assert(type(options) == "table", "WSI.new: options are required")
	assert(type(options.platformKey) == "string" and options.platformKey ~= "", "WSI.new: platformKey is required")
	local self = setmetatable({
		accountName = nil,
		_url = options.platformUrl or WSI.DEFAULT_URL,
		_key = options.platformKey,
		_clientId = HttpService:GenerateGUID(false),
		_instructions = options.instructions or WSI.DEFAULT_INSTRUCTIONS,
		_doneLimit = options.doneLimit or DEFAULT_DONE_LIMIT,
		_turnTimeout = options.turnTimeout or DEFAULT_TURN_TIMEOUT,
		_onEvent = options.onEvent,
		_debug = options.debug == true,
		_socket = nil,
		_open = false,
		_closed = false,
		_everConnected = false,
		_reconnecting = false,
		_reconnectAttempt = 0,
		_connectWaiters = {},
		_connecting = false,
		_sessions = {},
		_replyWaiters = {},
		_outbox = {},
		_pendingPong = nil,
		_heartbeat = nil,
	}, Client)
	game:BindToClose(function()
		self:close()
	end)
	return self
end

function Client._log(self: Client, ...: any)
	if self._debug then
		print("[WSI]", ...)
	end
end

function Client._emit(self: Client, event: Event)
	if self._onEvent then
		task.spawn(self._onEvent, event)
	end
end

function Client._send(self: Client, envelope: { [string]: any })
	if self._open and self._socket then
		self._socket:Send(Json.encode(envelope))
		return
	end
	if envelope.type == "mcp" or envelope.type == "ping" then
		table.insert(self._outbox, envelope)
		return
	end
	error("not connected to the platform", 0)
end

function Client._flushOutbox(self: Client)
	local pending = self._outbox
	self._outbox = {}
	for _, envelope in pending do
		self._socket:Send(Json.encode(envelope))
	end
end

function Client._failAll(self: Client, message: string)
	for key, waiter in self._replyWaiters do
		self._replyWaiters[key] = nil
		settle(waiter, false, message)
	end
	for _, agent in self._sessions do
		agent:_completeTurn({ ok = false, error = message })
	end
end

-- Open a socket and send hello. Yields until hello_ok or failure.
function Client._openSocket(self: Client): (boolean, string?)
	local created, socket = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, { Url = self._url })
	end)
	if not created then
		return false, "could not open a WebSocket: " .. errorText(socket) .. " (is Allow HTTP Requests on?)"
	end
	self._socket = socket
	local waiter = newWaiter()
	local helloDone = false

	socket.Opened:Connect(function()
		self:_log("socket open, sending hello")
		socket:Send(Json.encode({
			type = "hello",
			platformKey = self._key,
			clientId = self._clientId,
			protocolVersion = WSI.PROTOCOL_VERSION,
			sdkVersion = "luau-" .. WSI.SDK_VERSION,
		}))
	end)

	socket.MessageReceived:Connect(function(text: string)
		local ok, envelope = pcall(Json.decode, text)
		if not ok or type(envelope) ~= "table" then
			self:_log("ignored a message that is not JSON")
			return
		end
		if not helloDone and (envelope.type == "hello_ok" or envelope.type == "hello_err") then
			helloDone = true
			if envelope.type == "hello_err" then
				if envelope.code == "AUTH" or envelope.code == "PROTOCOL" then
					self._closed = true
				end
				settle(waiter, false, tostring(envelope.message))
				pcall(function()
					socket:Close()
				end)
				return
			end
			self.accountName = envelope.accountName
			self._open = true
			settle(waiter, true, nil)
			return
		end
		self:_handle(envelope)
	end)

	socket.Error:Connect(function(code: number, message: string)
		self:_log("socket error", code, message)
		if not helloDone then
			helloDone = true
			settle(waiter, false, "platform connection failed: " .. tostring(message))
		end
	end)

	socket.Closed:Connect(function()
		if self._socket ~= socket then
			return
		end
		local wasOpen = self._open
		self._open = false
		self._socket = nil
		self._pendingPong = nil
		if not helloDone then
			helloDone = true
			settle(waiter, false, "platform closed the connection before hello")
		end
		if wasOpen then
			self:_log("socket closed")
			self:_onDisconnect()
		end
	end)

	local ok, err = await(waiter, SESSION_REPLY_TIMEOUT, "platform did not answer hello")
	if not ok then
		self._socket = nil
		pcall(function()
			socket:Close()
		end)
		return false, err
	end
	self:_log("connected as", self.accountName)
	self:_startHeartbeat()
	self:_flushOutbox()
	return true, nil
end

--- Connect and log in. start() calls this for you. Returns ok, error.
function Client.connect(self: Client): (boolean, string?)
	if self._closed then
		return false, "client is closed"
	end
	if self._open then
		return true, nil
	end
	if self._connecting then
		local waiter = newWaiter()
		table.insert(self._connectWaiters, waiter)
		return await(waiter)
	end
	self._connecting = true
	local ok, err = self:_openSocket()
	self._connecting = false
	if ok then
		self._everConnected = true
		self._reconnectAttempt = 0
	end
	local waiters = self._connectWaiters
	self._connectWaiters = {}
	for _, waiter in waiters do
		settle(waiter, ok, err)
	end
	return ok, err
end

function Client._startHeartbeat(self: Client)
	local thread
	thread = task.spawn(function()
		while self._heartbeat == thread do
			task.wait(HEARTBEAT_SECONDS)
			if self._heartbeat ~= thread or not self._open then
				return
			end
			local id = HttpService:GenerateGUID(false)
			self._pendingPong = id
			pcall(self._send, self, { type = "ping", id = id })
			task.delay(PONG_TIMEOUT_SECONDS, function()
				if self._pendingPong == id and self._socket then
					self:_log("heartbeat timed out")
					pcall(function()
						self._socket:Close()
					end)
				end
			end)
		end
	end)
	self._heartbeat = thread
end

function Client._onDisconnect(self: Client)
	self._heartbeat = nil
	self:_emit({ type = "disconnected" })
	if self._closed or not self._everConnected then
		self:_failAll("platform connection closed")
		return
	end
	self:_scheduleReconnect()
end

function Client._scheduleReconnect(self: Client)
	if self._closed or self._reconnecting then
		return
	end
	if self._reconnectAttempt >= MAX_RECONNECT_ATTEMPTS then
		self._closed = true
		self:_failAll("could not reconnect to the platform")
		self:_emit({ type = "connectionLost", error = "could not reconnect to the platform" })
		return
	end
	local delay = math.min(RESUME_GRACE_SECONDS, 0.25 * 2 ^ self._reconnectAttempt)
	self._reconnectAttempt += 1
	self._reconnecting = true
	warn(string.format("[WSI] platform connection dropped; retrying in %.2fs", delay))
	task.delay(delay, function()
		local ok, err = self:_openSocket()
		self._reconnecting = false
		if not ok then
			self:_log("reconnect failed:", err)
			if self._closed then
				self:_failAll(err or "platform rejected the connection")
			else
				self:_scheduleReconnect()
			end
			return
		end
		self._reconnectAttempt = 0
		for _, agent in self._sessions do
			local resumed, resumeErr = self:_request(agent.sessionId, "resume", {
				type = "resume_session",
				sessionId = agent.sessionId,
				sessionToken = agent._token,
			})
			if not resumed then
				warn("[WSI] could not resume " .. agent.name .. ": " .. tostring(resumeErr))
				agent:_completeTurn({ ok = false, error = "connection lost" })
			end
		end
		self:_emit({ type = "reconnected" })
	end)
end

-- Send a session message and yield until the matching reply.
function Client._request(self: Client, sessionId: string, kind: string, envelope: { [string]: any }): (boolean, any)
	local key = sessionId .. ":" .. kind
	local waiter = newWaiter()
	self._replyWaiters[key] = waiter
	local sent, err = pcall(self._send, self, envelope)
	if not sent then
		self._replyWaiters[key] = nil
		return false, err
	end
	local ok, value = await(waiter, SESSION_REPLY_TIMEOUT, "timed out waiting for session " .. kind)
	if self._replyWaiters[key] == waiter then
		self._replyWaiters[key] = nil
	end
	return ok, value
end

function Client._reply(self: Client, sessionId: string?, kind: string, ok: boolean, value: any)
	if not sessionId then
		return
	end
	local key = sessionId .. ":" .. kind
	local waiter = self._replyWaiters[key]
	self._replyWaiters[key] = nil
	settle(waiter, ok, value)
end

function Client._handle(self: Client, envelope: { [string]: any })
	local kind = envelope.type
	local agent = envelope.sessionId and self._sessions[envelope.sessionId]
	if kind == "mcp" then
		if agent then
			task.spawn(agent._handleMcp, agent, envelope.message)
		end
	elseif kind == "turn_result" then
		if agent then
			if self._debug then
				self:_log(agent.name, "turn", envelope.ok and "ok" or "failed", envelope.action or envelope.error)
			end
			agent:_completeTurn(envelope)
		end
	elseif kind == "session_event" then
		if agent then
			if envelope.event == "subgoal" and not envelope.error then
				agent:_applySubgoal(envelope.action, envelope.args)
			end
			agent:_emit({
				type = envelope.event,
				sessionId = envelope.sessionId,
				action = envelope.action,
				args = envelope.args,
				error = envelope.error,
			})
		end
	elseif kind == "pong" then
		if self._pendingPong == envelope.id then
			self._pendingPong = nil
		end
	elseif kind == "ping" then
		pcall(self._send, self, { type = "pong", id = envelope.id })
	elseif kind == "session_started" then
		self:_reply(envelope.sessionId, "start", true, nil)
	elseif kind == "session_stopped" then
		self:_reply(envelope.sessionId, "stop", true, nil)
	elseif kind == "session_resumed" then
		self:_reply(envelope.sessionId, "resume", true, nil)
	elseif kind == "resume_err" then
		self:_reply(envelope.sessionId, "resume", false, envelope.message)
	elseif kind == "error" then
		warn("[WSI] platform error: " .. tostring(envelope.message))
		if envelope.sessionId then
			self:_reply(envelope.sessionId, "start", false, envelope.message)
		end
	end
end

--- Start an agent session. Yields until the platform accepts it.
--- Returns the Agent, or nil and an error message.
function Client.start(self: Client, def: AgentDefinition): (Agent?, string?)
	validateDefinition(def)
	local connected, connectErr = self:connect()
	if not connected then
		return nil, connectErr
	end
	local agent = newAgent(self, def)
	self._sessions[agent.sessionId] = agent
	local instructions = self._instructions
	if def.instructions and def.instructions ~= "" then
		instructions ..= "\n\n" .. def.instructions
	end
	local ok, err = self:_request(agent.sessionId, "start", {
		type = "start_session",
		sessionId = agent.sessionId,
		sessionToken = agent._token,
		name = def.name,
		playerId = def.playerId,
		tools = agent._tools,
		instructions = instructions,
		goal = def.goal,
	})
	if not ok then
		self._sessions[agent.sessionId] = nil
		agent._stopped = true
		return nil, tostring(err)
	end
	self:_log("started", def.name, agent.sessionId)
	return agent, nil
end

function Client._stopSession(self: Client, agent: Agent)
	if self._sessions[agent.sessionId] ~= agent then
		return
	end
	self._sessions[agent.sessionId] = nil
	if self._open then
		self:_request(agent.sessionId, "stop", { type = "stop_session", sessionId = agent.sessionId })
	end
end

--- Listen for events from every agent, plus disconnected, reconnected and connectionLost.
function Client.on(self: Client, listener: (Event) -> ())
	local previous = self._onEvent
	self._onEvent = function(event)
		if previous then
			previous(event)
		end
		listener(event)
	end
end

--- Stop every agent and close the connection.
function Client.close(self: Client)
	if self._closed and not self._socket then
		return
	end
	for _, agent in table.clone(self._sessions) do
		agent:stop()
	end
	self._closed = true
	self._heartbeat = nil
	self:_failAll("client closed")
	local socket = self._socket
	self._socket = nil
	self._open = false
	if socket then
		pcall(function()
			socket:Close()
		end)
	end
end

return WSI
