local record lib
	record Set<T>
		add : function<T> (Set<T>, T)
		contains : function<T> (Set<T>, T) : boolean
		contains_set : function<T> (Set<T>, Set<T>) : boolean
		items :  function<T> (Set<T>) : function<T> (Set<T>, T) : T
		remove : function<T> (Set<T>, T)
		add_list : function<T> (Set<T>, { T })
		include : function<T> (Set<T>, Set<T>)
		exclude : function<T> (Set<T>, Set<T>)
		empty : function<T> (Set<T>) : boolean
	end

	new : function<T> ({ T }) : Set<T>
	is_set : function (any) : boolean
	union : function<T> (Set<T>, Set<T>) : Set <T>
	difference : function<T> (Set<T>, Set<T>) : Set <T>
	intersection : function<T> (Set<T>, Set<T>) : Set <T>
	xor : function<T> (Set<T>, Set<T>) : Set <T>
end

return lib
