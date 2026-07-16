# {clue_pkg_name}

{clue_pkg_desc}

## Installation

```bash
nimble install {clue_pkg_name}
```

## Usage

```nim
import {clue_pkg_name}

proc main() {.async.} =
  var client = init{clue_client_ident}("your-api-key")
  let servers = await client.getServers()
  echo servers

waitFor main()
```

## License

{clue_pkg_license}
