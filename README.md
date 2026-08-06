# ContractIQ — GitHub Pages package (fixed)

This replaces what you uploaded before. Delete the old files from the
repository and upload these instead.

---

## What was wrong

**The app file contains 355 instances of `{{`.**

They come from the React code — inline styles are written as
`style={{ position: "fixed" }}`. That is perfectly valid JavaScript.

But GitHub Pages runs **Jekyll** over your repository by default, and
Jekyll's template engine treats `{{ ... }}` as a variable to substitute.
It hits `{{ position: "fixed" }}`, cannot parse it, and the build dies.
GitHub's documentation lists this exact failure as *"Page build failed:
Tag not properly terminated"*.

**The fix is a single empty file called `.nojekyll`.** Its presence tells
GitHub Pages to skip Jekyll entirely and serve your files exactly as they
are — which is what you want, because nothing here needs building.

It is already included in this package.

---

## Honest caveat about your specific error

The message you saw was `Internal server error. Correlation ID: …`
rather than a named Jekyll error. That generic message is **also** a
common GitHub-side infrastructure fault — several recent reports show it
appearing alongside *"The job was not acquired by Runner of type hosted"*,
which is a runner problem, not a content problem.

So there are two possibilities:

1. **Jekyll choked on the `{{`** — fixed by `.nojekyll` in this package.
2. **GitHub was having a bad day** — nothing in your files caused it.

The `{{` problem is real either way and would have broken the build
sooner or later, so it needed fixing regardless. If the build still
fails after uploading this package, it is cause 2 — see Troubleshooting
at the bottom.

---

## What else changed

**Removed `api/` and `.htaccess`.** These are Apache and PHP files for
Hostinger. GitHub Pages cannot run PHP — it serves `.php` files as plain
text, so anyone visiting `/api/config.example.php` would read the file
rather than execute it. They do nothing useful here and are better left
out. Keep using them when you deploy to Hostinger.

**Added the app at `/app/`.** Your site and the working application are
now in one repository, so `yourname.github.io/repo/app/` just works.

**Added an optional GitHub Actions workflow.** See below.

---

## How to upload

### Option A — replace the files in your existing repository

1. In your repository, delete the old files (select them, Delete).
2. Click **Add file → Upload files**.
3. Drag in **the contents of this folder**, not the folder itself.
4. Commit.

> **Watch out for the dotfiles.** Browsers often hide files whose names
> start with a dot, and drag-and-drop may silently skip `.nojekyll`.
> After uploading, check the file list — if `.nojekyll` is not there,
> click **Add file → Create new file**, type `.nojekyll` as the name,
> leave the contents empty, and commit. This one file is the whole fix,
> so it is worth confirming.

### Option B — start a clean repository

If the old one is in a confusing state, this is often faster:

1. Create a new repository.
2. Upload the contents of this folder.
3. Settings → Pages → Source: *Deploy from a branch*, Branch: `main`,
   Folder: `/ (root)`. Save.

### With Git

```bash
cd path/to/this/folder
git init
git add -A          # -A includes dotfiles; plain "git add ." can miss them
git commit -m "ContractIQ site and app"
git branch -M main
git remote add origin https://github.com/YOURNAME/YOURREPO.git
git push -u origin main --force
```

---

## Checking it worked

Give it a minute or two, then:

| Check | Expected |
|---|---|
| Actions tab | "pages build and deployment" green |
| `yourname.github.io/repo/` | The marketing site, with the background animation |
| `yourname.github.io/repo/app/` | The app sign-in screen |
| Sign in | `admin` / `ContractIQ2026!` |

---

## Troubleshooting

**Still "Internal server error" after uploading this?**
Then it is GitHub's side, not yours. In order:

1. Actions tab → the failed run → **Re-run all jobs**. Transient faults
   usually clear on a retry.
2. Check <https://www.githubstatus.com> for Pages and Actions.
3. Settings → Pages → set Source to **None**, save, then set it back to
   your branch. This recreates the deployment workflow and clears a
   surprising number of stuck states.
4. Push any trivial commit to trigger a fresh run.
5. If it persists for more than a few hours, switch to the Actions
   route: Settings → Pages → Source: **GitHub Actions**. The included
   `.github/workflows/deploy-pages.yml` takes over and bypasses the
   default build path completely.

**Site builds but pages 404.**
Check the Pages folder setting is `/ (root)` and not `/docs`.

**Site loads but looks unstyled, or the app is blank.**
The browser is loading a cached copy — hard refresh (Ctrl+Shift+R, or
Cmd+Shift+R on a Mac). If the app is still blank on a work machine, the
corporate network is blocking the CDN it loads React from — use
`ContractIQ_App_OFFLINE.html` from the main package instead.

**The app says "No AI endpoint configured".**
Expected until you connect Supabase. Sign in, open Settings, and paste
your Supabase project URL and anon key. See the Hosting & Deployment
Guide.

---

## What is NOT in here, deliberately

- `api/*.php` — Stripe endpoints. Hostinger only; PHP does not run here.
- `.htaccess` — Apache only; ignored by Pages.
- The four demo edition builds and the offline build — those are for
  showing people locally, not for hosting.

`supabase/` is included for reference so the schema and Edge Function
live alongside the code. Neither is served to visitors.
