--!strict
-- JSON for the wire protocol. HttpService:JSONEncode turns an empty table into
-- "[]", but tool schemas need "{}", so objects can be marked with Json.object().
-- Roblox values in a view (Vector3, CFrame, EnumItem, Instance) are converted
-- to plain JSON so see() can return them directly.

local HttpService = game:GetService("HttpService")

local Json = {}

local OBJECT = table.freeze({ __wsiObject = true })

--- Mark a table as a JSON object, so an empty one encodes as {} and not [].
function Json.object<T>(t: T?): T
	local value = (t or {}) :: any
	return setmetatable(value, OBJECT) :: any
end

local function round(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

local escapes = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(s: string): string
	return '"' .. s:gsub('[%c"\\]', function(c)
		return escapes[c] or string.format("\\u%04x", string.byte(c))
	end) .. '"'
end

local function encodeNumber(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "null"
	end
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return string.format("%.14g", n)
end

local function isArray(t: { [any]: any }): boolean
	if getmetatable(t :: any) == OBJECT then
		return false
	end
	local count = 0
	for key in t do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end
	return count == #t
end

local encode: (value: any, depth: number) -> string

function encode(value: any, depth: number): string
	if depth > 64 then
		error("JSON value is nested too deeply", 0)
	end
	local kind = typeof(value)
	if value == nil then
		return "null"
	elseif kind == "boolean" then
		return value and "true" or "false"
	elseif kind == "number" then
		return encodeNumber(value)
	elseif kind == "string" then
		return encodeString(value)
	elseif kind == "Vector3" then
		return string.format('{"x":%s,"y":%s,"z":%s}', encodeNumber(round(value.X)), encodeNumber(round(value.Y)), encodeNumber(round(value.Z)))
	elseif kind == "Vector2" then
		return string.format('{"x":%s,"y":%s}', encodeNumber(round(value.X)), encodeNumber(round(value.Y)))
	elseif kind == "CFrame" then
		return encode(value.Position, depth + 1)
	elseif kind == "EnumItem" then
		return encodeString(value.Name)
	elseif kind == "Instance" then
		return encodeString(value.Name)
	elseif kind == "Color3" then
		return encodeString("#" .. value:ToHex())
	elseif kind == "table" then
		local parts = {}
		if isArray(value) then
			for i = 1, #value do
				parts[i] = encode(value[i], depth + 1)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for key, item in value do
			if type(item) ~= "function" then
				table.insert(parts, encodeString(tostring(key)) .. ":" .. encode(item, depth + 1))
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return encodeString(tostring(value))
end

function Json.encode(value: any): string
	return encode(value, 0)
end

function Json.decode(text: string): any
	return HttpService:JSONDecode(text)
end

return Json
