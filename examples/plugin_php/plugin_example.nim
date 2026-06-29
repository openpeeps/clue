import ../../src/clue/kits/phpkit

phpModule do:
  name = "example"
  version = "0.1.0"

  ## Say hello — string param auto-converted from zval
  proc hello(name: string) =
    echo "Hello ", $name, " from Nim!"

  ## Greet — returns a formatted string
  proc greet(name: string) =
    toPhpString(retTy, "Greetings, " & $name & "!")

  ## Add two integers — returns the sum
  proc add(a: int, b: int) =
    toPhpInt(retTy, a + b)

  ## Double an integer
  proc double(n: int) =
    toPhpInt(retTy, n * 2)

  ## Check if a number is positive — returns boolean
  proc is_positive(n: float) =
    toPhpBool(retTy, n > 0.0)
