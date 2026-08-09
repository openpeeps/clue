# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Live two-line terminal output used by `clue install`:
##   line 1 — the spinning operation (e.g. `installing tim@0.2.7`)
##   line 2 — the current live event (cyan, indented), e.g. which package is
##            being fetched / installed / stored right now.
##
## Both lines update in place in real time so a run never looks hung.

import std/[os, terminal, times, monotimes, strutils]

const
  fgCyan = "\x1b[36m"
  reset  = "\x1b[0m"

type
  EventKind = enum
    evMain, evEvent, evStop, evSuccess, evFail

  Event = object
    kind: EventKind
    text: string

  Live* = ref object
    running: bool
    mainText: string
    eventText: string
    frames: seq[string]
    interval: int
    trackTime: bool
    startTime: MonoTime
    customSymbol: bool
    frame: string

var liveThread: Thread[Live]
var liveChannel: Channel[Event]

const dotFrames = @["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

proc newLive*(text: string, time = true): Live =
  result = Live(running: true, mainText: text, frames: dotFrames,
    interval: 30, trackTime: time)

proc setMain*(live: Live, text: string) =
  liveChannel.send(Event(kind: evMain, text: text))

proc event*(live: Live, text: string) =
  liveChannel.send(Event(kind: evEvent, text: text))

proc handle(live: Live, e: Event): bool =
  result = true
  case e.kind
  of evMain:
    live.mainText = e.text
  of evEvent:
    live.eventText = e.text
  of evStop:
    result = false
  of evSuccess:
    live.customSymbol = true
    live.frame = "✔"
    live.mainText = e.text
    live.eventText = ""
    result = false
  of evFail:
    live.customSymbol = true
    live.frame = "✖"
    live.mainText = e.text
    live.eventText = ""
    result = false

proc timeDiff(d: Duration): string =
  let minutes = int d.inMinutes()
  let seconds = int d.inSeconds()
  result = minutes.intToStr(2) & ":" & seconds.intToStr(2)

proc drawLine(s: string) =
  write(stdout, "\x1b[2K" & s)

proc render(live: Live, frame: string) =
  var main = frame & " " & live.mainText
  if live.trackTime:
    main = timeDiff(getMonoTime() - live.startTime) & " " & main
  let eventLine =
    if live.eventText.len > 0: "  " & fgCyan & live.eventText & reset
    else: ""

  # Always exactly two lines. Use cursor-down/up (never a linefeed) so the block
  # never scrolls or misaligns, and park the cursor back on line 1.
  drawLine(main)
  write(stdout, "\x1b[1B\r")
  drawLine(eventLine)
  write(stdout, "\x1b[1A\r")
  flushFile(stdout)

proc liveLoop(live: Live) {.thread.} =
  var frameCounter = 0
  if live.trackTime:
    live.startTime = getMonoTime()
  while live.running:
    let data = liveChannel.tryRecv()
    if data.dataAvailable:
      if not live.handle(data.msg):
        liveChannel.close()
        liveChannel = default(typeof(liveChannel))
        live.running = false
        live.render(live.frame)
        write(stdout, "\n")
        flushFile(stdout)
        break
    else:
      let frame =
        if live.customSymbol: live.frame
        else: live.frames[frameCounter]
      live.render(frame)
      frameCounter = (frameCounter + 1) mod live.frames.len
    sleep(live.interval)

proc start*(live: Live) =
  liveChannel.open()
  createThread(liveThread, liveLoop, live)

proc stop(live: Live, kind: EventKind, msg: string) =
  liveChannel.send(Event(kind: kind, text: msg))
  liveChannel.send(Event(kind: evStop))
  joinThread(liveThread)

proc success*(live: Live, msg: string) =
  live.stop(evSuccess, msg)

proc error*(live: Live, msg: string) =
  live.stop(evFail, msg)
