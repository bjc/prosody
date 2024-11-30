local record lib
	record Set<T>
		add : function (Set, T)
		contains : function (Set, T) : boolean
		contains_set : function (Set, Set) : boolean
		items :  function (Set) : function (Set, T) : T
		remove : function (Set, T)
		add_list : function (Set, { T })
		include : function (Set, Set)
		exclude : function (Set, Set)
		empty : function (Set) : boolean
	end

	new : function<T> ({ T }) : Set<T>
	is_set : function (any) : boolean
	union : function (Set, Set) : Set
	difference : function (Set, Set) : Set
	intersection : function (Set, Set) : Set
	xor : function (Set, Set) : Set
end

return lib
