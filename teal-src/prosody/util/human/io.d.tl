local record lib
	getchar : function (n : integer) : string
	getline : function () : string
	getpass : function () : string
	show_yesno : function (prompt : string) : boolean
	read_password : function () : string
	show_prompt : function (prompt : string) : boolean
	printf : function (fmt : string, ... : any)
	padleft : function (s : string, width : integer) : string
	padright : function (s : string, width : integer) : string

	-- {K:V} vs T ?
	record tablerow<K,V>
		width : integer | string -- generate an 1..100 % enum?
		title : string
		mapper : function (V, {K:V}) : string
		key : K
		enum alignments
			"left"
			"right"
		end
		align : alignments
	end
	type getrow = function<K,V> ({ K : V }) : string
	table : function<K,V> ({ tablerow<K,V> }, width : integer) : getrow<K,V>
end

return lib
