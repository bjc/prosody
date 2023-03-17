
local st = require "prosody.util.stanza";
local lxp = require "lxp";
local t_insert = table.insert;
local t_remove = table.remove;
local error = error;

local _ENV = nil;
-- luacheck: std none

local parse_xml = (function()
	local ns_prefixes = {
		["http://www.w3.org/XML/1998/namespace"] = "xml";
	};
	local ns_separator = "\1";
	local ns_pattern = "^([^"..ns_separator.."]*)"..ns_separator.."?(.*)$";
	return function(xml, options)
		--luacheck: ignore 212/self
		local handler = {};
		local stanza = st.stanza("root");
		local namespaces = {};
		local prefixes = {};
		function handler:StartNamespaceDecl(prefix, url)
			if prefix ~= nil then
				t_insert(namespaces, url);
				t_insert(prefixes, prefix);
			end
		end
		function handler:EndNamespaceDecl(prefix)
			if prefix ~= nil then
				-- we depend on each StartNamespaceDecl having a paired EndNamespaceDecl
				t_remove(namespaces);
				t_remove(prefixes);
			end
		end
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
			local n = {}
			for i=1,#namespaces do
				n[prefixes[i]] = namespaces[i];
			end
			stanza:tag(name, attr, n);
		end
		function handler:CharacterData(data)
			stanza:text(data);
		end
		function handler:EndElement()
			stanza:up();
		end
		-- SECURITY: These two handlers, especially the Doctype one, are required to prevent exploits such as Billion Laughs.
		local function restricted_handler(parser)
			if not parser.stop or not parser:stop() then
				error("Failed to abort parsing");
			end
		end
		handler.StartDoctypeDecl = restricted_handler;
		if not options or not options.allow_comments then
			-- NOTE: comments are generally harmless and can be useful when parsing configuration files or other data, even user-provided data
			handler.Comment = restricted_handler;
		end
		if not options or not options.allow_processing_instructions then
			-- Processing instructions should generally be safe to just ignore
			handler.ProcessingInstruction = restricted_handler;
		end
		local parser = lxp.new(handler, ns_separator);
		local ok, err, line, col = parser:parse(xml);
		if ok then ok, err, line, col = parser:parse(); end
		--parser:close();
		if ok then
			return stanza.tags[1];
		else
			return ok, ("%s (line %d, col %d))"):format(err, line, col);
		end
	end;
end)();

return {
	parse = parse_xml;
};
