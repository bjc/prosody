-- util to easily merge multiple sets of LuaSec context options

local type = type;
local pairs = pairs;
local rawset = rawset;
local t_concat = table.concat;
local t_insert = table.insert;
local setmetatable = setmetatable;

local _ENV = nil;

local handlers = { };
local finalisers = { };
local id = function (v) return v end

-- All "handlers" behave like extended rawset(table, key, value) with extra
-- processing usually merging the new value with the old in some reasonable
-- way
-- If a field does not have a defined handler then a new value simply
-- replaces the old.


-- Convert either a list or a set into a special type of set where each
-- item is either positive or negative in order for a later set of options
-- to be able to remove options from this set by filtering out the negative ones
function handlers.options(config, field, new)
	local options = config[field] or { };
	if type(new) ~= "table" then new = { new } end
	for key, value in pairs(new) do
		if value == true or value == false then
			options[key] = value;
		else -- list item
			options[value] = true;
		end
	end
	config[field] = options;
end

handlers.verifyext = handlers.options;

-- finalisers take something produced by handlers and return what luasec
-- expects it to be

-- Produce a list of "positive" options from the set
function finalisers.options(options)
	local output = {};
	for opt, enable in pairs(options) do
		if enable then
			output[#output+1] = opt;
		end
	end
	return output;
end

finalisers.verifyext = finalisers.options;

-- We allow ciphers to be a list

function finalisers.ciphers(cipherlist)
	if type(cipherlist) == "table" then
		return t_concat(cipherlist, ":");
	end
	return cipherlist;
end

-- protocol = "x" should enable only that protocol
-- protocol = "x+" should enable x and later versions

local protocols = { "sslv2", "sslv3", "tlsv1", "tlsv1_1", "tlsv1_2" };
for i = 1, #protocols do protocols[protocols[i] .. "+"] = i - 1; end

-- this interacts with ssl.options as well to add no_x
local function protocol(config)
	local min_protocol = protocols[config.protocol];
	if min_protocol then
		config.protocol = "sslv23";
		for i = 1, min_protocol do
			t_insert(config.options, "no_"..protocols[i]);
		end
	end
end

-- Merge options from 'new' config into 'config'
local function apply(config, new)
	if type(new) == "table" then
		for field, value in pairs(new) do
			(handlers[field] or rawset)(config, field, value);
		end
	end
end

-- Finalize the config into the form LuaSec expects
local function final(config)
	local output = { };
	for field, value in pairs(config) do
		output[field] = (finalisers[field] or id)(value);
	end
	-- Need to handle protocols last because it adds to the options list
	protocol(output);
	return output;
end

local sslopts_mt = {
	__index = {
		apply = apply;
		final = final;
	};
};

local function new()
	return setmetatable({options={}}, sslopts_mt);
end

return {
	apply = apply;
	final = final;
	new = new;
};
