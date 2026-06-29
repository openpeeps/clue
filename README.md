<p align="center">
  A toolkit for cool developers
</p>

<p align="center">
  <code>nimble install clue</code>
</p>

<p align="center">
  <a href="https://github.com/">API reference</a><br>
  <img src="https://github.com/openpeeps/clue/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/clue/workflows/docs/badge.svg" alt="Github Actions">
</p>

### Why Clue?
Because sometimes I have no damn clue how to... 😂

## 😍 Key Features
- [x] Plugin Kit interface for **PHP**, **Ruby**, **Lua**, **Python** and more
- [ ] Generate API bindings for Go, C, C++, D, Crystal, Dart, Zig and more
- [ ] Generate C header files for your Nim library
- [ ] Package generator for target languages (`gem`, `pip`, `npm`, `composer`)
- [x] Simple, macro-based DSL for creating extensions in Nim
- [ ] Generate HTTP clients from OpenAPI 3.0 specs
- [ ] Documentation database for local packages

> [!NOTE]
> Clue is an effort to create a unified interface for generating native libraries and extensions for other languages in Nim, enjoying the power of native performance and low-level capabilities of Nim while providing a super dev-friendly experience for authors. Do the do!

## Plugin Kits

All kits follow the same macro-based DSL pattern. Write your logic once in Nim, generate native extensions for the target language.

### PHP
```nim
import clue/kits/phpkit

phpModule do:
  name = "example"
  version = "0.1.0"

  proc hello(name: string) =
    echo "Hello ", $name, " from Nim!"

  proc add(a: int, b: int) =
    php_zval_long(retTy, zend_long(a + b))
```

- [PHP example](examples/plugin_php/README.md)

### Ruby
```nim
import clue/kits/rubykit

rubyModule do:
  name: "Example"
  version: "0.1.0"

  proc hello(name: string) =
    echo "Hello ", name, " from Nim!"

  proc add(a: int, b: int) =
    result = INT2NUM(cint(a + b))
```

- [Ruby example](examples/plugin_ruby/README.md)

### Lua (LuaJIT)
```nim
import clue/kits/luakit

luaModule do:
  name: "mylib"

  proc hello(name: string) =
    lua_pushstring(L, cstring("Hello " & name & " from Nim!"))
    return 1

  proc add(a: int, b: int) =
    lua_pushinteger(L, a + b)
    return 1
```

- [Lua example](examples/plugin_lua/README.md)

### Python
```nim
import clue/kits/pykit

pythonModule do:
  name: "mylib"

  proc hello(name: string) =
    result = PyUnicode_FromString(cstring("Hello " & name & " from Nim!"))

  proc add(a: int, b: int) =
    result = PyLong_FromLong(a + b)
```

- [Python example](examples/plugin_python/README.md)

<details>
  <summary>Use <code>-d:clueDebugExtension</code> to inspect the generated code 👇</summary>
  Pass this flag when compiling to see the Nim-to-C expansion for any module kit:

```
nim c -d:clueDebugExtension --app:lib -o:out.so my_extension.nim
```
</details>

> [!NOTE]
> All major dynamic languages that support native extensions will be supported via plugin kits, and the goal is to have a unified DSL for defining extensions across all supported languages. Write your logic once in Nim, and generate native extensions for the community in multiple languages without spending time learning all the details of each language's native extension API.

## Package generator
The goal is to generate the structure of a package for the target language, including the necessary metadata files (`package.json`, `setup.py`, `*.gemspec`, etc.) and the generated native library or extensio directly from Clue CLI

_TODO_

## API bindings generator
The API bindings generator will allow you to generate C-like header files and bindings for your Nim code to be consumed by other languages. Similar to [@treeform/genny](https://github.com/treeform/genny), but for Clue we can extend this concept to all low-level languages (C, C++, D, Crystal, Dart, Zig, Rust, etc.) and provide a unified interface for generating bindings for your Nim code.

_TODO_

## Documentation Builder
Clue offers a local documentation generator built on top of the built-in Nim doc system. Why? Because most of the time, package authors may focus on writing code and don't provide a easy way to access documentation for their packages.

For OpenPeeps packages I always want to generate API references for all our packages via GitHub Actions and make them easily accessible via the GitHub Pages, but for local development, I want a simple way to generate and access documentation for any local package without needing to set up a separate documentation hosting solution.

Local documentation generation comes with other benefits as well! Clue has LLM integration, offers a RAG capability for your local documentation, and can generate a local search index for your docs to make them easily searchable from the command line.

## Todo
- [ ] Plugin kits - Add support for version detection and other runtime checks
- [ ] Plugin kits - More languages (Crystal, Dart, Zig, etc.)
- [ ] Plugin kits - Add a `initModules` macro for bulk definitions. Crazy!

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/clue/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/clue/fork)
- 😎 [Get €20 in cloud credits from Hetzner](https://hetzner.cloud/?ref=Hm0mYGM9NxZ4)

### 🎩 License
Clue | MIT license. [Made by humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
