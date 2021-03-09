local record lib

	type children_iter = function ( stanza_t ) : stanza_t
	type childtags_iter = function () : stanza_t
	type maptags_cb = function ( stanza_t ) : stanza_t

	record stanza_t
		name : string
		attr : { string : string }
		{ stanza_t | string }
		tags : { stanza_t }

		query : function ( stanza_t, string ) : stanza_t
		body : function ( stanza_t, string, { string : string } ) : stanza_t
		text_tag : function ( stanza_t, string, string, { string : string } ) : stanza_t
		tag : function ( stanza_t, string, { string : string } ) : stanza_t
		text : function ( stanza_t, string ) : stanza_t
		up : function ( stanza_t ) : stanza_t
		reset : function ( stanza_t ) : stanza_t
		add_direct_child : function ( stanza_t, stanza_t )
		add_child : function ( stanza_t, stanza_t )
		remove_children : function ( stanza_t, string, string ) : stanza_t

		get_child : function ( stanza_t, string, string ) : stanza_t
		get_text : function ( stanza_t ) : string
		get_child_text : function ( stanza_t, string, string ) : string
		child_with_name : function ( stanza_t, string, string ) : stanza_t
		child_with_ns : function ( stanza_t, string, string ) : stanza_t
		children : function ( stanza_t ) : children_iter, stanza_t, number
		childtags : function ( stanza_t, string, string ) : childtags_iter
		maptags : function ( stanza_t, maptags_cb ) : stanza_t
		find : function ( stanza_t, string ) : stanza_t | string

		top_tag : function ( stanza_t ) : string
		pretty_print : function ( stanza_t ) : string
		pretty_top_tag : function ( stanza_t ) : string

		get_error : function ( stanza_t ) : string, string, string, stanza_t
		indent : function ( stanza_t, number, string ) : stanza_t
	end

	record serialized_stanza_t
		name : string
		attr : { string : string }
		{ serialized_stanza_t | string }
	end

	stanza : function ( string, { string : string } ) : stanza_t
	is_stanza : function ( any ) : boolean
	preserialize : function ( stanza_t ) : serialized_stanza_t
	deserialize : function ( serialized_stanza_t ) : stanza_t
	clone : function ( stanza_t, boolean ) : stanza_t
	message : function ( { string : string }, string ) : stanza_t
	iq : function ( { string : string } ) : stanza_t
	reply : function ( stanza_t ) : stanza_t
	error_reply : function ( stanza_t, string, string, string, string )
	presence : function ( { string : string } ) : stanza_t
	xml_escape : function ( string ) : string
end

return lib
