# NOTHING™

A joke landing page for a subscription that delivers nothing. Static files
only: `index.html`, the box product shot, the trailer, and a social preview.

Hosted on Cloudflare Pages as the project `subscribe-to-nothing`.

## Deploying

Automatic: `.github/workflows/nothing.yml` publishes this folder whenever it
changes on `main`, once the repository has the `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` secrets.

By hand, from this folder, with the same two values in the environment:

```sh
npx wrangler@4 pages deploy . --project-name=subscribe-to-nothing
```

If the site ends up on a domain other than `subscribe-to-nothing.pages.dev`,
update the two `og:image` / `twitter:image` URLs in `index.html` so link
previews keep showing the box.

The `.gdignore` file keeps Godot from importing anything in here.
