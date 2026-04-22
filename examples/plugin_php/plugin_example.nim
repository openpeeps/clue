import ../../src/clue/kits/phpkit

phpModule do:
  name = "hello"
  version = "0.1.0"

  proc helloWorld(name: string) =
    echo "👋 Hey there ", name, " 👑 Nim is Awesome!"