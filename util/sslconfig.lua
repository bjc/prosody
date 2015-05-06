
local handlers = { };
local finalisers = { };
local id = function (v) return v end

function handlers.options(a, k, b)
	local o = a[k] or { };
	if type(b) ~= "table" then b = { b } end
	for key, value in pairs(b) do
		if value == true or value == false then
			o[key] = value;
		else
			o[value] = true;
		end
	end
	a[k] = o;
end

handlers.verify = handlers.options;
handlers.verifyext = handlers.options;

function finalisers.options(a)
	local o = {};
	for opt, enable in pairs(a) do
		if enable then
			o[#o+1] = opt;
		end
	end
	return o;
end

finalisers.verify = finalisers.options;
finalisers.verifyext = finalisers.options;

function finalisers.ciphers(a)
	if type(a) == "table" then
		return table.concat(a, ":");
	end
	return a;
end

local protocols = { "sslv2", "sslv3", "tlsv1", "tlsv1_1", "tlsv1_2" };
for i = 1, #protocols do protocols[protocols[i] .. "+"] = i - 1; end

local function protocol(a)
	local min_protocol = protocols[a.protocol];
	if min_protocol then
		a.protocol = "sslv23";
		for i = 1, min_protocol do
			table.insert(a.options, "no_"..protocols[i]);
		end
	end
end

local function apply(a, b)
	if type(b) == "table" then
		for k,v in pairs(b) do
			(handlers[k] or rawset)(a, k, v);
		end
	end
end

local function final(a)
	local f = { };
	for k,v in pairs(a) do
		f[k] = (finalisers[k] or id)(v);
	end
	protocol(f);
	return f;
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
