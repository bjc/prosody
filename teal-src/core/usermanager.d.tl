local Role = require "util.roles".Role;

local record usermanager
	record AuthProvider
		-- TODO
	end
	record AccountInfo
		created : number
		password_updated : any
		enabled : boolean
	end

	-- Users
	test_password : function (username : string, host : string, password : string) : boolean
	get_password : function (username : string, host : string) : string, string
	set_password : function (username : string, host : string, password : string) : boolean, string
	get_account_info : function (username : string, host : string) : AccountInfo
	user_exists : function (username : string, host : string) : boolean
	create_user : function (username : string, password : string, host : string) : boolean, string
	delete_user : function (username : string, host : string) : boolean, string
	users : function (host : string) : function () : string

	-- Roles
	get_user_role : function (username : string, host : string) : Role
	set_user_role : function (username : string, host : string, role_name : string) : boolean, string
	user_can_assume_role : function (username : string, host : string, role_name : string) : boolean
	add_user_secondary_role : function (username : string, host: string, role_name : string) : boolean, string
	remove_user_secondary_role : function (username : string, host: string, role_name : string) : boolean, string
	get_user_secondary_roles : function (username : string, host : string) : { string : Role }
	get_users_with_role : function (role : string, host : string) : { string }
	get_jid_role : function (jid : string, host : string) : Role
	set_jid_role : function (jid : string, host : string, role_name : string) : boolean
	get_jids_with_role : function (role : string, host : string) : { string }
	get_role_by_name : function (role_name : string) : Role

	-- Etc
	get_provider : function (host : string) : AuthProvider
	get_sasl_handler : function (host : string, session : table) : table
	initialize_host : function (host : string)
	new_null_provider : function () : AuthProvider
end

return usermanager
