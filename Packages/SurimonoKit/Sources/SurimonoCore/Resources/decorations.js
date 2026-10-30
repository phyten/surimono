// Decorates headings, list items and rules with the emoji a theme lists in --deco-emoji; the theme's CSS shows them
// through attr(data-deco). The choice is seeded by the document's text, so the screen and every print of the same
// document get the same decorations. It runs in the app's isolated world, never as the document's own script.
const emoji = getComputedStyle(document.documentElement)
  .getPropertyValue("--deco-emoji")
  .replace(/["']/g, "")
  .trim()
  .split(/\s+/)
  .filter(Boolean);
if (emoji.length > 0) {
  let seed = 2166136261;
  for (const character of document.body.textContent) {
    seed = Math.imul(seed ^ character.codePointAt(0), 16777619);
  }
  if (seed === 0) seed = 1;
  const next = () => {
    seed ^= seed << 13;
    seed ^= seed >>> 17;
    seed ^= seed << 5;
    return (seed >>> 0) / 4294967296;
  };
  const pick = () => emoji[Math.floor(next() * emoji.length)];
  for (const element of document.querySelectorAll("h1, h2, h3, li:not(.task-list-item)")) {
    element.dataset.deco = pick();
  }
  for (const element of document.querySelectorAll("hr")) {
    element.dataset.deco = Array.from({ length: 5 }, pick).join(" ");
  }
}
