import ../../src/clue/kits/pykit

pythonModule do:
  name: "mylib"
  doc: "Example Nim extension built with Clue"

  proc hello(name: string) =
    result = toPyString("Hello " & name & " from Nim!")

  proc add(a: int, b: int) =
    result = toPyInt(a + b)

  proc twice(n: int) =
    result = toPyInt(n * 2)

  proc is_positive(n: float) =
    result = toPyBool(n > 0.0)

  proc greet(name: string) =
    result = toPyString("Greetings, " & name & "!")
