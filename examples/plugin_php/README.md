## PluginKit for PHP
Thiis will showcase various features of the Clue PluginKit interface for PHP, which allows you to create native PHP extensions in Nim. Amazing!

### Prerequisites
- PHP 8.0 or higher
- Nim 2.0 or higher
- Clue installed `nimble install clue`

## Simple example

```nim
import clue/kits/phpkit

phpModule do:
  name = "hello"
  version = "0.1.0"

  proc helloWorld(name: string) =
    ecoh "👋 Hey there", name, " 👑 Nim is Awesome!"
```

That's it!

### Build the extension
This is easy peasy, just tell Nim you want that juice!
```
nim c --app:lib --out:"build/plugin_example.so" plugin_example.nim
```

### Add the extension
Find the `php.ini` file on your system (use `php83 --ini`), there you will have to add the absolute path to the compiled plugin:
```ini
extension=/path/to/build/plugin_example.so
```

### Test the extension
Create a basic PHP file to test the extension:
```php
<?php

echo helloWorld("PHP"); // "👋 Hey there PHP 👑 Nim is Awesome!"
```

## Debugging your extension
Use `-d:clueDebugExtension` when compiling your extension to show the generated Nim code. 

If something goes wrong you may want to see the error messages in PHP. You can do this by running PHP with the `-d` flag to set the following flags
```
php -d extension=./plugin_example.so -d display_errors=1 -d error_reporting=E_ALL plugin_example.php
```