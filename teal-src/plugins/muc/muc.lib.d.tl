local Stanza = require "util.stanza".stanza_t

local record Room
	jid : string

	enum Affiliation
		"outcast"
		"none"
		"member"
		"admin"
		"owner"
	end

	enum Role
		"none"
		"visitor"
		"participant"
		"moderator"
	end

	record Occupant
		bare_jid : string
		nick : string
		sessions : { string : Stanza }
		role : Role
		jid : string
	end

	-- Private properties
	_jid_nick : { string : string }
	_occupants : { string : Occupant }
	_data : { string : any }
	_affiliations : { string : Affiliation }
	_affiliation_data : { string : { string : any } }

	-- Occupant methods
	get_occupant_jid : function (Room, real_jid : string) : string
	new_occupant : function (Room, bare_real_jid : string, nick : string) : Occupant
	get_occupant_by_nick : function (Room, nick : string) : Occupant
	type OccupantIterator = function ({string:Occupant}, occupant_jid : string) : string, Occupant
	each_occupant : function (Room, read_only : boolean) : OccupantIterator, {string:Occupant}, nil
	has_occupant : function (Room) : boolean
	get_occupant_by_real_jid : function (Room, real_jid : string) : Occupant
	save_occupant :function (Room, Occupant) : Occupant

	-- Affiliation methods
	type AffiliationIterator = function (any, jid : string) : string, Affiliation
	get_affiliation : function (Room, jid : string) : Affiliation
	each_affiliation : function (Room, Affiliation) : AffiliationIterator, nil, nil
	set_affiliation : function (Room, jid : string, Affiliation, reason : string, data : { string : any }) : boolean, string, string, string -- ok + error tripplet
	get_affiliation_data : function (Room, jid : string, key : string) : any
	set_affiliation_data : function (Room, jid : string, key : string, value : any) : boolean
	get_registered_nick : function (Room, jid : string) : string
	get_registered_jid : function (Room, nick : string) : string

	-- Role methods
	get_default_role : function (Room, Affiliation) : Role, integer
	get_role : function (Room, nick : string) : Role
	may_set_role : function (Room, actor : string, Occupant, Role) : boolean
	set_role : function (Room, actor : string, occupant_jid : string, Role, reason : string) : boolean, string, string, string

	-- Routing input, generally handled by mod_muc and hooked up to Prosody routing events
	handle_first_presence : function (Room, table, Stanza) : boolean
	handle_normal_presence : function (Room, table, Stanza) : boolean
	handle_presence_to_room : function (Room, table, Stanza) : boolean
	handle_presence_to_occupant : function (Room, table, Stanza) : boolean
	handle_message_to_room : function (Room, table, Stanza) : boolean
	handle_message_to_occupant : function (Room, table, Stanza) : boolean
	handle_groupchat_to_room : function (Room, table, Stanza) : boolean
	handle_iq_to_occupant : function (Room, table, Stanza) : boolean
	handle_disco_info_get_query : function (Room, table, Stanza) : boolean
	handle_disco_items_get_query : function (Room, table, Stanza) : boolean
	handle_admin_query_set_command : function (Room, table, Stanza) : boolean
	handle_admin_query_get_command : function (Room, table, Stanza) : boolean
	handle_owner_query_get_to_room : function (Room, table, Stanza) : boolean
	handle_owner_query_set_to_room : function (Room, table, Stanza) : boolean
	handle_mediated_invite : function (Room, table, Stanza) : boolean
	handle_mediated_decline : function (Room, table, Stanza) : boolean
	handle_role_request : function (Room, table, Stanza) : boolean
	handle_register_iq : function (Room, table, Stanza) : boolean
	handle_kickable : function (Room, table, Stanza) : boolean

	-- Routing output
	broadcast : function (Room, Stanza, function (nick : string, Occupant) : boolean)
	broadcast_message : function (Room, Stanza) : boolean
	route_stanza : function (Room, Stanza)
	route_to_occupant : function (Room, Occupant, Stanza)

	-- Sending things to someone joining
	publicise_occupant_status :  function (Room, Occupant, x : Stanza, nick : string, actor : string, reason : string, prev_role : Role, force_unavailable : boolean, recipient : Occupant)
	send_occupant_list : function (Room, to : string, filter : function (occupant_jid : string, Occupant) : boolean)
	send_history : function (Room, Stanza)
	send_subject : function (Room, to : string, time : number)

	respond_to_probe : function (Room, table, Stanza, Occupant)

	-- Constructors for various answer stanzas
	get_disco_info : function (Room, Stanza) : Stanza
	get_disco_items : function (Room, Stanza) : Stanza

	build_item_list : function (Room, Occupant, Stanza, is_anonymous : boolean, nick : string, actor_nick : string, actor_jid : string, reason : string) : Stanza
	build_unavailable_presence : function (Room, from_muc_jid : string, to_jid : string) : Stanza

	-- Form handling
	send_form : function (Room, table, Stanza)
	get_form_layout : function (Room, actor : string) : table
	process_form : function (Room, table, Stanza) : boolean

	-- Properties and configuration
	get_name : function (Room) : string
	set_name : function (Room, string) : boolean
	get_description : function (Room) : string
	set_description : function (Room, string) : boolean
	get_language : function (Room) : string
	set_language : function (Room, string) : boolean
	get_hidden : function (Room) : boolean
	set_hidden : function (Room, boolean)
	get_public : function (Room) : boolean
	set_public : function (Room, boolean)
	get_password : function (Room) : string
	set_password : function (Room, string) : boolean
	get_members_only : function (Room) : boolean
	set_members_only : function (Room, boolean) : boolean
	get_allow_member_invites : function (Room) : boolean
	set_allow_member_invites : function (Room, boolean) : boolean
	get_moderated : function (Room) : boolean
	set_moderated : function (Room, boolean) : boolean
	get_persistent : function (Room) : boolean
	set_persistent : function (Room, boolean) : boolean
	get_changesubject : function (Room) : boolean
	set_changesubject : function (Room, boolean) : boolean
	get_subject : function (Room) : string
	set_subject : function (Room, string) : boolean
	get_historylength : function (Room) : integer
	set_historylength : function (Room, integer) : boolean
	get_presence_broadcast : function (Room) : { Role : boolean }
	set_presence_broadcast : function (Room, { Role : boolean }) : boolean

	is_anonymous_for : function (Room, jid : string) : boolean
	get_salt : function (Room) : string
	get_occupant_id : function (Room, Occupant)

	-- Room teardown
	clear : function (Room, x : Stanza)
	destroy : function (Room, newjid : string, reason : string, password : string) : boolean

	-- Room state persistence
	record FrozenRoom
		_jid : string
		_data : { string : any }
		_affiliation_data : { string : { string : any } }
		-- { string : Affiliation }
	end

	record StateEntry
		bare_jid : string
		role : Role
		jid : string
	end

	save : function (Room, forced : boolean, savestate : boolean) : boolean
	freeze : function (Room, live : boolean) : FrozenRoom, { string : StateEntry }
end

local record lib
	new_room : function (jid : string, config : { string : any }) : Room
	restore_room : function (Room.FrozenRoom, { string : Room.StateEntry }) : Room

	room_mt : metatable
end

return lib
