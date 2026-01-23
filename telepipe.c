/* telepipe.c (startup and support code for Telepipe)
Copyright © 2026 Victoria Lacroix

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. */

#include <libintl.h>
#include <locale.h>
#include <lua.h>

#include <lauxlib.h>
#include <lualib.h>

/* The first macro quotes the argument name as a string. The second allows the passing of a macro value to be quoted instead. */
#define QUOTE(name) #name
#define MSTR(macro) QUOTE(macro)
/* Environment variables passed from the Makefile, whose values are made into C strings. */
#define APP_ID MSTR(PACKAGE)
#define APP_VER MSTR(VERSION)

static int
get_is_devel_lua(lua_State *L)
{
#ifdef DEVEL
	lua_pushboolean(L, 1);
#else
	lua_pushboolean(L, 0);
#endif
	return 1;
}

static int
get_app_id_lua(lua_State *L)
{
	lua_pushstring(L, APP_ID);
	return 1;
}

static int
get_app_ver_lua(lua_State *L)
{
#ifdef VERSION
	lua_pushstring(L, MSTR(VERSION));
#else
#error("VERSION macro is not defined!")
#endif
	return 1;
}

static int argc;
static char **argv;

static int
get_cli_args_lua(lua_State *L)
/* Returns each argument given to the command line. Used for the --new-window flag. */
{
	int i;
	for (i = 0; i < argc; ++i)
		lua_pushstring(L, argv[i]);
	return argc;
}

static int
gettext_lua(lua_State *L)
/* Returns a localized string using gettext(). */
{
	const char *msgid;
	char *msg;

	msgid = luaL_checkstring(L, 1);
	if (!msgid) {
		luaL_pushfail(L);
		return 1;
	}

	msg = gettext(msgid);
	lua_pushstring(L, msg);
	return 1;
}

static const luaL_Reg telepipelib[] = {
	{ "get_is_devel", get_is_devel_lua },
	{ "get_app_id", get_app_id_lua },
	{ "get_app_ver", get_app_ver_lua },
	{ "get_cli_args", get_cli_args_lua },
	{ "gettext", gettext_lua },
	/* sentinel item, marks the end of the array */
	{ NULL, NULL },
};

const char telepipe_bytecode[] = {
#embed "telepipe.bytecode"
};

int
main(int _argc, char **_argv)
{
	lua_State *L;
	const char *message;
	int lua_result;

	setlocale(LC_ALL, "");
	/* Tells gettext where to look for messages files. Dest should be /app/share/locale/<lang>/LC_MESSAGES/<domain>.mo */
	bindtextdomain("messages", "/app/share/locale");
	textdomain("messages");

	argc = _argc;
	argv = _argv;

	L = luaL_newstate();
	luaL_openlibs(L);
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_remove(L, -2);
	lua_pushstring(L, "telepipelib");
	luaL_newlib(L, telepipelib);
	lua_settable(L, -3);
	lua_remove(L, -1);

	lua_result = luaL_loadbuffer(L, telepipe_bytecode, sizeof (telepipe_bytecode), APP_ID);
	switch (lua_result) {
	case LUA_ERRSYNTAX:
		fprintf(stderr, "Failed to load Telepipe: binary is malformed.\n");
		message = luaL_checkstring(L, -1);
		if (message)
			fprintf(stderr, "%s\n", message);
		return 1;
	case LUA_ERRMEM:
		fprintf(stderr, "Failed to load Telepipe: could not allocate memory.\n");
		return 2;
	case LUA_OK:
		break;
	default:
		fprintf(stderr, "Failed to load Telepipe: an unhandled error ocurred.\n");
		return -1;
	}

	lua_call(L, 0, 0);
	return 0;
}
