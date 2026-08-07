import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

proc doctorCheckCommand*(v: Values) =
  ## kapsis cli command for running a `docker.check` command
  discard