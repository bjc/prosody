-- Storage local record API Description
--
-- This is written as a TypedLua description

-- Key-Value stores (the default)

local stanza = require"prosody.util.stanza".stanza_t

local record keyval_store
	get : function ( keyval_store, string ) : any , string
	set : function ( keyval_store, string, any ) : boolean, string
end

-- Map stores (key-key-value stores)

local record map_store
	get : function ( map_store, string, any ) : any, string
	set : function ( map_store, string, any, any ) : boolean, string
	set_keys : function ( map_store, string, { any : any }) : boolean, string
	remove : table
end

-- Archive stores

local record archive_query
	start  : number -- timestamp
	["end"]: number -- timestamp
	with   : string
	after  : string -- archive id
	before : string -- archive id
	total  : boolean
end

local record archive_store
	-- Optional set of capabilities
	caps   : {
		-- Optional total count of matching items returned as second return value from :find()
		string : any
	}

	-- Add to the archive
	append : function ( archive_store, string, string, any, number, string ) : string, string

	-- Iterate over archive
	type iterator = function () : string, any, number, string
	find   : function ( archive_store, string, archive_query ) : iterator, integer

	-- Removal of items. API like find. Optional
	delete : function ( archive_store, string, archive_query ) : boolean | number, string

	-- Array of dates which do have messages (Optional)
	dates  : function ( archive_store, string ) : { string }, string

	-- Map of counts per "with" field
	summary : function ( archive_store, string, archive_query ) : { string : integer }, string

	-- Map-store API
	get    : function ( archive_store, string, string ) : stanza, number, string
	get    : function ( archive_store, string, string ) : nil, string
	set    : function ( archive_store, string, string, stanza, number, string ) : boolean, string
end

-- This represents moduleapi
local record coremodule
	-- If the first string is omitted then the name of the module is used
	-- The second string is one of "keyval" (default), "map" or "archive"
	open_store : function (archive_store, string, string) : keyval_store, string
	open_store : function (archive_store, string, string) : map_store, string
	open_store : function (archive_store, string, string) : archive_store, string

	-- Other module methods omitted
end

return coremodule
