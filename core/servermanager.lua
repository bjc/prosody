
require "modulemanager"

-- Handle stanzas that were addressed to the server (whether they came from c2s, s2s, etc.)
function handle_stanza(origin, stanza)
	-- Use plugins
	return modulemanager.handle_stanza(origin, stanza);
end
