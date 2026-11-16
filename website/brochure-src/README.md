# AI tax filing brochure (source)

`brochure.html` is the OpsAPI-branded A4 brochure published at
`/brochures/opsapi-ai-tax-filing-scenarios.pdf`. It uses the thumbnails `t0.jpg`–`t6.jpg`,
QR codes `qr_<youtube id>.svg` and the logos in this folder.

`thumbnail-landlord.html` (with `shot180.png`) is the 1280×720 thumbnail for scenario 01,
published at `/img/ai-tax-filing/opsapi-landlord-learns-from-last-year.jpg`.

Render with Playwright (Chromium), from any folder where `playwright` is installed:

```js
// PDF
await page.goto('file://' + abs('brochure.html'), { waitUntil: 'networkidle' });
await page.evaluate(() => document.fonts.ready);
await page.pdf({ path: 'opsapi-ai-tax-filing-scenarios.pdf', format: 'A4', printBackground: true, preferCSSPageSize: true });
// Thumbnail: viewport 1280×720, page.screenshot(), then scale to 960×540 JPEG.
```

Not part of the website build.
