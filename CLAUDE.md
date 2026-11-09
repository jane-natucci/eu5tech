# Notes for Claude

Start with the README: it explains how the site works, how the data is extracted and how to deploy.

## Current task: update to EU5 1.4 (issue #1)

The live site still has **game 1.3.11** data (`generated_at` 2026-10-24, 1565 countries). Since then, the free **1.4 "Rio Salado"** update and the **Across the Pillars** Chronicle Pack (28 October 2026) added content for Castile, Morocco and Granada. The goal is to re-extract the data from 1.4 and deploy it. See https://github.com/jane-natucci/eu5tech/issues/1.

This is being done on Jane's **Windows** PC, because EU5 is installed there. Earlier extractions ran on a Mac, so expect small Windows problems (below).

### Plan

1. **Keep the old data to compare with.** Before extracting, download what's live:
   `curl -o old-data.json https://eu5tech.jane.berlin/eu5/data.json`. Keep it out of git.
2. **Make a start save.** Start a new game in 1337 on 1.4, let it autosave, melt it on https://pdx.tools ("Melt"), and put the `*_melted.eu5` file in `saves/` (git-ignored). Use the same kind of start as before: a plain new game, no mods.
3. **Extract:** `ruby extract.rb "<game dir>" saves/<file>_melted.eu5`, then `ruby flag_facts.rb` and `ruby extract_flags.rb`.
4. **Compare old and new** before deploying: number of countries, new and removed tags, new advances, units and buildings, and anything that looks empty or broken. Look closely at Castile (CAS), Morocco (MOR) and Granada (GRA). When Vic3 Tech Tree went through the same kind of update, new script conditions in the game files were silently misread, so look for warnings and for values that went missing, not only for errors.
5. **Check the page locally:** `bundle exec ruby -run -e httpd . -p 8000`, then open http://localhost:8000, with a few countries and the footer's game version.
6. **Deploy:** `./deploy.sh`, a full deploy (see the README). Then check https://eu5tech.jane.berlin.
7. **Report back to Jane:** what changed in 1.4 for the site, any countries that are new or gone, and anything that couldn't be checked. Close issue #1 when done.

`links.json` (country name → tag) is read by other sites: paradox-scores' `country_links.rb` uses it to link country names to their page. If countries were renamed or added, say so in the report.

### Windows setup and known gaps

- **Tools:** Git (Git Bash runs `deploy.sh`), Ruby 3.4.8 (see `.ruby-version`, e.g. RubyInstaller with DevKit), ImageMagick with `magick` on the PATH, the AWS CLI, and the GitHub CLI.
- **Game folder:** `extract.rb`'s `DEFAULT_GAME_DIRS` and `extract_flags.rb`'s default only know Mac paths. Pass the game folder to `extract.rb` and `flag_facts.rb` as the first argument, and set `EU5_GAME_DIR` for `extract_flags.rb`. Usually it's `C:\Program Files (x86)\Steam\steamapps\common\Europa Universalis V\game`. Adding the Windows path to the defaults is a fine small fix.
- **AWS:** `deploy.sh` uses the AWS profile `personal` unless `AWS_PROFILE` says otherwise. That profile has to be set up on the Windows PC first (`aws configure --profile personal`, with Jane's own keys). Never put keys in the repo.
- **deploy.sh** uses `md5sum` or `md5`, `find`, `xargs` and `mktemp`. Git Bash has them, but PowerShell doesn't, so run it from Git Bash.
- Saves, game data and generated files are Paradox's and stay out of git (see `.gitignore`).

## Working style

- Commit messages: a plain sentence saying what changed, for example "Extract: read the new 1.4 advance files". Push to `main` only when Jane says so; a push deploys the code part of the site.
- Jane wants short, clear answers. Say what was checked and what wasn't.
