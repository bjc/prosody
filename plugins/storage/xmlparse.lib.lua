
local st = require "util.stanza";

-- XML parser
local parse_xml = (function()
	local entity_map = setmetatable({
		["amp"] = "&";
		["gt"] = ">";
		["lt"] = "<";
		["apos"] = "'";
		["quot"] = "\"";
	}, {__index = function(_, s)
			if s:sub(1,1) == "#" then
				if s:sub(2,2) == "x" then
					return string.char(tonumber(s:sub(3), 16));
				else
					return string.char(tonumber(s:sub(2)));
				end
			end
		end
	});
	local function xml_unescape(str)
		return (str:gsub("&(.-);", entity_map));
	end
	local function parse_tag(s)
		local name,sattr=(s):gmatch("([^%s]+)(.*)")();
		local attr = {};
		for a,b in (sattr):gmatch("([^=%s]+)=['\"]([^'\"]*)['\"]") do attr[a] = xml_unescape(b); end
		return name, attr;
	end
	return function(xml)
		local stanza = st.stanza("root");
		local regexp = "<([^>]*)>([^<]*)";
		for elem, text in xml:gmatch(regexp) do
			if elem:sub(1,1) == "!" or elem:sub(1,1) == "?" then -- neglect comments and processing-instructions
			elseif elem:sub(1,1) == "/" then -- end tag
				elem = elem:sub(2);
				stanza:up(); -- TODO check for start-end tag name match
			elseif elem:sub(-1,-1) == "/" then -- empty tag
				elem = elem:sub(1,-2);
				local name,attr = parse_tag(elem);
				stanza:tag(name, attr):up();
			else -- start tag
				local name,attr = parse_tag(elem);
				stanza:tag(name, attr);
			end
			if #text ~= 0 then -- text
				stanza:text(xml_unescape(text));
			end
		end
		return stanza.tags[1];
	end
end)();
-- end of XML parser

return parse_xml;
