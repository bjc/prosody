
local indent = function(i)
	return string.rep("\t", i);
end
local function basicSerialize (o)
	if type(o) == "number" or type(o) == "boolean" then
		return tostring(o);
	else -- assume it is a string -- FIXME make sure it's a string. throw an error otherwise.
		return (string.format("%q", tostring(o)):gsub("\\\n", "\\n"));
	end
end
local function _simplesave (o, ind, t)
	if type(o) == "number" then
		table.insert(t, tostring(o));
	elseif type(o) == "string" then
		table.insert(t, (string.format("%q", o):gsub("\\\n", "\\n")));
	elseif type(o) == "table" then
		table.insert(t, "{\n");
		for k,v in pairs(o) do
			table.insert(t, indent(ind));
			table.insert(t, "[");
			table.insert(t, basicSerialize(k));
			table.insert(t, "] = ");
			_simplesave(v, ind+1, t);
			table.insert(t, ",\n");
		end
		table.insert(t, indent(ind-1));
		table.insert(t, "}");
	elseif type(o) == "boolean" then
		table.insert(t, (o and "true" or "false"));
	else
		error("cannot serialize a " .. type(o))
	end
end
local t_concat = table.concat;

module "serialize"

function serialize(o)
	local t = {};
	_simplesave(o, 1, t);
	return t_concat(t);
end

return _M;
