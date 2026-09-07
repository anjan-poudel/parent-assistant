# Bundled instruction manuals (manifest v1)

Five short instruction manuals that teach an older person the basics of using the
most important apps on this iPhone. Content is authored for elderly readers:
one idea per step, short imperative sentences, no jargon, and every step is
available in English and Nepali (Devanagari). Back navigation is treated as a
first-class skill in every manual, with dedicated steps and images.

## Files

| file | purpose |
|---|---|
| `manifest.json` | The single source of truth consumed by the app. |
| `imageSources.md` | Download URL, source page, and license note for every image filename. |
| `images/` | Not part of this authoring deliverable; the image-fetcher downloads each file listed in `imageSources.md` into this shared folder. |

Manifest image paths are relative to the images folder, so `iphone/step-01.png`
means `images/iphone/step-01.png`.

## Content guidelines (used to write this content)

- Steps are **8-12 per manual**, numbered from 1.
- Step texts are **short, second-person, imperative**, at most **18 English words**.
  Nepali mirrors the English step 1:1 (same step count, same order).
- Every text and every annotation label carries **both `en` and `ne`**.
- An `image` is included only when a **clean, official, full-bleed screenshot**
  of the taught screen exists; otherwise the key is omitted (never fake an image).
- Every manual has **one overview image** and **at least 5 steps with images**.
- An `annotation` is included only when the highlighted element is **visible in
  the image**: label (max 4 English words) plus normalized center coordinates
  `(x, y)` in 0-1, top-left origin, tolerance about 0.05. Coordinates were
  **measured with OCR** on the actual downloaded image, not guessed; two soft
  anchors (the green dial button in `phone`, the trash button revealed by swipe
  in `messages`/`iphone`) are icon-only and were derived from the surrounding
  OCR-verified rows, so treat them as approximate. The "left edge" annotation
  in `iphone` marks the iOS swipe-back gesture zone rather than a button.
- Localization: keep Nepali polite-imperative (`गर्नुहोस्`), loanwords in
  Devanagari (`एप`, `स्क्रिन`, `कल`, `किबोर्ड`) with native words where they
  exist (`तीर` = arrow, `कुराकानी` = chat, `सन्देश` = message).

## Back-navigation coverage

Back is taught three ways: the **back arrow** (top left), the **iOS swipe from
the left edge**, and screen-specific exits (Cancel / End call / bottom Home).

| manual | back-arrow step | left-edge-swipe step | other exit steps |
|---|---|---|---|
| `iphone` | 8 (annotated), 9 (Settings example, annotated) | 10 (annotated left edge) | 5 swipe-up home, 6 Control Center close |
| `phone` | 9 (annotated) | 10 | 6 red button ends call |
| `messages` | 7 (annotated) | 8 | 10 Cancel |
| `messenger` | 7 (annotated) | 8 | 9 red button ends call |
| `youtube` | 8 (annotated) | 9 | 6-7 rotate for fullscreen and back, 10 Home tab |

The back-arrow lesson uses a real, annotated arrow from Apple's iOS screenshots
(`Settings > AutoFill & Passwords`, iOS 26) because several taught screens
(YouTube watch page, Phone app) do not display a back arrow in the available
official screenshots; the same visual is reused across manuals, as the arrow is
identical app to app.

## Steps intentionally without images

Screens that exist only on the user's own phone (not in any official clean
screenshot) are text-only steps; this is deliberate and listed per manual in
`imageSources.md` spirit — every *filename* there is used, and no step claims
an image it does not have.

- `iphone`: steps 2 (Face ID unlock), 3 (home screen), 4 (open an app),
  5 (swipe up home), 6 (Control Center) - generic screens without a clean
  official full-bleed source.
- `phone`: steps 1 (app icon), 5 (in-call Speaker), 6 (red end button),
  8 (Recents list), 10 (edge swipe).
- `messages`: steps 1 (app icon), 6 (blue send arrow), 8 (edge swipe).
- `messenger`: steps 1 (app icon), 8 (edge swipe), 9 (red end button).
- `youtube`: steps 1 (app icon), 5 (pause), 6 (rotate to fullscreen),
  7 (rotate back), 9 (edge swipe).

## Compatibility contract (extending this content, e.g. crowd-sourced)

`schemaVersion` and the stable manual `id`s are the compatibility contract:

- **Never renumber or rename** an existing manual `id` or the meaning of a step
  number - apps and future translations may key on them.
- **Add** a step only by appending a new `number` at the end of a manual, or
  add a whole new manual with a new `id`; bump `schemaVersion` only for
  breaking layout/schema changes, and keep old clients able to ignore new
  manuals they do not know.
- A new translation of an existing manual keeps every `number`, `image`,
  and annotation coordinate identical and translates only `text`, `label`,
  and `overview`.
- New images must be official and clean (prefer Apple/App Store sources,
  .png or .jpg), must be added to `imageSources.md`, and annotations must be
  measured on the actual image (top-left origin, 0-1 normalized).
