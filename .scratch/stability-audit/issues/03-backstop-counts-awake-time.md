# The Backstop counts awake time only

Type: grilling
Status: needs-triage

## Question

CONTEXT.md calls the Backstop "the absolute horizon after which a Lock releases itself". `LockController.startBackstop` uses a `Timer`, and timers stop while the Mac sleeps. A 4 hour Backstop on a Mac that sleeps for 8 hours with the lid closed fires 12 hours after the lock. Keep Awake already learned this ("deadlines, not stopwatches"). Should the Backstop be a wall-clock deadline too?

## The catch

With a wall-clock deadline, a Mac locked at night and opened in the morning unlocks itself on wake, with no authentication, whenever the lid stayed closed longer than the Backstop. The macOS lock screen covers that case only when "require password after sleep" is on.

A second, smaller interaction: with "Engage Medusa when idle" on, a Backstop release is followed by an idle auto-lock within 2 seconds, because the idle time is still past the threshold. The Backstop then only restarts the lock.

## Comments
