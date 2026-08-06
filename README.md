# ContractIQ

The marketing site and the full application, ready to deploy to GitHub Pages.

---

## Two ways in

| URL | What it is | Needs setup? |
|---|---|---|
| `/demo/` | **The full app with sample analysis.** Every feature works — ingestion, OCR, search, obligations, clause matrix, knowledge, verification, exports. The AI returns realistic pre-written output instead of calling a model. | **No.** Works the moment the site is live. |
| `/app/` | **The same app with real AI.** Identical in every other way. | Yes — a Supabase project (about 20 minutes). |

Both run the **Enterprise edition**, so nothing is feature-gated. Sign in
with `admin` / `ContractIQ2026!`

**Start with `/demo/`.** It exercises everything except the model call, so
you can judge the whole product before spending anything or configuring
anything.

---

## Deploying

1. Create a repository and upload **the contents of this folder** (not the
   folder itself).
2. Settings → Pages → Source: *Deploy from a branch*, Branch `main`,
   Folder `/ (root)`. Save.
3. Wait a minute. You are live at `https://YOURNAME.github.io/REPO/`

> **Check `.nojekyll` made it.** Browsers hide dotfiles and drag-and-drop
> often skips them. If it is missing from the file list: **Add file →
> Create new file**, name it `.nojekyll`, leave it empty, commit. With
> Git, use `git add -A` rather than `git add .`
>
> The app is pre-compiled so it no longer contains anything Jekyll would
> choke on — but `.nojekyll` also stops Jekyll rewriting other files, so
> it is still worth having.

### If the build fails

Check <https://www.githubstatus.com> first. If **Actions** or **Pages**
show anything other than Operational, the failure is not yours — wait and
use **Re-run jobs**. Errors reading *"The job was not acquired by Runner
of type hosted"* always mean this: the job never started, so nothing in
your files caused it.

If GitHub is healthy and it still fails: Settings → Pages → set Source to
**None**, save, set it back. That clears stuck deployments.

---

## Turning on real AI (the `/app/` build)

1. Create a free project at [supabase.com](https://supabase.com).
2. SQL Editor → paste all of `supabase/schema.sql` → Run.
3. Project Settings → API → copy the **Project URL** and the **anon**
   key. (The *service role* key on that page must never go in the app.)
4. Get an Anthropic API key at
   [console.anthropic.com](https://console.anthropic.com), add a small
   amount of credit, and **set a spend limit**.
5. Deploy the proxy that holds your key:

```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF

supabase secrets set ANTHROPIC_API_KEY=sk-ant-your-key
supabase secrets set ALLOWED_ORIGIN=https://YOURNAME.github.io
supabase secrets set MAX_CALLS_PER_HOUR=60

supabase functions deploy anthropic-proxy --no-verify-jwt
```

6. Open `/app/`, sign in, **Settings** → paste the Supabase URL and anon
   key. The AI endpoint is derived from that URL automatically.

`ALLOWED_ORIGIN` must be the origin the **app** is served from — for
GitHub Pages that is `https://YOURNAME.github.io`, with no path and no
trailing slash. Get this wrong and every AI call returns 403.

### Cost

Hosting is free. The AI is not: roughly **£0.05 per contract analysis**
and **£0.01 per question**. Twenty contracts and fifty questions comes to
about **£1.50**.

---

## What to test

Fifteen minutes, in this order:

1. **Sign in.** The Terms tick box is required — that is deliberate.
2. **Load a sample portfolio** from the welcome panel. Look at the
   **renewal runway** immediately: contracts are plotted by *notice
   deadline*, and anything already past it is red.
3. **Select all → Analyse.** Watch the credit cost appear before it runs.
4. **Verify tab** on any record. Every value carries a confidence score,
   its reasoning and a quote from the source. Below 80% it is held back
   until you accept it.
5. **Suppliers.** Name variants merge into one row; near-misses are
   flagged for review.
6. **Clause matrix.** Gaps down a column are exposure; gaps across a row
   are your negotiating pattern.
7. **Knowledge.** Who holds undocumented context, and every verbal
   commitment that never reached a contract.
8. **Upload a transcript** to a record. A consent dialogue blocks the
   upload until you confirm participants were informed.
9. **Upload a scanned PDF.** It is flagged amber with a *Run OCR* button;
   OCR runs in your browser and the file is never transmitted.
10. **Ctrl+K** searches records, document text and every finding.
11. **Settings** → clear the workspace and start clean.

The stress-test pack (38 fictional documents with a 37-finding answer
key) is in the main package if you want something harder to throw at it.

---

## Notes

**Pre-compiled.** The app ships as plain JavaScript rather than JSX
transformed in the browser, so it loads faster and needs no Babel.

**If the app shows "Loading ContractIQ…" and stops**, your network is
blocking `cdnjs.cloudflare.com`. That is common on corporate machines.
Use the offline build from the main package — it has every library
embedded and needs no internet.

**Sign-in is demo-grade.** The credentials are inside the HTML, so anyone
with the URL can sign in. Fine for testing; before real users this moves
to Supabase Auth.

**Credits are display-only.** The balance is not enforced server-side
yet, so a modified client could exceed it. Fine while it is just you.

`supabase/` is reference material — it is not served to visitors.

ContractIQ is an automated screening aid, not legal advice.
