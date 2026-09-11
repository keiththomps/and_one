# AndOne marketing site

Dependency-free HTML, CSS, and a progressively enhanced copy button. No build step,
external fonts, analytics, or third-party scripts. The finding card is an illustrative
example, not a live dashboard or benchmark.

## Preview locally

From the repository root:

```sh
python3 -m http.server 8000 --directory site
```

Open http://localhost:8000. To verify GitHub Pages project-path behavior, serve the
repository root instead and visit http://localhost:8000/site/; all asset links are relative.

## Deploy

1. In the repository's **Settings → Pages → Build and deployment**, select
   **GitHub Actions** as the source.
2. Merge the site and `.github/workflows/pages.yml` into `main`.
3. The **Deploy marketing site** workflow publishes `site/` on changes to the site
   or workflow. You can also run it manually from the Actions tab on `main`.

Default URL: https://keiththomps.github.io/and_one/

For a custom domain, configure it in Settings → Pages and set the required DNS
records. The site makes no assumptions about the hostname or project prefix.

## Editing and checks

- `index.html`: content, metadata, examples, and documentation links.
- `assets/style.css`: responsive layout, local system fonts, and reduced-motion support.
- `assets/site.js`: copy-to-clipboard enhancement with manual-selection fallback.
- `assets/icon.svg`: basketball mark and favicon.

Before publishing, check narrow/mobile and desktop layouts, keyboard navigation,
FAQ disclosure controls, and copy success/failure. Core content and navigation
must work with JavaScript disabled. Keep feature claims consistent with the Ruby
implementation and linked technical docs; never present illustrative timings as
performance guarantees.
