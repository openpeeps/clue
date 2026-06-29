## PluginKit for Ruby

This showcases the Clue PluginKit interface for Ruby, which allows you to create
native Ruby extensions (`.bundle`) in Nim using Ruby's C API.

### Prerequisites

- Ruby 3.0 or higher
- Nim 2.0 or higher
- Clue installed (`nimble install clue`)

### Simple example

```nim
import clue/kits/rubykit

rubyModule do:
  name: "Example"
  version: "0.1.0"

  proc hello(name: string) =
    echo "Hello ", name, " from Nim!"

  proc double(n: int) =
    result = INT2NUM(cint(n * 2))

  proc is_positive(n: float) =
    if n > 0.0:
      result = Qtrue
    else:
      result = Qfalse
```

### Build the extension

```
nim c --app:lib --out:"build/Example.bundle" plugin_example.nim
```

Or with the included `.nims`:

```
nim c plugin_example.nims
```

### Test the extension

```ruby
require_relative 'build/Example'

Example.hello("Ruby")
puts Example.greet("World")
puts Example.double(21)
puts Example.is_positive(3.14)
puts Example.repeat("go", 3)
```

### Debugging

Use `-d:clueDebugExtension` when compiling to see the generated Nim code.

```
nim c -d:clueDebugExtension --app:lib --out:"build/Example.bundle" plugin_example.nim
```
