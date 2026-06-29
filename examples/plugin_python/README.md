## PluginKit for Python

This showcases the Clue PluginKit interface for Python, which allows you to
create native Python extensions (`.so`) in Nim using the CPython C API.

### Prerequisites

- Python 3.11 or higher
- Nim 2.0 or higher
- Clue installed (`nimble install clue`)

### Simple example

```nim
import clue/kits/pykit

pythonModule do:
  name: "mylib"

  proc hello(name: string) =
    result = PyUnicode_FromString(cstring("Hello " & name & " from Nim!"))

  proc add(a: int, b: int) =
    result = PyLong_FromLong(a + b)

  proc is_positive(n: float) =
    if n > 0.0: Py_RETURN_TRUE
    else: Py_RETURN_FALSE
```

### Build the extension

```
nim c --app:lib --out:"build/mylib.cpython-311-darwin.so" plugin_example.nim
```

Or with the included `.nims`:

```
nim c plugin_example.nims
```

### Test the extension

```python
import mylib

print(mylib.hello("Python"))
print(f"3 + 7 = {mylib.add(3, 7)}")
```

Run with:

```
PYTHONPATH="./build:$PYTHONPATH" python3 test_example.py
```

### Debugging

Use `-d:clueDebugExtension` when compiling to see the generated Nim code.
