# Summarise the council's verdict

A council of AI reviewers critiqued a subject, argued with each other, and a
chair wrote the full verdict below. You are writing the version someone reads
in a terminal before deciding what to do next.

## Required output

Plain text, no markdown headings, no bold, under 200 words. Exactly this shape:

VERDICT: <copy the chair's verdict verbatim>

<One paragraph, three sentences at most, saying what the change is and whether
it should proceed. Lead with the consequence, not the process.>

MUST FIX:
- <the blockers, one line each, most severe first. If there are none, write "nothing blocking".>

WORTH KNOWING:
- <at most three lines: major findings that are not blockers, and anything the
  council genuinely disagreed about. Say when a point was contested.>

## Rules

- Report only what the verdict below says. Add nothing of your own, and do not
  soften or upgrade a severity the chair already assigned.
- Prefer the chair's own wording for each finding's claim.
- If the verdict says the chair failed, say so plainly in one line and
  summarise whatever member output follows it instead.
- No preamble, no sign-off, no offer to help further. Start at VERDICT:.

## The chair's full verdict

{{VERDICT_REPORT}}
