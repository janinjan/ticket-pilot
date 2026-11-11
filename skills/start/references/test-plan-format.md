# Test plan format (step 7)

The test plan uses a QA format: it can be pasted as is into a Jira comment by the user. Write it in the user's language. Write the cases yourself, from the requests, the diff, the backend and the code.

**The plan contains NO code references**: no file paths, no `path:line`, no class, function, variable or field names, no endpoint paths, no code blocks and no backticks inside the cases. Describe everything functionally, as a QA person would: write "the delivery options call contains the postal code entered", not the field or endpoint names. The link between the plan and the code lives in the report (see "Coverage" below), never in the plan.



## Structure

1. **Prerequisites**: the build to use, the toggle state (described by what it does), the proxy and whether real (unaltered) traffic was used or which proxy rule altered it, the data sets (for example an eligible and a non-eligible postal code), the account or the starting screen.
2. **Numbered and titled cases**, `Case 1 – <title>`, each with:
   - the request it covers, as `(Request 2)`, when it covers one;
   - numbered steps;
   - expected results, each prefixed by where it is checked: `App:`, `Proxy:`…
3. **Complementary checks**: toggle OFF identical to production; out-of-scope cases unchanged; alignment with the other platforms when relevant.
4. **Open questions**: what the ticket does not decide, marked ❓.

After running the plan, mark every expected result:

- ✅ verified;
- ❌ failed, with what was actually observed;
- ❓ to be confirmed (could not be checked, or the expected value is written nowhere).

Every expected result and every observation names the exact state seen on screen, never a close one: "unchecked" is not "disabled" or "greyed out", "hidden" is not "empty". Before the report, check each wording against the screenshot or the answer it comes from.

## Coverage (in the report, outside the plan)

The final report adds a **Coverage** list next to the plan, one line per case: case title → request number and/or diff branch (`path:line`). This is where the traceability to the code goes; the plan itself stays free of it.

## Writing the cases

1. **One case per acceptance criterion** of the numbered request list, with the link case ↔ request as `(Request N)`.
2. **One case per branch added in the diff**: condition, null value, cache, reload, error path… not only what the ticket says. Read the diff hunk by hunk to find them. Describe the branch functionally in the case (for example "when the distance is missing"); its `path:line` goes only in the Coverage list of the report.
3. **Real data**: values found in the backend or the API docs (for example the postal codes of disabled areas) and behaviour read in the code, instead of examples "to be validated". Only what is written nowhere stays an open question.
4. **`Proxy:` checks** derived from the modified network call, worded functionally: what the call must contain or return, without endpoint or field names.
5. **Systematic complementary checks**: toggle OFF identical to production, out-of-scope cases unchanged, alignment with the other platforms if relevant.

## Example

```
Prerequisites
- Build: debug build of the branch, favourites feature ON (OFF for check A)
- Proxy: running, filtering on the favourites calls, no active rule: real (unaltered) traffic
- Account: test account with three items already visible in the catalogue, no favourite yet

Case 1 – Adding a favourite (Request 1)
1. Open the catalogue
2. Tap the heart on the first item
- Proxy: the call sent contains the identifier of the first item ✅
- App: the heart is filled and the item appears in the favourites list ✅

Case 2 – Removing a favourite (Request 2)
1. Open the favourites list
2. Tap the filled heart on the item
- App: the item disappears from the list and the heart is empty in the catalogue ❌ observed: the heart stays filled until the catalogue is reloaded

Case 3 – Empty state
1. Remove every favourite
2. Open the favourites list
- App: a message invites the user to add a first favourite, and no empty line is shown ✅

Complementary checks
A. Feature OFF: the catalogue is identical to production (no heart) ✅
B. Search results (out of scope): unchanged ✅

Open questions
❓ Is there a maximum number of favourites? The ticket and the design do not say.
```
