local stanza_t = require "prosody.util.stanza".stanza_t

local record lib
	record dataform
		title : string
		instructions : string

		record form_field is { form_field }

			enum field_type
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


		enum form_type
			"form"
			"submit"
			"cancel"
			"result"
		end

		form : function ( dataform, { string : any }, form_type ) : stanza_t
		data : function ( dataform, stanza_t ) : { string : any }
	end

	new : function ( dataform ) : dataform
end

return lib
