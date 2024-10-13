local record lib

	type children_iter = function ( stanza_t ) : stanza_t
	type childtags_iter = function () : stanza_t
	type maptags_cb = function ( stanza_t ) : stanza_t


	enum stanza_error_type
		"auth"
		"cancel"
		"continue"
		"modify"
		"wait"
	end
	enum stanza_error_condition
		"bad-request"
		"conflict"
		"feature-not-implemented"
		"forbidden"
		"gone"
		"internal-server-error"
		"item-not-found"
		"jid-malformed"
		"not-acceptable"
		"not-allowed"
		"not-authorized"
		"policy-violation"
		"recipient-unavailable"
		"redirect"
		"registration-required"
		"remote-server-not-found"
		"remote-server-timeout"
		"resource-constraint"
		"service-unavailable"
		"subscription-required"
		"undefined-condition"
		"unexpected-request"
	end

	record stanza_t is { stanza_t | string }
		name : string
		attr : { string : string }
		tags : { stanza_t }

		query : function ( stanza_t, string ) : stanza_t
		body : function ( stanza_t, string, { string : string } ) : stanza_t
		text_tag : function ( stanza_t, string, string, { string : string } ) : stanza_t
		tag : function ( stanza_t, string, { string : string } ) : stanza_t
		text : function ( stanza_t, string ) : stanza_t
		up : function ( stanza_t ) : stanza_t
		at_top : function ( stanza_t ) : boolean
		reset : function ( stanza_t ) : stanza_t
		add_direct_child : function ( stanza_t, stanza_t )
		add_child : function ( stanza_t, stanza_t )
		remove_children : function ( stanza_t, string, string ) : stanza_t

		get_child : function ( stanza_t, string, string ) : stanza_t
		get_text : function ( stanza_t ) : string
		get_child_text : function ( stanza_t, string, string ) : string
		get_child_attr : function ( stanza_t, string, string ) : string
		get_child_with_attr : function ( stanza_t, string, string, string, function (string) : boolean ) : string
		child_with_name : function ( stanza_t, string, string ) : stanza_t
		child_with_ns : function ( stanza_t, string, string ) : stanza_t
		children : function ( stanza_t ) : children_iter, stanza_t, integer
		childtags : function ( stanza_t, string, string ) : childtags_iter
		maptags : function ( stanza_t, maptags_cb ) : stanza_t
		find : function ( stanza_t, string ) : stanza_t | string

		top_tag : function ( stanza_t ) : string
		pretty_print : function ( stanza_t ) : string
		pretty_top_tag : function ( stanza_t ) : string

		-- FIXME Represent util.error support
		get_error : function ( stanza_t ) : stanza_error_type, stanza_error_condition, string, stanza_t
		add_error : function ( stanza_t, stanza_error_type, stanza_error_condition, string, string )
		indent : function ( stanza_t, integer, string ) : stanza_t
	end

	record serialized_stanza_t is { serialized_stanza_t | string }
		name : string
		attr : { string : string }
	end

	record message_attr
		["xml:lang"] : string
		from : string
		id : string
		to : string
		type : message_type
		enum message_type
			"chat"
			"error"
			"groupchat"
			"headline"
			"normal"
		end
	end

	record presence_attr
		["xml:lang"] : string
		from : string
		id : string
		to : string
		type : presence_type
		enum presence_type
			"error"
			"probe"
			"subscribe"
			"subscribed"
			"unsubscribe"
			"unsubscribed"
		end
	end

	record iq_attr
		["xml:lang"] : string
		from : string
		id : string
		to : string
		type : iq_type
		enum iq_type
			"error"
			"get"
			"result"
			"set"
		end
	end

	stanza : function ( string, { string : string } ) : stanza_t
	is_stanza : function ( any ) : boolean
	preserialize : function ( stanza_t ) : serialized_stanza_t
	deserialize : function ( serialized_stanza_t ) : stanza_t
	clone : function ( stanza_t, boolean ) : stanza_t
	message : function ( message_attr, string ) : stanza_t
	iq : function ( iq_attr ) : stanza_t
	reply : function ( stanza_t ) : stanza_t
	error_reply : function ( stanza_t, stanza_error_type, stanza_error_condition, string, string ) : stanza_t
	presence : function ( presence_attr ) : stanza_t
	xml_escape : function ( string ) : string
	pretty_print : function ( string ) : string
end

return lib
