import ../../src/clue/kits/rubykit

rubyModule do:
  name: "Example"
  version: "0.1.0"

  ## Simple hello — string param auto-converted from VALUE
  proc hello(name: string) =
    echo "Hello ", name, " from Nim!"

  ## Greet with sprintf — returns formatted Ruby string
  proc greet(name: string) =
    result = rb_sprintf("Hi, %s!", cstring(name))

  ## Double an integer — return via Ruby's INT2NUM
  proc double(n: int) =
    result = INT2NUM(cint(n * 2))

  ## Check if a float is positive — return Qtrue/Qfalse
  proc is_positive(n: float) =
    if n > 0.0:
      result = Qtrue
    else:
      result = Qfalse

  ## Repeat a string and collect results into a Ruby array
  proc repeat(msg: string, count: int) =
    let ary = rb_ary_new()
    for i in 0 ..< count:
      discard rb_ary_push(ary, rb_str_new_cstr(cstring(msg & " " & $i)))
    result = ary
