// Fletcher - tests/run.js
// Loads the mocked WoW API into a fengari (Lua 5.3) VM, hands it every file
// the .toc lists (in load order), then runs tests/spec.lua, which boots the
// addon once per scenario. Nothing here ships with the addon.

"use strict";

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const root = path.resolve(__dirname, "..");

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function fail(where, message) {
  console.error("[" + where + "] " + message);
  process.exit(1);
}

function run(file) {
  const source = fs.readFileSync(path.join(root, file), "utf8");
  if (lauxlib.luaL_loadstring(L, to_luastring(source)) !== lua.LUA_OK) {
    fail(file, to_jsstring(lua.lua_tostring(L, -1)));
  }
  if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    fail(file, to_jsstring(lua.lua_tostring(L, -1)));
  }
}

// The addon's files must be plain ASCII.
for (const file of ["Fletcher.lua", "Fletcher_Vendor.lua", "Fletcher_Options.lua", "Fletcher.toc"]) {
  const text = fs.readFileSync(path.join(root, file), "utf8");
  const line = text.split(/\r?\n/).findIndex((entry) => /[^\x00-\x7F]/.test(entry));
  if (line !== -1) fail(file, "non-ASCII character on line " + (line + 1));
}

// The load order is the .toc's, so a file missing from it fails here too.
const tocFiles = fs.readFileSync(path.join(root, "Fletcher.toc"), "utf8")
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter((line) => line.length > 0 && !line.startsWith("#"));

run("tests/wow_stub.lua");

lua.lua_newtable(L);
tocFiles.forEach((file, index) => {
  const source = fs.readFileSync(path.join(root, ...file.split("\\")), "utf8");
  lua.lua_newtable(L);
  lua.lua_pushstring(L, to_luastring(file));
  lua.lua_setfield(L, -2, to_luastring("file"));
  lua.lua_pushstring(L, to_luastring(source));
  lua.lua_setfield(L, -2, to_luastring("source"));
  lua.lua_rawseti(L, -2, index + 1);
});
lua.lua_setglobal(L, to_luastring("__toc_files"));

run("tests/spec.lua");

lua.lua_getglobal(L, to_luastring("__exit_code"));
const code = lua.lua_tointeger(L, -1);
process.exit(code === 0 ? 0 : 1);
