# ADR-0002: A Schedule holds by the clock, it does not start a Session

A Schedule keeps the Mac awake during a weekly window. Amphetamine models the same wish as a Trigger that starts a session when its criteria turn true, which is an edge: an app that was not running, or a Mac that was asleep, at 09:00 misses it and needs catch-up rules. Medusa treats a Schedule as a level instead. The engine asks "is now inside an enabled window?" on every evaluation and places a Schedule hold while the answer is yes. The Schedule hold is a third Hold on the one engine from ADR-0001, next to the Session and the Lock hold.

## Considered options

- A Schedule starts a Session at the window's start and ends it at the end. This reuses the Session code, but it misses the start after a late launch or a wake, a manual Stop would have to be remembered so the Schedule does not restart the Session, and Extend on a scheduled Session has no clear meaning.
- A Schedule arms a system wake (`pmset schedule`). It needs root and changes machine state outside the app.
- Chosen: a Schedule hold derived from the clock. Launch, wake, a time-zone change, and an edit in Settings all converge on the same answer with no stored state.

## Consequences

Stopping a Schedule for today is its own action. Pause holds the Schedule off until the open window ends, lives in memory only, and the next window opens as usual. The Battery guard covers the Schedule hold, because a Schedule keeps a Mac awake with nobody watching the charge. A Schedule does not pause idle auto-lock: it is a standing rule, not the "I am here, hands off" gesture that a Session is. The kernel timeout on the shared assertion is derived from every live Hold, since a Schedule hold or a Lock hold can outlive a finite Session.
