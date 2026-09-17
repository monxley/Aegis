# Brand assets

The masters the shipped rasters are generated from.

## What is here

| File | What it is |
|------|------------|
| `wordmark.svg` | The SHOAL wordmark, as vector. The master for every `wordmark*.png`. |

The **mark** — the shoal of fish with one picked out in amber — has no vector
master in the repository yet; the shipped rasters were derived from supplied
artwork. Replace this file set when the vector arrives.

## One thing to know before rendering `wordmark.svg`

Its ink reaches **y = 360.59** while its `viewBox` is only **359** tall. SVG
clips to the viewBox by default, so a naive render silently shaves the bottom of
the letterforms — you get a picture either way, which is what makes it easy to
miss. Render with `overflow: visible` on a canvas taller than the viewBox, then
crop to the measured ink.

## Where the rasters go

| Path | Ground | Used by |
|------|--------|---------|
| `app/assets/logo/mark.png` | transparent | the app's dark surfaces |
| `app/assets/logo/icon.png` | transparent, inset to Android's safe zone | adaptive launcher icon *foreground* |
| `app/assets/logo/icon_legacy.png` | opaque, brand ground | legacy launcher icon, iOS, the F-Droid repo icon |
| `app/assets/brand/*` | transparent, except `mark_hero.png` | in-app brand imagery |
| `docs/assets/icon.png` | opaque | site favicon and header |
| `docs/brand/lockup.png` | opaque | the README, which GitHub renders on white in light mode |
| `docs/brand/og.png` | opaque, 1200×630 | social cards |

Anything shown on a surface we do not control — GitHub's light theme, a browser
tab strip, a social card — is **opaque, on the brand ground**. The mark is a
pale silver; on white it disappears.
