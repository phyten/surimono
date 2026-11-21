#!/usr/bin/env python3
"""Rebuild offline from the pinned SwaTex checkout and TeX Live AMSFonts.

python build.py --output DIR --audit DIR [--format ttf] [--face Math-Italic]
Requires fontTools, numpy, scipy and Pillow. The audit records every cmap slot and the
old/new ink overlay for each accepted substitution (red old, blue new).
"""
import argparse
import csv
import functools
import logging
import re
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from fontTools import t1Lib
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.basePen import BasePen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import DecomposingRecordingPen, RecordingPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.tfmLib import TFM
from fontTools.ttLib import TTFont
from scipy.ndimage import distance_transform_edt

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'Packages/SurimonoKit'
CHECKOUT = PACKAGE / '.build/checkouts/SwaTex/Sources'
FAMILIES = {
    'Main-Regular': 'cmr10 cmsy10 cmmi10 msam10 msbm10',
    'Main-Bold': 'cmbx10 cmbsy10 cmmib10',
    'Main-Italic': 'cmti10', 'Main-BoldItalic': 'cmbxti10',
    'Math-Italic': 'cmmi10', 'Math-BoldItalic': 'cmmib10',
    'AMS-Regular': 'msam10 msbm10',
    'Caligraphic-Regular': 'cmsy10', 'Caligraphic-Bold': 'cmbsy10',
    'Fraktur-Regular': 'eufm10', 'Fraktur-Bold': 'eufb10',
    'SansSerif-Regular': 'cmss10', 'SansSerif-Italic': 'cmssi10',
    'SansSerif-Bold': 'cmssbx10', 'Typewriter-Regular': 'cmtt10',
    'Script-Regular': '',  # Formal Script is outside the AMSFonts distribution.
    **{f'Size{n}-Regular': 'cmex10' for n in range(1, 5)},
}
FAMILY_NAMES = {'AMS': 'Symbols', 'Math': 'Letters', 'Caligraphic': 'Calligraphic',
                'SansSerif': 'Sans', 'Size1': 'Size One', 'Size2': 'Size Two',
                'Size3': 'Size Three', 'Size4': 'Size Four'}
FIELDS = ['face', 'unicode', 'glyph', 'source', 'slot', 'sourceGlyph', 'dx', 'dy',
          'advance', 'sourceAdvance', 'overlap', 'reason', 'oldBounds', 'newBounds']


def winding_mask(polygons, size):
    # Type 1 contours may overlap. The interior uses the nonzero winding rule.
    winding = np.zeros((size[1], size[0]), dtype=int)
    for points in polygons:
        if len(points) < 3:
            continue
        layer = Image.new('1', size)
        ImageDraw.Draw(layer).polygon([tuple(p) for p in points], fill=1)
        xs, ys = points.T
        direction = np.sign(np.sum(xs * np.roll(ys, -1) - ys * np.roll(xs, -1)))
        winding += np.asarray(layer).astype(int) * int(direction)
    return winding != 0


class Contours(BasePen):
    """Sample both quadratic and cubic curves for the same origin-independent ink comparison."""
    def __init__(self, glyphs):
        super().__init__(glyphs)
        self.paths = []

    def _moveTo(self, pt):
        self.paths.append([np.array(pt)])

    def _lineTo(self, pt):
        self.paths[-1].append(np.array(pt))

    def _curveToOne(self, b, c, d):
        a = self.paths[-1][-1]
        for t in np.arange(1, 17) / 16:
            u = 1 - t
            self.paths[-1].append(u**3 * a + 3*u*u*t * np.array(b) + 3*u*t*t * np.array(c) + t**3 * np.array(d))

    def _qCurveToOne(self, b, c):
        a = self.paths[-1][-1]
        for t in np.arange(1, 17) / 16:
            self.paths[-1].append((1-t)**2 * a + 2*(1-t)*t * np.array(b) + t*t * np.array(c))

    def _closePath(self):
        pass

    _endPath = _closePath


class Shape:
    def __init__(self, glyphs, name):
        self.name = name
        self.glyph = glyphs[name]
        pen = BoundsPen(glyphs)
        self.glyph.draw(pen)
        self.bounds = pen.bounds
        if not self.bounds:
            return
        x, y, right, top = self.bounds
        self.center = np.array([(x + right) / 2, (y + top) / 2])
        self.size = np.array([right - x, top - y])
        outlines = Contours(glyphs)
        self.glyph.draw(outlines)
        # Comparing masks in a common tight coordinate system tolerates emboldening but
        # not reflection. Absolute EM dimensions and advance are checked separately.
        scale = 104 / np.maximum(self.size, 1)
        self.paths = [np.asarray(curve) for curve in outlines.paths]
        self.mask = winding_mask(((c - [x, y]) * scale + 2 for c in self.paths), (109, 109))
        self.distance = distance_transform_edt(~self.mask)


def texfile(name):
    return Path(subprocess.check_output(['kpsewhich', name], text=True).strip()).resolve(strict=True)


@functools.cache
def source(face):
    path = texfile(face + '.pfb')
    if 'amsfonts' not in path.parts or b'SIL Open Font License, Version 1.1' not in path.read_bytes()[:1200]:
        raise ValueError(f'Expected a licensed AMSFonts PFB: {path}')
    pfb = t1Lib.T1Font(str(path))
    tfm = TFM(str(texfile(face + '.tfm')))
    glyphs = pfb.getGlyphSet()
    shapes = []
    for slot, name in enumerate(pfb['Encoding']):
        if slot not in tfm.chars or name == '.notdef':
            continue
        shape = Shape(glyphs, name)
        if shape.bounds:
            shape.face, shape.slot = face, slot
            shape.metrics = tfm.chars[slot]
            shape.advance = shape.glyph.width
            shapes.append(shape)
    return shapes


@functools.cache
def encoded_shape(face, slot):
    return next(s for s in source(face) if s.slot == slot)


@functools.cache
def constructions():
    # Coordinates are the DVI positions in a 10 pt article, relative to the
    # math origin, in 1/1000 em. Harpoons and the bold hbar use fontmath.ltx;
    # the other commands use amsmath + amssymb (display style for Size2).
    with Path(__file__).with_name('constructions.tsv').open() as file:
        return {(r['face'], int(r['unicode'], 16)): r for r in csv.DictReader(file, delimiter='\t')}


class CompoundOutline(RecordingPen):
    def draw(self, pen):
        self.replay(pen)


def constructed_shape(face, code, old):
    recipe = constructions().get((face, code))
    if not recipe:
        return None
    drawing = CompoundOutline()
    sources = []
    components = recipe['components'].split()
    packed = code in {0x222c, 0x222d, 0x21e0, 0x21e2}
    if packed:
        # KaTeX packs these single-contour parts closer than amsmath does.
        # Recover each part's horizontal origin without scaling the CM ink.
        contours = sorted(old.paths, key=lambda path: path[:, 0].min())
        assert len(contours) == len(components)
    for i, component in enumerate(components):
        family, slot, x, y = component.split(':')
        glyph = encoded_shape(family, int(slot))
        if packed:
            assert len(glyph.paths) == 1
            xs = contours[i][:, 0]
            x = round((xs.min() + xs.max()) / 2 - glyph.center[0])
        glyph.glyph.draw(TransformPen(drawing, (1, 0, 0, 1, int(x), int(y))))
        sources.append(glyph)
    shape = Shape({recipe['command']: drawing}, recipe['command'])
    shape.faces = {g.face for g in sources}
    shape.face = '+'.join(dict.fromkeys(g.face for g in sources))
    shape.slot = '+'.join(str(g.slot) for g in sources)
    shape.metrics, shape.advance = {}, None
    return shape


def documented_shape(face, code):
    # OT1, fontmath.ltx, amssymb.sty and the TFM NEXTLARGER chains identify
    # aliases even where KaTeX made a spacing accent into a combining glyph.
    primary = FAMILIES[face].split()
    if not primary:
        return None
    source_face = primary[0]
    slot = None
    if face.startswith(('Main-', 'SansSerif-')):
        slot = {0x27: 39, 0x7e: 126, 0xb0: 23, 0x2c9: 22}.get(code)
    if face in {'Main-Regular', 'Main-Bold'}:
        bold = face == 'Main-Bold'
        if code in {0x22c5, 0x2217, 0x2a3f, 0xe020}:
            source_face = 'cmbsy10' if bold else 'cmsy10'
            slot = {0x22c5: 1, 0x2217: 3, 0x2a3f: 0x71, 0xe020: 0x36}[code]
        elif code in {0x2118, 0x20d7}:
            source_face = 'cmmib10' if bold else 'cmmi10'
            slot = 0x7d if code == 0x2118 else 0x7e
        elif code == 0x2215:
            slot = 47  # Identical to the original slash in the operators font.
        elif code == 0xa3:
            source_face, slot = ('cmbxti10' if bold else 'cmti10'), 36
    if face == 'Main-Italic' and code == 0x210f:
        source_face, slot = 'msbm10', 0x7e  # amsfonts.sty; same outline as the Main-Regular alias.
    if face == 'AMS-Regular':
        slot = {0x22c5: 5, 0x21ba: 9, 0x21bb: 8, 0x226c: 0x47,
                0x229a: 0x7d, 0x229b: 0x7e, 0x229d: 0x7f}.get(code)
    if face == 'Caligraphic-Bold' and code == ord('F'):
        slot = ord('F')
    if face == 'Typewriter-Regular':
        # The input's accent aliases at 95/125 actually contain the OT1
        # typewriter underscore/right brace. Preserve what those slots draw.
        slot = {0x2ca: 19, 0x2cb: 18, 0x2d8: 21, 0x2d9: 95, 0x2dd: 125}.get(code)
    if (face.startswith('Size') or face == 'AMS-Regular') and code in {0x2c6, 0x302, 0x2dc, 0x303}:
        tilde = code in {0x2dc, 0x303}
        level = int(face[4]) if face.startswith('Size') else 5
        if level <= 3:
            source_face, slot = 'cmex10', (101 if tilde else 98) + level - 1
        else:
            source_face, slot = 'msbm10', (93 if tilde else 91) + level - 4
    return encoded_shape(source_face, slot) if slot is not None else None


def declared_slot(face, code):
    # fontmath.ltx names these symbol/letter slots; cmex10.tfm's NEXTLARGER
    # and VARCHAR recipes identify the display integrals and mirrored repeaters.
    if face in {'Main-Regular', 'Main-Bold'} and 0x2295 <= code <= 0x2299:
        return ('cmsy10' if face == 'Main-Regular' else 'cmbsy10', 8 + code - 0x2295)
    if face.startswith('Math-') and code == 0x3d6:
        return ('cmmi10' if face == 'Math-Italic' else 'cmmib10', 0x24)
    slots = {
        'Size2-Regular': {0x222b: 0x5a, 0x222e: 0x49},
        'Size4-Regular': {0x239c: 66, 0x239f: 67, 0x23a2: 54, 0x23a5: 55},
    }
    slot = slots.get(face, {}).get(code)
    return ('cmex10', slot) if slot is not None else None


def match(old, advance, pool, primary, declared):
    scores = []
    for other in pool:
        size_error = np.abs(old.size - other.size)
        width_error = abs(advance - other.advance)
        if np.any(size_error > 42) or width_error > 60:
            continue
        overlap = np.count_nonzero(old.mask & other.mask) / np.count_nonzero(old.mask | other.mask)
        known_slot = (other.face, other.slot) == declared
        same_name = old.name == other.name and other.face == primary
        boundary_error = max(other.distance[old.mask].max(), old.distance[other.mask].max())
        if known_slot and width_error <= 5 and max(size_error) <= 35 and overlap > .48 and boundary_error < 6:
            return (other, overlap), ''
        if declared:
            continue
        if boundary_error > (13 if same_name else 8):
            continue
        if overlap < (.62 if same_name else .72):
            continue
        cost = 1 - overlap + size_error.sum() / 400 + width_error / 500
        if same_name and width_error <= 5 and np.max(size_error) <= 35:
            # The original PostScript name in the designated face disambiguates
            # homographs when both the normalized outline and advance agree.
            return (other, overlap), ''
        scores.append((cost, overlap, other))
    scores.sort(key=lambda s: s[0])
    if not scores or scores[0][0] > .44:
        return None, 'no verified outline'
    best, overlap, winner = scores[0]
    if len(scores) > 1 and scores[1][0] - best < .055:
        # Homographs (e.g. a vertical bar and a delimiter piece) cannot be identified by ink alone.
        return None, 'ambiguous outline'
    return (winner, overlap), ''


def font_names(font, family, variant, used):
    display = 'Surimono Math ' + FAMILY_NAMES.get(family, family)
    ps = display.replace(' ', '') + '-' + variant
    credits = font['name'].getDebugName(0)
    notices = set()
    for face in used:
        notice = t1Lib.T1Font(str(texfile(face + '.pfb')))['FontInfo']['Notice']
        notices.add(notice.replace(r'\050', '(').replace(r'\051', ')'))
    credits += ''.join('\n' + line for line in sorted(notices))
    style = variant.replace('BoldItalic', 'Bold Italic')
    table = font['name']
    # A standalone HTML or TikZ SVG includes the entire font program. Keep the
    # license with each font even when it is exported without app resources.
    ofl = (PACKAGE / 'Sources/SurimonoFormats/Resources/KaTeX-OFL.txt').read_text()
    license_text = table.getDebugName(13) + '\n\n' + ofl
    table.names = []
    names = {
        0: credits, 1: display, 2: style, 3: ps + ';1.000', 4: display + ' ' + style,
        5: 'Version 1.000', 6: ps, 13: license_text, 14: 'https://openfontlicense.org/',
        16: display, 17: style,
    }
    for key, value in names.items():
        table.setName(value, key, 3, 1, 0x409)
    font['OS/2'].fsType = 0
    return ps, display, credits


def write_quadratics(font, glyphs, replacements):
    for name in font.getGlyphOrder():
        glyph = font['glyf'][name]
        if name not in replacements and glyph.isComposite() and any(
                part in replacements for part in glyph.getComponentNames(font['glyf'])):
            pen = TTGlyphPen(None)
            recording = DecomposingRecordingPen(glyphs)
            glyphs[name].draw(recording)
            recording.replay(pen)
            font['glyf'][name] = pen.glyph()
    for name, (other, dx, dy) in replacements.items():
        pen = TTGlyphPen(None)
        other.glyph.draw(TransformPen(Cu2QuPen(pen, .5, reverse_direction=True), (1, 0, 0, 1, dx, dy)))
        result = pen.glyph()
        result.recalcBounds(font['glyf'])
        font['glyf'][name] = result
        font['hmtx'][name] = font['hmtx'][name][0], result.xMin


def write_cubics(font, glyphs, replacements, ps, display, credits, variant):
    strings = {}
    for name in font.getGlyphOrder():
        pen = T2CharStringPen(font['hmtx'][name][0], glyphs, roundTolerance=0)
        if name in replacements:
            other, dx, dy = replacements[name]
            other.glyph.draw(TransformPen(pen, (1, 0, 0, 1, dx, dy)))
        else:
            # BasePen elevates each original quadratic to its exact cubic.
            # Composite components decompose against the untouched input glyph set.
            glyphs[name].draw(pen)
        strings[name] = pen.getCharString()
    for tag in ['glyf', 'loca', 'cvt ', 'fpgm', 'prep', 'gasp']:
        if tag in font:
            del font[tag]
    builder = FontBuilder(font=font)
    builder.isTTF = False
    info = {
        'FamilyName': display, 'FullName': font['name'].getDebugName(4), 'Notice': credits,
        'Weight': variant, 'ItalicAngle': font['post'].italicAngle,
        'isFixedPitch': bool(font['post'].isFixedPitch),
    }
    builder.setupCFF(ps, info, strings, {})
    builder.setupMaxp()
    # Keep the original per-glyph advances, including the blank TeX glue slots.
    # A CFF font's glyph left bearing is its outline's actual xMin.
    for name, (other, dx, _) in replacements.items():
        width = font['hmtx'][name][0]
        font['hmtx'][name] = width, round(other.bounds[0] + dx)


def build(face, options, writer, mismatches, metrics):
    font = TTFont(options.inputs / ('KaTeX_' + face + '.ttf'), recalcTimestamp=False)
    if font['head'].unitsPerEm != 1000:
        raise ValueError('Expected 1000 units per em')
    family, variant = face.split('-')
    pool = [s for f in FAMILIES[face].split() for s in source(f)]
    glyphs = font.getGlyphSet()
    replacements = {}
    masks = []
    for code, name in font.getBestCmap().items():
        old = Shape(glyphs, name)
        advance = font['hmtx'][name][0]
        row = dict(face=face, unicode=f'U+{code:04X}', glyph=name, advance=advance, oldBounds=old.bounds)
        candidate = None
        composite = constructed_shape(face, code, old)
        specified = documented_shape(face, code)
        if composite:
            overlap = np.count_nonzero(old.mask & composite.mask) / np.count_nonzero(old.mask | composite.mask)
            candidate, why = (composite, overlap), 'TeX construction'
        elif specified and max(abs(specified.size - old.size)) <= 45:
            overlap = np.count_nonzero(old.mask & specified.mask) / np.count_nonzero(old.mask | specified.mask)
            if overlap >= .4:
                candidate, why = (specified, overlap), ''
            else:
                why = 'unverified documented outline'
        elif not old.bounds:
            why = 'no ink'
        elif not pool:
            why = 'no AMS source'
        elif code == 0x005F and face.startswith(('Main-', 'SansSerif-')):
            # A nearest stroke is insufficient to identify the original accent or rule.
            why = 'no corresponding single glyph'
        else:
            candidate, why = match(old, advance, pool, pool[0].face, declared_slot(face, code))
        if candidate:
            other, overlap = candidate
            # Capture actual displacements of delimiters and pieces. Ordinary glyphs retain
            # the TeX origin when the small contour-centre difference is explained by ink weight.
            shift = np.rint(old.center - other.center).astype(int)
            shift[np.abs(shift) <= 8] = 0
            dx, dy = map(int, shift)
            replacements[name] = other, dx, dy
            bounds = tuple(round(float(v + shift[i % 2]), 2) for i, v in enumerate(other.bounds))
            row.update(source=other.face, slot=other.slot, sourceGlyph=other.name, dx=dx, dy=dy,
                       sourceAdvance=other.advance, overlap=round(overlap, 4), newBounds=bounds)
            # A gallery supplements the numerical score; both masks use the same axes
            # and scale here, including the recovered offset.
            masks.append((name, old, other, dx, dy))
            values = metrics.get((face.lower().replace('-', ''), code))
            if composite:
                mismatches.writerow([face, row['unicode'], other.face, other.slot, 'TeX construction', '', ''])
            elif values:
                for index, key in [(0, 'depth'), (1, 'height'), (2, 'italic'), (4, 'width')]:
                    if abs(values[index] - other.metrics.get(key, 0)) > .002:
                        mismatches.writerow([face, row['unicode'], other.face, other.slot, key,
                                             values[index], other.metrics.get(key, 0)])
            else:
                mismatches.writerow([face, row['unicode'], other.face, other.slot, 'no engine entry', '', ''])
        row['reason'] = why
        writer.writerow(row)
    used = {face for shape, _, _ in replacements.values() for face in getattr(shape, 'faces', {shape.face})}
    ps, display, credits = font_names(font, family, variant, used)
    if options.format == 'ttf':
        write_quadratics(font, glyphs, replacements)
        ext = 'ttf'
    else:
        write_cubics(font, glyphs, replacements, ps, display, credits, variant)
        ext = 'otf'
    file = options.output / (ps + '.' + ext)
    font.save(file)
    with TTFont(file) as result, TTFont(options.inputs / ('KaTeX_' + face + '.ttf')) as original:
        assert result.getGlyphOrder() == original.getGlyphOrder()
        assert [t.cmap for t in result['cmap'].tables] == [t.cmap for t in original['cmap'].tables]
        assert all(result['hmtx'][n][0] == original['hmtx'][n][0] for n in result.getGlyphOrder())
        actual = result.getGlyphSet()
        for name, old, other, _, _ in masks:
            emitted = Shape(actual, name)
            # Reopen the binary: its embedded charstring, not just the candidate
            # path, must reproduce the source ink after conversion.
            overlap = np.count_nonzero(emitted.mask & other.mask) / np.count_nonzero(emitted.mask | other.mask)
            if options.format == 'cff' and overlap < .995:
                raise ValueError(f'{face} {name}: emitted outline differs from its AMS source')
            if max(abs(emitted.center - old.center)) > 10:
                raise ValueError(f'{face} {name}: emitted outline moved by more than .01em')

    overlay(face, masks, options.audit)
    print(f'{face}: {len(replacements)} replaced', flush=True)


def overlay(face, rows, directory):
    if not rows:
        return
    gallery = Image.new('RGB', (900, 110 * ((len(rows) + 9) // 10)), 'white')
    labels = ImageDraw.Draw(gallery)
    for index, (name, old, new, dx, dy) in enumerate(rows):
        scale = 76 / max(*old.size, *new.size, 1)
        images = []
        for shape, shift in [(old, [0, 0]), (new, [dx, dy])]:
            paths = ((c + shift - old.center) * [scale, -scale] + [45, 44] for c in shape.paths)
            images.append(winding_mask(paths, (90, 88)))
        old_ink, new_ink = images
        rgb = np.stack([~new_ink, ~(old_ink | new_ink), ~old_ink], axis=-1).astype('uint8') * 255
        x, y = index % 10 * 90, index // 10 * 110
        gallery.paste(Image.fromarray(rgb), (x, y))
        labels.text((x + 1, y + 88), name[:16], fill='black')
    gallery.save(directory / (face + '.png'))


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--output', required=True, type=Path)
    cli.add_argument('--audit', required=True, type=Path)
    cli.add_argument('--format', choices=['ttf', 'cff'], default='cff')
    cli.add_argument('--face', choices=FAMILIES)
    cli.add_argument('--inputs', type=Path, default=CHECKOUT / 'SwaTexRender/Resources/Fonts')
    cli.add_argument('--engine', type=Path, default=CHECKOUT / 'SwaTex/Font/MetricsData.swift')
    args = cli.parse_args()
    for path in [args.output,args.audit]:
        path.mkdir(exist_ok=True, parents=True)
    metrics = {}
    for key, rows in re.findall(r'static let (\w+): \[MetricsEntry\] = \[(.*?)\n    \]', args.engine.read_text(), re.S):
        for fields in re.findall(r'\(([\d., -]+)\)', rows):
            code, *values = fields.split(',')
            metrics[key.lower(), int(code)] = list(map(float, values))
    with (args.audit / 'slots.tsv').open('w') as a, (args.audit / 'tfm.tsv').open('w') as b:
        slots = csv.DictWriter(a, FIELDS, delimiter='\t')
        slots.writeheader()
        mismatch = csv.writer(b, delimiter='\t')
        mismatch.writerow(['face', 'unicode', 'source', 'slot', 'metric', 'engine', 'tfm'])
        for face in [args.face] if args.face else FAMILIES:
            build(face, args, slots, mismatch, metrics)


if __name__ == '__main__':
    logging.getLogger('fontTools.ttLib.tables._h_e_a_d').setLevel(logging.ERROR)
    main()
