# Screen monitoring on work PCs — what you should know

*Owner: adapt the names, hours and contact below, then share this with the team before the rollout.*

Hi team,

Starting on **[date]**, the work PCs run a small program called **screenlog**. This note explains
exactly what it does and does not do.

## What is captured

- **Screenshots of the whole screen** (all monitors), at random moments, on average **7 per hour**
  — roughly one every 8 to 9 minutes, never on a fixed schedule.
- With each screenshot, **how long the keyboard and mouse have been idle**. A screenshot counts as
  "active" when you used the PC in the last 5 minutes.
- Only during **capture hours: [09:00] to [17:50]**, [Sunday to Thursday] included. Outside those
  hours nothing is captured.
- When the screen is **locked**, nothing is captured; the program only notes "locked".

## What is never captured

- Keystrokes or what you type. Idle time is a single number ("3 minutes since the last input"),
  not a log of keys.
- Audio, webcam or microphone.
- Browser history, passwords, clipboard contents or window titles.
- Anything while the screen is locked, or outside capture hours.

## Who can see the screenshots

- The screenshots are uploaded to a company Google Drive account that only **[owner name]** can
  open. They are not shared with anyone else.
- Once a day, at **[17:30]**, a summary (number of screenshots, active percentage, a small overview
  image) is posted to a private Discord channel that only **[owner name]** can read.
- The screenshots on the PC itself are stored in a folder only the administrator account can read.

## How long they are kept

- On the PC: about **7 days**, then deleted automatically.
- In Drive: **60 days**, then moved to the trash automatically.

## Tips

- **Lock the screen (`Super` + `L`) before doing anything personal** — nothing is captured while it
  is locked.
- You can see that the program is running with `systemctl status screenlog`; it is a normal system
  service, not hidden.
- Questions or concerns: talk to **[owner name / contact]**.

Thanks,
[owner]
