
local st = require "util.stanza";
local lxp = require "lxp";

local _ENV = nil;

local parse_xml = (function()
	local ns_prefixes = {
		["http://www.w3.org/XML/1998/namespace"] = "xml";
	};
	local ns_separator = "\1";
	local ns_pattern = "^([^"..ns_separator.."]*)"..ns_separator.."?(.*)$";
	return function(xml)
		--luacheck: ignore 212/self
		local handler = {};
		local stanza = st.stanza("root");
		function handler:StartElement(tagname, attr)
			local curr_ns,name = tagname:match(ns_pattern);
			if name == "" then
				curr_ns, name = "", curr_ns;
			end
			if curr_ns ~= "" then
				attr.xmlns = curr_ns;
			end
			for i=1,#attr do
				local k = attr[i];
				attr[i] = nil;
				local ns, nm = k:match(ns_pattern);
				if nm ~= "" then
					ns = ns_prefixes[ns];
					if ns then
						attr[ns..":"..nm] = attr[k];
						attr[k] = nil;
					end
				end
			end
			stanza:tag(name, attr);
		end
		function handler:CharacterData(data)
			stanza:text(data);
		end
		function handler:EndElement()
			stanza:up();
		end
		local parser = lxp.new(handler, "\1");
		local ok, err, line, col = parser:parse(xml);
		if ok then ok, err, line, col = parser:parse(); end
		--parser:close();
		if ok then
			return stanza.tags[1];
		else
			return ok, err.." (line "..line..", col "..col..")";
		end
	end;
end)();

return {
	parse = parse_xml;
};
