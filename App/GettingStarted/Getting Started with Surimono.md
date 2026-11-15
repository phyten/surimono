# Getting Started with Surimono

Surimono is a Mac app for opening Markdown, PDF, image, Org, text, CSV, HTML and LaTeX files and printing them as they are. A document opens already laid out on paper, and pressing ⌘P twice prints it.

This guide is an ordinary Markdown document too: print it as a small booklet and fold it.

## What Surimono does

- **Prints what you see**: the paper in the window and the sheets on the print screen are the same pages.
- **Offers layouts**: single-sided, duplex, a saddle-stitched booklet, two pages on one sheet, and more.
- **Changes the style**: text documents take a style chosen from samples.
- **Leaves your files alone**: Surimono never changes a file it opens, nor writes files next to it.
- **Remembers each document**: your layout and style come back next time.

## Read the paper

A document opens as pages of paper that fill the window. The toolbar offers the contents, single pages (⌥⌘1) or spreads (⌥⌘2), and how the pages turn. The keys you will use most:

| Key | What it does |
| --- | --- |
| ⌘F | Find in the document |
| ⌥⌘G | Go to a page by its number |
| Double-click | Switch between zoomed in and fit to window |
| ⌘P | Open the print screen; print when on it |
| ⌘1–⌘6 | Choose a layout and open the print screen |
| Esc | Leave the print screen |

## Print it

Printing takes three steps.

1. Click the vermilion Print… button at the right end of the toolbar, or press ⌘P. The print screen opens and shows the sheets as they will come out.
2. Under Paper to Use, choose the booklet half the size of your paper: A5 Booklet for A4 paper, Half Letter Booklet for Letter paper. The buttons beside Paper to Use, such as A4 / A3 and Letter / Tabloid, switch the kind of paper.
3. Click the vermilion Print button, or press ⌘P again. The sheets go to the chosen printer without a dialog.

> [!note] The print screen is for checking
> Opening the print screen does not print anything. Look at the sheets, and if something is wrong, go back with Back to View or Esc. Choose the printer from the button that shows its name. For copies, paper trays and other printer settings, use Print with System Dialog… in the same menu.

You can check the booklet on screen before printing it. Click See It Folded on the print screen to turn the pages of the folded booklet in reading order.

## Fold the booklet

In a booklet each sheet holds four pages, so a document of $n$ pages takes $s$ sheets:

$$s = \left\lceil \frac{n}{4} \right\rceil$$

Pages that do not fill the last sheet are left blank.

| Pages in the document | Sheets | Blank pages |
| ---: | ---: | ---: |
| 8 | 2 | none |
| 10 | 3 | 2 |
| 16 | 4 | none |

The print screen shows the number of pages, blank pages and sheets. For a booklet that opens from the right, choose Right Binding under Booklet Binding in All Print Settings….

Finish the printed sheets in this order.

- [ ] Stack the sheets in the order they came out, without reordering them
- [ ] Fold the whole stack in the middle, with page 1 on the outside
- [ ] Open the center spread and staple the fold in two places, near the top and the bottom

A long-reach stapler makes this easy. With an ordinary one, staple the open stack from the inside over cardboard and bend the points over by hand.

## Change the style

Markdown, Org, text, CSV and LaTeX documents can take a style.

1. If you are on the print screen, go back with Back to View or Esc.
2. Click the style button in the toolbar, which shows a palette and the current style's name, such as Standard, or choose Document > Choose Style…. Look through Recent, Favorites, Suggested and the categories.
3. Hold the pointer over a sample to try it on the paper (on the print screen this only enlarges the sample). With the setting “Try a Style on the Paper When Pointing at It” off, or in a document that takes long to typeset, the paper does not change. Clicking a sample chooses it in every case.

Compare Styles lays up to four side by side. Change the text size with Increase Text Size (⌥⌘+) and Decrease Text Size (⌥⌘−) in the View menu.

This guide's note box is written like this:

```markdown
> [!note] The print screen is for checking
> Opening the print screen prints nothing.
```

## Add finishing touches

The strip at the bottom of the print screen adds:

- Header & Footer: page numbers or the file name on each page
- Page Breaks: a new page before each large heading
- Contents Page: a printed table of contents
- Notes: pages left for writing on

Margins and finer settings are in All Print Settings…. Export PDF (⇧⌘E) on the print screen saves the laid-out sheets as a PDF.

## When something goes wrong

If the printed sheets are not right, check these first.

### The back sides come out upside down

On the print screen, open the printer's button and choose Duplex Test Print…. Follow the screen and answer Up (same as front) or Down (upside down). The answer is kept for each printer and binding, so test a booklet (short edge) and ordinary duplex (long edge) once each.

### The pages stack in the wrong order

If the stack comes out in reverse,[^order] open All Print Settings… and, under Printer Adjustments, switch Output Order between Last Sheet First and First Sheet First. This is kept for each printer.

### Images next to the document do not show

If images next to the document are missing and the notice offers Allow Access to Folder…, click it and choose the document's folder or a folder above it. Surimono remembers the folder.

## Open your own document

- Choose File > Open… (⌘O)
- Drag files onto Surimono's Dock icon, or onto the window it shows at launch
- Open copied text with Open from Clipboard (⌘N)

Several images opened together become one image bundle; several documents become one binder. When removing documents leaves just one, Surimono asks whether to leave the binder. You can also choose Leave Binder Mode from the list’s “…” menu later. Choose whether to ask in Settings > View. Leaving restores that document’s own settings. To return a document to its first settings, choose Document > Reset Document Settings.

Help > Getting Started with Surimono opens this guide again; Help > Keys and Gestures lists the keys.

The keys in this guide are the ones Surimono starts with. You can change them in Settings > Keyboard Shortcuts, and Keys and Gestures then shows the keys you chose.

[^order]: With a printer that puts the sheets out face up, printing from the last sheet leaves them in page order when you pick them up.
