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
- [ ] Plugin Kit interaface for PHP, Python, Ruby, Node.js and more
- [ ] Generate API bindings for Go, C, C++, D, Crystal, Dart, Zig and more
- [ ] Generate C header files for your Nim library
- [ ] Package generator for target languages (`gem`, `pypi`, `npm`, `composer`)
- [x] Simple, macro-based DSL for creating extensions in Nim
- [ ] Generate HTTP clients from OpenAPI 3.0 specs
- [ ] Documentation database for local packages

> [!NOTE]
> Clue is an effort to create a unified interface for generating native libraries and extensions for other languages in Nim.

## Plugin Kit examples
Currently, only the PHP plugin kit is available, adding more plugin interfaces is on the roadmap.

### PHP example
Here's a simple example of a PHP extension written in Nim.

```nim
import clue/kits/phpkit

phpModule do:
  name = "hello"
  version = "0.1.0"

  proc helloWorld(name: string) =
    ecoh "👋 Hey there", name, " 👑 Nim is Awesome!"
```
- Check the [PHP example](examples/plugin_php/README.md) directory

### JS example
Here's a simple example of a Node.js addon written in Nim using the (upcoming) Node.js plugin kit.
```nim
import clue/kits/jskit

jsModule do:
  name = "hello"
  version = "0.1.0"

  proc helloWorld(name: string) =
    echo "👋 Hey there ", name, " 👑 Nim is Awesome!"
```

Exactly! We are doing it in the same way as the PHP plugin kit, that is the beauty of the Nim-based DSL approach!

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

Local documentation generation comes with other benefits as well! Clue has LLM integration, offers a RAG capability for your local documentation, and can even generate a local search index for your docs to make them easily searchable from the command line.


## Todo
- [ ] Plugin kits - Add support for version detection and other runtime checks
- [ ] Plugin kits - More languages (Python, Ruby, [Node.js via Denim](https://github.com/openpeeps/denim), etc.)
- [ ] Plugin kits - Add a `initModules` macro for bulk definitions. Crazy!

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/clue/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/clue/fork)
- 😎 [Get €20 in cloud credits from Hetzner](https://hetzner.cloud/?ref=Hm0mYGM9NxZ4)

### 🎩 License
Clue | LGPL-v3 license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
