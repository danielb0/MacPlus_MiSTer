# Why Prince of Persia buzzed, and what we found when we chased it

A plain-language explanation of the sound timing work on this core. No
electronics or programming knowledge assumed.

For the technical version, with all the measurements and source references,
see `SOUND_PHASE_PLAN.md`.

## The complaint

Prince of Persia's music sounded wrong on the core - a buzzing, grating
quality that wasn't there on a real Mac. Almost nothing else was affected.
Games, system sounds, the startup chime: all fine. Just this one game.

That pattern is the interesting part. A fault that breaks *everything* is
usually something simple and central. A fault that breaks exactly one thing
means the one thing is doing something unusual, and you have to find out what.

## The Mac Plus has no sound chip

This is the thing that makes the whole story make sense.

Modern computers have dedicated sound hardware. You hand it some audio and it
plays it while the rest of the machine gets on with other work. The Mac Plus
had nothing like that. Apple saved the cost by making the *video* circuitry do
double duty.

The screen is drawn one horizontal line at a time, 370 lines for every
complete refresh, about 60 times a second. As the machine draws each line, it
also grabs one number out of a list in memory and sends it to the speaker.

So that list - 370 numbers long - *is* the sound. There's no play button and
no queue. The machine reads its way down the list forever, at a fixed speed,
whether anything useful is in there or not. To make a sound, a program has to
keep rewriting the list just behind the point the machine has read up to.

## A circular track

Picture a running track marked into 370 segments, joined into a loop.

A runner jogs round it at a steady, unchangeable pace - one segment per
screen line, all the way round about 60 times a second. That's the machine
reading the sound list. Nothing can speed the runner up or slow them down.

Meanwhile a painter has to keep repainting the segments with fresh markings -
that's the program writing new audio. The painter is much faster than the
runner, but only gets to work in bursts: once per lap, when a signal goes off.

The painter has one job: make sure that whatever segment the runner steps on
next has fresh paint on it.

Get this wrong in either direction and the runner steps on the wrong thing:

**Start painting too late.** The runner has already passed the segment you
meant to paint first. They saw the old markings. A glitch.

**Start painting too early.** The painter races round and catches up with the
runner from behind, repainting segments the runner hasn't reached yet with
markings meant for the *next* lap. Also a glitch.

There's a window in between where it works, and every program that made sound
on a Mac Plus had to aim for that window.

## Where the bug was

Each program picks a segment to start painting at. Prince of Persia starts at
segment 37. Lemmings starts at 32. The Mac's own built-in sound code starts at
50. Those choices are baked into the software and we can't change them.

What we *can* change is where the runner is when the signal goes off - because
it turns out our core had that wrong.

On the core, the runner was reset to the start line every lap. So when
Prince of Persia began painting at segment 37, the runner was right at the
beginning, barely moved. The painter then raced all the way round, came back,
and repainted six segments just before the runner got to them. Every lap.
Sixty times a second.

Sixty glitches a second is exactly what a buzz sounds like.

Everything else was unaffected because everything else starts painting further
round the track, or takes longer doing it, and doesn't lap the runner.

## The setting

We added a control that shifts where the runner is when the signal fires. It's
called the **sound scan phase**, and it's a number of segments. Zero is the
old behaviour. It doesn't change the speed of anything or the length of a lap,
it just slides the runner's position relative to the starting gun.

Then we measured it properly. We built a probe into the core that reports, for
every single lap, exactly where the runner was when the program's first brush
stroke landed. That turns the whole question from guesswork into readings.

With the setting at 28, Prince of Persia's buzz vanished, and the readings
explained precisely why. There was also a satisfying confirmation: the model
predicted the buzz would come *back* at a setting of 36, for a completely
different reason, and it did. A theory that only predicts success isn't worth
much; this one predicted a specific failure and got it.

Twenty-eight also had an appealing explanation. Of the 370 lines the Mac draws
per refresh, 28 of them are the beam travelling back to the top of the screen
with the picture switched off. The number matching looked like a real hardware
fact rather than a fudge.

So that's where it stood: fixed, explained, and apparently principled.

## Then the mouse

Moving the mouse made Lemmings crackle.

The natural suspect was our own mouse handling. A real Mac mouse was a big
slow ball-and-roller thing; a modern optical mouse produces movement data far
faster, and there was reason to think our core was flooding the Mac with it.

So we measured that too, without changing anything: the machine running
Lemmings, the probe reading every lap, under three conditions - mouse
untouched, mouse moved gently, mouse moved as fast as possible.

Two separate things came out, and only one of them is our fault.

**The cursor redraw.** Every time the mouse moves, the Mac redraws the cursor
before it lets any program do its per-lap work. That costs about 17 segments'
worth of time - the painter is held at the gate while the runner keeps going.
This is the Mac's own built-in behaviour. A real Mac Plus did exactly the same
thing, and we measured it doing so here. **Not our bug.**

**Our mouse flood.** We confirmed the suspicion: when you move a modern mouse
quickly, our core interrupts the Mac roughly four thousand times a second,
where a real mouse managed a few hundred. Worse, it keeps going for a quarter
of a second after your hand has stopped - which is also why the cursor feels
laggy. That's costing the Mac about a third of its attention. It's why the
game visibly slows down while the music doesn't: the music gets a guaranteed
slot each lap, and the game's animation has to live on the leftovers.
**Genuinely our bug, worth fixing on its own.**

## The awkward conclusion

Here's the problem. The cursor redraw alone - the authentic part, the part a
real Mac also did - eats 17 segments. At a setting of 28 there were only two
to spare. So the moment you touch the mouse, Lemmings glitches, and fixing our
mouse flood would not save it.

Which means 28 can't be what a real Mac Plus did.

And a real Mac Plus had no setting. It had one fixed value, permanently. So
whatever that value was, every program that shipped and sounded fine had to
work at it. Working backwards from what each program needs:

- Prince of Persia needs the runner **at least 9 segments** in, or it laps
  itself and buzzes.
- Lemmings, with the mouse moving, needs the runner **under 15 segments** in,
  or the cursor redraw pushes it past its deadline.

That leaves a narrow band, somewhere around **10**. Not 28.

The band being narrow is actually reassuring rather than worrying. Two
different companies wrote those two programs, independently, tuning them
against the same real hardware. You'd expect their requirements to close in
tightly around the true value. A wide, comfortable band would be the
suspicious result.

The catch is that it costs us the elegant explanation. The neat coincidence
with the 28 blank lines appears to be exactly that - a coincidence, which
happened to land inside Prince of Persia's acceptable window, which is why it
tested clean on everything that doesn't use the mouse.

## Where it stands

Measured and settled:

- Prince of Persia's buzz is a timing race, and the core had the timing wrong.
- The cursor redraw cost is real, is about 17 segments, and is authentic Mac
  behaviour that we should not try to "fix".
- Our mouse handling floods the machine and needs fixing, separately.
- A setting of 28 cannot be right, because it can't survive the authentic
  cursor redraw.

Still open:

- The exact right value. Around 10 on the evidence, but that needs a rebuild
  and another round of listening tests before anyone should believe it.
- One piece of evidence pointing the other way came from another emulator's
  author and has never been independently checked. It's the only thing arguing
  for a higher value, and our own measurements of a modern Mac system don't
  match it.

Nothing has been merged, and nothing has been released. It is worth being
precise about what does and doesn't exist, because it's easy to get wrong:

- **28 has never been built as the default.** Only one version of the core was
  ever compiled for this work. In that version the setting starts at zero, and
  28 is simply one of the four choices on the menu. That is how it was tested -
  by selecting it by hand.
- **The decision to make 28 the default was written down but never built.** It
  exists as a change to the source code on a side branch. No one has ever run
  a copy of the core that starts up at 28.
- **The released core is unaffected by all of this.** It has no such setting at
  all, and behaves as it always did.

There is a trap in that for whoever compiles next: the source currently *would*
produce a build defaulting to 28, which is the value the evidence now argues
against. That needs changing before anyone builds for general use.
