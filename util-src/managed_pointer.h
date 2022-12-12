/* managed_pointer.h

These macros allow wrapping an allocator/deallocator into an object that is
owned and managed by the Lua garbage collector.

Why? It is too easy to leak objects that need to be manually released, especially
when dealing with the Lua API which can throw errors from many operations.

USAGE
-----

For example, given an object that can be created or released with the following
functions:

  fancy_buffer* new_buffer();
  void free_buffer(fancy_buffer* p_buffer)

You could declare a managed version like so:

  MANAGED_POINTER_ALLOCATOR(new_managed_buffer, fancy_buffer*, new_buffer, free_buffer)

And then, when you need to create a new fancy_buffer in your code:

  fancy_buffer *my_buffer = new_managed_buffer(L);

NOTES
-----

Managed objects MUST NOT be freed manually. They will automatically be
freed during the next GC sweep after your function exits (even if via an error).

The managed object is pushed onto the stack, but should generally be ignored,
but you'll need to bear this in mind when creating managed pointers in the
middle of a sequence of stack operations.
*/

#define MANAGED_POINTER_MT(wrapped_type) #wrapped_type "_managedptr_mt"

#define MANAGED_POINTER_ALLOCATOR(name, wrapped_type, wrapped_alloc, wrapped_free) \
  static int _release_ ## name(lua_State *L) {                                \
  	wrapped_type *p = (wrapped_type*)lua_topointer(L, 1);                 \
  	if(*p != NULL) {                                                      \
	  	wrapped_free(*p);                                             \
	}                                                                     \
  	return 0;                                                             \
  }                                                                           \
  static wrapped_type name(lua_State *L) {                                    \
  	wrapped_type *p = (wrapped_type*)lua_newuserdata(L, sizeof(wrapped_type)); \
  	if(luaL_newmetatable(L, MANAGED_POINTER_MT(wrapped_type)) != 0) {     \
  		lua_pushcfunction(L, _release_ ## name);                      \
  		lua_setfield(L, -2, "__gc");                                  \
  	}                                                                     \
  	lua_setmetatable(L, -2);                                              \
  	*p = wrapped_alloc();                                                 \
  	if(*p == NULL) {                                                      \
  		lua_pushliteral(L, "not enough memory");                      \
  		lua_error(L);                                                 \
  	}                                                                     \
  	return *p;                                                            \
  }

