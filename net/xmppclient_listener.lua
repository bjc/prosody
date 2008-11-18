
local logger = require "logger";
local lxp = require "lxp"
local init_xmlhandlers = require "core.xmlhandlers"
local sm_new_session = require "core.sessionmanager".new_session;

local connlisteners_register = require "net.connlisteners".register;

local t_insert = table.insert;
local t_concat = table.concat;
local t_concatall = function (t, sep) local tt = {}; for _, s in ipairs(t) do t_insert(tt, tostring(s)); end return t_concat(tt, sep); end
local m_random = math.random;
local format = string.format;
local sm_new_session, sm_destroy_session = sessionmanager.new_session, sessionmanager.destroy_session; --import("core.sessionmanager", "new_session", "destroy_session");
local sm_streamopened = sessionmanager.streamopened;
local st = stanza;

local sessions = {};
local xmppclient = { default_port = 5222 };

-- These are session methods --

local function session_reset_stream(session)
	-- Reset stream
		local parser = lxp.new(init_xmlhandlers(session, sm_streamopened), "|");
		session.parser = parser;
		
		session.notopen = true;
		
		function session.data(conn, data)
			parser:parse(data);
		end
		return true;
end


local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local function session_disconnect(session, reason)
	local log = session.log or log;
	if session.conn then
		if reason then
			if type(reason) == "string" then -- assume stream error
				log("info", "Disconnecting client, <stream:error> is: %s", reason);
				session.send(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					log("info", "Disconnecting client, <stream:error> is: %s", tostring(stanza));
					session.send(stanza);
				elseif reason.name then -- a stanza
					log("info", "Disconnecting client, <stream:error> is: %s", tostring(reason));
					session.send(reason);
				end
			end
		end
		session.send("</stream:stream>");
		session.conn.close();
		xmppclient.disconnect(session.conn, "stream error");
	end
end


-- End of session methods --

function xmppclient.listener(conn, data)
	local session = sessions[conn];
	if not session then
		session = sm_new_session(conn);
		sessions[conn] = session;

		-- Logging functions --

		local mainlog, log = log;
		do
			local conn_name = tostring(conn):match("[a-f0-9]+$");
			log = logger.init(conn_name);
		end
		local print = function (...) log("info", t_concatall({...}, "\t")); end
		session.log = log;

		print("Client connected");
		
		session.reset_stream = session_reset_stream;
		session.disconnect = session_disconnect;
		
		session_reset_stream(session); -- Initialise, ready for use
		
		-- TODO: Below function should be session,stanza - and xmlhandlers should use :method() notation to call,
		-- this will avoid the useless indirection we have atm
		-- (I'm on a mission, no time to fix now)

		-- Debug version --
		local function handleerr(err) print("Traceback:", err, debug.traceback()); end
		session.stanza_dispatch = function (stanza) return select(2, xpcall(function () return core_process_stanza(session, stanza); end, handleerr));  end

--		session.stanza_dispatch = function (stanza) return core_process_stanza(session, stanza); end

	end
	if data then
		session.data(conn, data);
	end
end
	
function xmppclient.disconnect(conn, err)
	local session = sessions[conn];
	if session then
		if session.presence and session.presence.attr.type ~= "unavailable" then
			local pres = st.presence{ type = "unavailable" };
			if err == "closed" then err = "connection closed"; end
			pres:tag("status"):text("Disconnected: "..err);
			session.stanza_dispatch(pres);
		end
		(session.log or log)("info", "Client disconnected: %s", err);
		sm_destroy_session(session);
		sessions[conn]  = nil;
		session = nil;
		collectgarbage("collect");
	end
end

connlisteners_register("xmppclient", xmppclient);
