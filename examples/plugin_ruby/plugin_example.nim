import ../../src/clue/kits/rubykit

rubyModule do:
  name: "Example"
  version: "0.1.0"

  ## Simple hello — string param auto-converted from VALUE
  proc hello(name: string) =
    echo "Hello ", name, " from Nim!"

  ## Greet — returns formatted Ruby string
  proc greet(name: string) =
    result = toRbString("Hi, " & name & "!")

  ## Double an integer
  proc double(n: int) =
    result = toRbInt(n * 2)

  ## Check if a float is positive
  proc is_positive(n: float) =
    result = toRbBool(n > 0.0)

  ## Repeat a string and collect results into a Ruby array
  proc repeat(msg: string, count: int) =
    let ary = toRbArray()
    for i in 0 ..< count:
      discard rb_ary_push(ary, toRbString(msg & " " & $i))
    result = ary
