# Self-Review Checklist

After completing your changes, re-read the entire document you produced. For each change you made, check:

1. **Conflicts:** Does this change conflict with anything else in the document?
 - Internal contradictions: Does any section contradict another section?
 - Tooling conflicts: If you added a new tool/script/hook, does it conflict with existing tools the document already describes?
 - Downgrades: Did you replace an existing capability with a weaker one?

2. **Edge cases:** Does this change introduce a new edge case?
 - What inputs would break this?
 - What happens on failure?
 - What about automated/non-human usage?

3. **Interactions:** Does this change interact with another change you made in this same pass?
 - Trace through any scenario where two of your changes touch the same feature or flow.

4. **New additions:** Did you add a new feature, constraint, or number?
 - If yes, trace through its full execution path — what happens when it succeeds AND when it fails?

5. **Evidence-gated verification:** For every claim that you "verified" something exists (a config field, function, file, type, import):
 - You MUST paste the actual evidence: the line of code, the config field, the file path you read.
 - Format: `VERIFIED: <thing> found at <file:line> — "<quoted evidence>"`
 - If you cannot paste evidence, you MUST write `UNVERIFIED: could not locate <thing>` instead.
 - NEVER write "I verified X" without pasting the evidence. A claim without evidence is treated as false.

If you find a problem with your own change, fix it immediately and note it as `SELF-CAUGHT: [description]` so downstream stages can verify your self-correction.
