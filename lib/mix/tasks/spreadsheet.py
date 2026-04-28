"""Zero-dep XLSX writer. import spreadsheet; wb = Workbook(); ws = wb.sheet("S"); wb.save("out.xlsx")"""
import zipfile

# ── Helpers ───────────────────────────────────────────────────────────────────

def _col_letter(n):
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s

def _col_num(s):
    n = 0
    for c in s.upper():
        n = n * 26 + (ord(c) - 64)
    return n

def _ref(row, col):
    return _col_letter(col) + str(row)

def _parse_ref(ref):
    i = 0
    while i < len(ref) and ref[i].isalpha():
        i += 1
    return int(ref[i:]), _col_num(ref[:i])

def _parse_col(spec):
    if isinstance(spec, int):
        return spec, spec
    if ":" in spec:
        a, b = spec.split(":")
        return _col_num(a), _col_num(b)
    n = _col_num(spec)
    return n, n

def _xe(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

# ── Public API ────────────────────────────────────────────────────────────────

class Formula:
    def __init__(self, expr, cached=None):
        self.expr = expr
        self.cached = cached

def formula(expr, cached=None):
    return Formula(expr, cached)

# ── Style registry ────────────────────────────────────────────────────────────

class _Reg:
    def __init__(self):
        self.fonts   = [(False, False, 11, None, "Calibri")]
        self.font_i  = {(False, False, 11, None, "Calibri"): 0}
        self.fills   = [("none", None), ("gray125", None)]
        self.fill_i  = {}
        self.borders = [(None, None, None, None)]
        self.bord_i  = {(None, None, None, None): 0}
        self.cfmts   = {}
        self.next_id = 164
        self.xfs     = [(0, 0, 0, 0, None, None, False)]
        self.xf_i    = {(0, 0, 0, 0, None, None, False): 0}

    def font(self, bold=False, italic=False, size=11, color=None, name="Calibri"):
        k = (bold, italic, size, color, name)
        if k not in self.font_i:
            self.font_i[k] = len(self.fonts)
            self.fonts.append(k)
        return self.font_i[k]

    def fill(self, color=None):
        if not color:
            return 0
        if color not in self.fill_i:
            self.fill_i[color] = len(self.fills)
            self.fills.append(("solid", color))
        return self.fill_i[color]

    def border(self, all=None, top=None, bottom=None, left=None, right=None):
        k = (left or all, right or all, top or all, bottom or all)
        if k not in self.bord_i:
            self.bord_i[k] = len(self.borders)
            self.borders.append(k)
        return self.bord_i[k]

    def num_fmt(self, fmt):
        if fmt is None:          return 0
        if fmt == "int":         return 1
        if fmt == "float":       return 2
        if fmt == "number":      return 3
        if fmt == "currency":    return 4
        if fmt == "percent_int": return 9
        if fmt == "percent":     return 10
        if fmt == "date":        return 14
        if fmt == "time":        return 21
        if fmt == "text":        return 49
        if fmt not in self.cfmts:
            self.cfmts[fmt] = self.next_id
            self.next_id += 1
        return self.cfmts[fmt]

    def xf(self, nf=0, fn=0, fi=0, bi=0, ah=None, av=None, wrap=False):
        k = (nf, fn, fi, bi, ah, av, wrap)
        if k not in self.xf_i:
            self.xf_i[k] = len(self.xfs)
            self.xfs.append(k)
        return self.xf_i[k]

    def resolve(self, style, bold=False):
        thin  = self.border(all="thin")
        bfont = self.font(bold=True)

        if isinstance(style, dict):
            fn = self.font(bold=style.get("bold", bold), italic=style.get("italic", False),
                           size=style.get("size", 11), color=style.get("color"),
                           name=style.get("font", "Calibri"))
            fi = self.fill(style.get("bg"))
            bi = self.border(all=style.get("border"), top=style.get("border_top"),
                             bottom=style.get("border_bottom"))
            nf = self.num_fmt(style.get("number"))
            return self.xf(nf=nf, fn=fn, fi=fi, bi=bi,
                           ah=style.get("align"), av=style.get("valign"),
                           wrap=style.get("wrap", False))

        fn = bfont if bold else 0

        if style is None or style == "text":
            return self.xf(bi=thin, fn=fn)
        if style == "header":
            return self.xf(fn=self.font(bold=True, color="FFFFFFFF"),
                           fi=self.fill("FF2F75B6"), bi=thin)
        if style == "title":
            return self.xf(fn=self.font(bold=True, size=14), ah="center")
        if style == "bold":
            return self.xf(fn=bfont, bi=thin)
        if style == "currency":
            return self.xf(nf=4, bi=thin, fn=fn)
        if style == "number":
            return self.xf(nf=3, bi=thin, fn=fn)
        if style == "percent":
            return self.xf(nf=10, bi=thin, fn=fn)
        if style == "date":
            return self.xf(nf=14, bi=thin, fn=fn)
        if style == "link":
            return self.xf(fn=self.font(color="FF0563C1"), bi=thin)
        if style == "subtotal":
            return self.xf(nf=4, fn=bfont,
                           bi=self.border(top="medium", bottom="double"))
        return 0

    def xml(self):
        p = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
             '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">']

        if self.cfmts:
            p.append('<numFmts count="' + str(len(self.cfmts)) + '">')
            for fs, fid in self.cfmts.items():
                p.append('<numFmt numFmtId="' + str(fid) + '" formatCode="' + _xe(fs) + '"/>')
            p.append('</numFmts>')

        p.append('<fonts count="' + str(len(self.fonts)) + '">')
        for (b, it, sz, color, nm) in self.fonts:
            f = "<font>"
            if b:     f += "<b/>"
            if it:    f += "<i/>"
            f += '<sz val="' + str(sz) + '"/>'
            if color: f += '<color rgb="' + color + '"/>'
            f += '<name val="' + nm + '"/></font>'
            p.append(f)
        p.append('</fonts>')

        p.append('<fills count="' + str(len(self.fills)) + '">')
        for (pat, color) in self.fills:
            if pat == "none":
                p.append('<fill><patternFill patternType="none"/></fill>')
            elif pat == "gray125":
                p.append('<fill><patternFill patternType="gray125"/></fill>')
            else:
                p.append('<fill><patternFill patternType="solid"><fgColor rgb="' + color + '"/><bgColor indexed="64"/></patternFill></fill>')
        p.append('</fills>')

        p.append('<borders count="' + str(len(self.borders)) + '">')
        for (l, r, t, b) in self.borders:
            p.append('<border>')
            for tag, s in [("left", l), ("right", r), ("top", t), ("bottom", b)]:
                if s:
                    p.append('<' + tag + ' style="' + s + '"><color rgb="FF000000"/></' + tag + '>')
                else:
                    p.append('<' + tag + '/>')
            p.append('<diagonal/></border>')
        p.append('</borders>')

        p.append('<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>')

        p.append('<cellXfs count="' + str(len(self.xfs)) + '">')
        for (nf, fn, fi, bi, ah, av, wr) in self.xfs:
            x = ('<xf numFmtId="' + str(nf) + '" fontId="' + str(fn) +
                 '" fillId="' + str(fi) + '" borderId="' + str(bi) + '" xfId="0"')
            if nf: x += ' applyNumberFormat="1"'
            if fn: x += ' applyFont="1"'
            if fi: x += ' applyFill="1"'
            if bi: x += ' applyBorder="1"'
            if ah or av or wr:
                x += '><alignment'
                if ah: x += ' horizontal="' + ah + '"'
                if av: x += ' vertical="' + av + '"'
                if wr: x += ' wrapText="1"'
                x += '/></xf>'
            else:
                x += '/>'
            p.append(x)
        p.append('</cellXfs>')

        p.append('<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>')
        p.append('</styleSheet>')
        return ''.join(p)


# ── Cell XML ──────────────────────────────────────────────────────────────────

def _cell_xml(r, v, xf, ss_idx):
    s = ' s="' + str(xf) + '"' if xf else ''
    if isinstance(v, Formula):
        f = '<f>' + _xe(v.expr) + '</f>'
        cv = '<v>' + str(v.cached) + '</v>' if v.cached is not None else ''
        return '<c r="' + r + '"' + s + '>' + f + cv + '</c>'
    if isinstance(v, bool):
        return '<c r="' + r + '" t="b"' + s + '><v>' + ('1' if v else '0') + '</v></c>'
    if isinstance(v, (int, float)):
        return '<c r="' + r + '"' + s + '><v>' + str(v) + '</v></c>'
    if v is None:
        return '<c r="' + r + '"' + s + '/>'
    return '<c r="' + r + '" t="s"' + s + '><v>' + str(ss_idx(str(v))) + '</v></c>'


# ── Sheet ─────────────────────────────────────────────────────────────────────

class Sheet:
    def __init__(self, name, reg):
        self.name       = name
        self._reg       = reg
        self._cells     = {}
        self._widths    = {}
        self._heights   = {}
        self._merges    = []
        self._fr        = 0
        self._fc        = 0
        self._filter    = None
        self._page      = {}
        self._cur       = 1

    def freeze(self, rows=0, cols=0):
        self._fr = rows
        self._fc = cols
        return self

    def col_width(self, spec, width):
        lo, hi = _parse_col(spec)
        for c in range(lo, hi + 1):
            self._widths[c] = width
        return self

    def row_height(self, row, height):
        self._heights[row] = height
        return self

    def merge(self, ref):
        self._merges.append(ref)
        return self

    def autofilter(self, ref):
        self._filter = ref
        return self

    def page(self, orientation="portrait", fit_to=None):
        self._page = {"o": orientation, "ft": fit_to}
        return self

    def write(self, ref, value, style=None, bold=False):
        row, col = _parse_ref(ref) if isinstance(ref, str) else ref
        self._cells[(row, col)] = (value, self._reg.resolve(style, bold=bold))
        return self

    def write_row(self, values, style=None, bold=False):
        row = self._cur
        uniform = style in ("header", "title")
        for i, v in enumerate(values):
            s = style if (uniform or not isinstance(v, str)) else None
            self._cells[(row, i + 1)] = (v, self._reg.resolve(s, bold=bold))
        self._cur += 1
        return self

    def write_header(self, values):
        return self.write_row(values, style="header")

    def skip(self, n=1):
        self._cur += n
        return self

    def xml(self, ss_idx):
        p = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
             '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
             ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">']

        p.append('<sheetViews><sheetView tabSelected="1" workbookViewId="0">')
        if self._fr or self._fc:
            tl = _ref(self._fr + 1, self._fc + 1 if self._fc else 1)
            p.append('<pane ySplit="' + str(self._fr) + '"' +
                     (' xSplit="' + str(self._fc) + '"' if self._fc else '') +
                     ' topLeftCell="' + tl + '" activePane="bottomLeft" state="frozen"/>')
        p.append('</sheetView></sheetViews>')
        p.append('<sheetFormatPr defaultRowHeight="15"/>')

        if self._widths:
            p.append('<cols>')
            for c in sorted(self._widths):
                p.append('<col min="' + str(c) + '" max="' + str(c) +
                         '" width="' + str(self._widths[c]) + '" customWidth="1"/>')
            p.append('</cols>')

        rows = {}
        for (r, c), cell in self._cells.items():
            rows.setdefault(r, {})[c] = cell

        p.append('<sheetData>')
        for r in sorted(rows):
            ra = ' r="' + str(r) + '"'
            if r in self._heights:
                ra += ' ht="' + str(self._heights[r]) + '" customHeight="1"'
            p.append('<row' + ra + '>')
            for c in sorted(rows[r]):
                v, xf = rows[r][c]
                p.append(_cell_xml(_ref(r, c), v, xf, ss_idx))
            p.append('</row>')
        p.append('</sheetData>')

        if self._filter:
            p.append('<autoFilter ref="' + self._filter + '"/>')
        if self._merges:
            p.append('<mergeCells count="' + str(len(self._merges)) + '">')
            for m in self._merges:
                p.append('<mergeCell ref="' + m + '"/>')
            p.append('</mergeCells>')
        if self._page:
            pp = '<pageSetup orientation="' + self._page["o"] + '"'
            if self._page["ft"]:
                pp += ' fitToPage="1" fitToWidth="' + str(self._page["ft"]) + '" fitToHeight="0"'
            p.append(pp + '/>')

        p.append('</worksheet>')
        return ''.join(p)


# ── Workbook ──────────────────────────────────────────────────────────────────

class Workbook:
    def __init__(self):
        self._sheets = []
        self._reg    = _Reg()

    def sheet(self, name):
        ws = Sheet(name, self._reg)
        self._sheets.append(ws)
        return ws

    def save(self, path):
        ss_list = []
        ss_map  = {}
        def ss_idx(s):
            if s not in ss_map:
                ss_map[s] = len(ss_list)
                ss_list.append(s)
            return ss_map[s]

        for ws in self._sheets:
            for (r, c) in sorted(ws._cells):
                v, _ = ws._cells[(r, c)]
                if isinstance(v, str):
                    ss_idx(v)

        n = len(self._sheets)

        sheet_ct = ""
        for i in range(n):
            sheet_ct += ('<Override PartName="/xl/worksheets/sheet' + str(i + 1) + '.xml"'
                         ' ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>')

        ct = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
              '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
              '<Default Extension="xml" ContentType="application/xml"/>'
              '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
              + sheet_ct +
              '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
              '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
              '</Types>')

        root_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                     '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                     '<Relationship Id="rId1"'
                     ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"'
                     ' Target="xl/workbook.xml"/>'
                     '</Relationships>')

        sheets_el = ""
        wb_rels   = ""
        for i, ws in enumerate(self._sheets):
            rid = "rId" + str(i + 1)
            sheets_el += '<sheet name="' + _xe(ws.name) + '" sheetId="' + str(i + 1) + '" r:id="' + rid + '"/>'
            wb_rels   += ('<Relationship Id="' + rid + '"'
                          ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
                          ' Target="worksheets/sheet' + str(i + 1) + '.xml"/>')

        ss_rid  = "rId" + str(n + 1)
        sty_rid = "rId" + str(n + 2)
        wb_rels += ('<Relationship Id="' + ss_rid + '"'
                    ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"'
                    ' Target="sharedStrings.xml"/>'
                    '<Relationship Id="' + sty_rid + '"'
                    ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"'
                    ' Target="styles.xml"/>')

        workbook = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
                    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
                    '<sheets>' + sheets_el + '</sheets>'
                    '</workbook>')

        workbook_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                         '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                         + wb_rels + '</Relationships>')

        ns = len(ss_list)
        ss_parts = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
                    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
                    ' count="' + str(ns) + '" uniqueCount="' + str(ns) + '">']
        for s in ss_list:
            ss_parts.append('<si><t xml:space="preserve">' + _xe(s) + '</t></si>')
        ss_parts.append('</sst>')
        shared_strings = ''.join(ss_parts)

        with zipfile.ZipFile(path, "w") as z:
            z.writestr("[Content_Types].xml",         ct)
            z.writestr("_rels/.rels",                 root_rels)
            z.writestr("xl/workbook.xml",             workbook)
            z.writestr("xl/_rels/workbook.xml.rels",  workbook_rels)
            z.writestr("xl/sharedStrings.xml",        shared_strings)
            z.writestr("xl/styles.xml",               self._reg.xml())
            for i, ws in enumerate(self._sheets):
                z.writestr("xl/worksheets/sheet" + str(i + 1) + ".xml", ws.xml(ss_idx))
