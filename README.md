# EU5 Tech

**https://eu5tech.jane.berlin** — compare every Europa Universalis V country at the 1337 start: the full advance tree by Age with what each country starts with, their development, population, treasury and armies, and every unit and building by Age.

Everything is read straight from the game's own files and a freshly started 1337 save, not transcribed by hand.

## How it works

- `index.html` — the whole site: one static page, plain HTML/CSS/JS, no build step or framework.
- `extract.rb` — reads a local Europa Universalis V install plus a *melted* 1337 save and writes `eu5/data.json` and the icons the page uses. Plain Ruby; needs [ImageMagick](https://imagemagick.org) (`magick`) for the icons.
- `deploy.sh` — uploads the page and the generated files to S3, served through CloudFront. See [Deploying](#deploying).

The generated files (and the save) come from Paradox's game data, so they're **not in this repo**. Run the extractor against your own install to get them.

## Getting a start save

Which advances each country begins with isn't spelled out in the game files (it comes from the start's own setup logic), so the extractor reads it from a save. Start a new game in 1337, let it autosave, then melt the save on [pdx.tools](https://pdx.tools) (open the save, then "Melt") and put the result in `saves/` (git-ignored).

## Running it locally

```bash
ruby extract.rb                                           # default Steam path, newest save in saves/
ruby extract.rb "/path/to/Europa Universalis V/game" saves/start_melted.eu5
bundle install && bundle exec ruby -run -e httpd . -p 8000   # then open http://localhost:8000
```

Re-run `extract.rb` after a game patch. The page shows which game version its data came from in the footer.

## Deploying

Two kinds of deploy, because the game data can only be generated where the game is installed:

- **Code** (`index.html` and our own files in `eu5/`): deployed automatically by GitHub Actions on every push to `main` (`./deploy.sh --code-only`). It reuses the game data already on S3.
- **Game data** (after a game patch, or anything `extract.rb` produces): run locally:

  ```bash
  ruby extract.rb && ./deploy.sh
  ```

> [!IMPORTANT]
> **The very first deploy must be a full local one** (`ruby extract.rb && ./deploy.sh`). CI has no game data to upload, so until S3 has an `eu5/data.json`, the GitHub Action stops with an error saying so.

Local deploys use the `personal` AWS profile by default (`AWS_PROFILE` overrides it). CI logs into AWS through GitHub's OIDC, into a role that can only write to this site's bucket (defined in the site's separate infrastructure config), so no AWS keys are stored in this repo.

## Known approximations

- Country-specific advances, units and buildings depend on culture, religion or government, which the page can't evaluate on its own; it shows what a country actually starts with.
- Regiments at the start are few: most armies are raised from levies in-game.
- Countries are coloured by their map colour; there are no flags.

## Credits

Unofficial fan project. Europa Universalis V and all its data, art and text are © Paradox Interactive; this project isn't affiliated with or endorsed by Paradox. The code in this repository is MIT-licensed.
