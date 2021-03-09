local stanza_t = require "util.stanza".stanza_t

local enum form_type
	"form"
	"submit"
	"cancel"
	"result"
end

local enum field_type
	"boolean"
	"fixed"
	"hidden"
	"jid-multi"
	"jid-single"
	"list-multi"
	"list-single"
	"text-multi"
	"text-private"
	"text-single"
end

local record form_field

	type : field_type
	var : string -- protocol name
	name :  string -- internal name

	label : string
	desc : string

	datatype : string
	range_min : number
	range_max : number

	value : any -- depends on field_type
	options : table
end

local record dataform
	title : string
	instructions : string
	{ form_field } -- XXX https://github.com/teal-language/tl/pull/415

	form : function ( dataform, table, form_type ) : stanza_t
end

local record lib
	new : function ( dataform ) : dataform
end

return lib
