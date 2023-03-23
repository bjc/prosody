local record util_roles

	type context = any

	record Role
		id : string
		name : string
		description : string
		default : boolean
		priority : number -- or integer?
		permissions : { string : boolean }

		may : function (Role, string, context)
		clone : function (Role, role_config)
		set_permission : function (Role, string, boolean, boolean)
	end

	is_role : function (any) : boolean

	record role_config
		name : string
		description : string
		default : boolean
		priority : number -- or integer?
		inherits : { Role }
		permissions : { string : boolean }
	end

	new : function (role_config, Role) : Role
end

return util_roles
