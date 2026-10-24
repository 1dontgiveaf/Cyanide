//
//  font_patcher.m
//  Cyanide
//
//  See font_patcher.h. A minimal sfnt reader/writer: table directory, name,
//  fvar/STAT name IDs, glyf/loca (decoded and re-encoded when scaling),
//  head/hhea/hmtx/OS/2/post metrics, an empty gvar, checksums.
//

#import "font_patcher.h"
#import <math.h>

#pragma mark - Big-endian access

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static int16_t  rds16(const uint8_t *p) { return (int16_t)rd16(p); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static void wr16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xff; }
static void wr32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = (v >> 16) & 0xff; p[2] = (v >> 8) & 0xff; p[3] = v & 0xff; }
static void ap16(NSMutableData *d, uint16_t v) { uint8_t b[2]; wr16(b, v); [d appendBytes:b length:2]; }
static void ap32(NSMutableData *d, uint32_t v) { uint8_t b[4]; wr32(b, v); [d appendBytes:b length:4]; }

static int16_t clamp16(double v)
{
    long r = lround(v);
    return (int16_t)(r < INT16_MIN ? INT16_MIN : r > INT16_MAX ? INT16_MAX : r);
}

#pragma mark - Tables

// tag -> table data (copies), from a TrueType font or the first face of a
// collection. nil when it isn't one.
static NSMutableDictionary<NSString *, NSData *> *fp_tables(NSData *font, NSString **why)
{
    const uint8_t *b = font.bytes;
    size_t n = font.length;
    if (n < 12) { *why = @"Not a font file."; return nil; }
    size_t base = 0;
    if (memcmp(b, "ttcf", 4) == 0) {
        if (n < 16 || rd32(b + 8) < 1) { *why = @"Empty font collection."; return nil; }
        base = rd32(b + 12);
    }
    if (base + 12 > n) { *why = @"Damaged font."; return nil; }
    uint32_t version = rd32(b + base);
    if (memcmp(b + base, "OTTO", 4) == 0) { *why = @"This font has PostScript (CFF) outlines; only TrueType outlines can be adapted."; return nil; }
    if (version != 0x00010000 && memcmp(b + base, "true", 4) != 0) { *why = @"Not a TrueType font."; return nil; }
    uint16_t numTables = rd16(b + base + 4);
    if (base + 12 + (size_t)numTables * 16 > n) { *why = @"Damaged font."; return nil; }
    NSMutableDictionary *tables = [NSMutableDictionary dictionary];
    for (uint16_t i = 0; i < numTables; i++) {
        const uint8_t *r = b + base + 12 + i * 16;
        uint32_t off = rd32(r + 8), len = rd32(r + 12);
        if ((size_t)off + len > n) { *why = @"Damaged font (a table runs past its end)."; return nil; }
        NSString *tag = [[NSString alloc] initWithBytes:r length:4 encoding:NSASCIIStringEncoding];
        if (tag) tables[tag] = [font subdataWithRange:NSMakeRange(off, len)];
    }
    return tables;
}

BOOL fontpatch_needed(NSData *target, NSData *source)
{
    NSString *why = nil;
    NSDictionary *t = fp_tables(target, &why), *s = fp_tables(source, &why);
    return t[@"fvar"] != nil && s != nil && s[@"fvar"] == nil;
}

#pragma mark - Names

// Name IDs the weight axes and named styles use (fvar, STAT).
static NSSet<NSNumber *> *fp_axis_name_ids(NSData *fvar, NSData *stat)
{
    NSMutableSet *ids = [NSMutableSet set];
    if (fvar.length >= 16) {
        const uint8_t *f = fvar.bytes;
        uint16_t axesOff = rd16(f + 4), axisCount = rd16(f + 8), axisSize = rd16(f + 10);
        uint16_t instCount = rd16(f + 12), instSize = rd16(f + 14);
        for (uint16_t i = 0; i < axisCount; i++) {
            size_t a = axesOff + (size_t)i * axisSize;
            if (a + 20 <= fvar.length) [ids addObject:@(rd16(f + a + 18))];
        }
        size_t inst = axesOff + (size_t)axisCount * axisSize;
        for (uint16_t i = 0; i < instCount; i++) {
            size_t r = inst + (size_t)i * instSize;
            if (r + 4 > fvar.length) break;
            [ids addObject:@(rd16(f + r))];
            if (instSize >= axisCount * 4 + 6 && r + axisCount * 4 + 6 <= fvar.length) {
                uint16_t ps = rd16(f + r + 4 + axisCount * 4);
                if (ps != 0xFFFF) [ids addObject:@(ps)];
            }
        }
    }
    if (stat.length >= 18) {
        const uint8_t *s = stat.bytes;
        uint16_t axisSize = rd16(s + 4), axisCount = rd16(s + 6);
        uint32_t axesOff = rd32(s + 8);
        uint16_t valueCount = rd16(s + 12);
        uint32_t valuesOff = rd32(s + 14);
        for (uint16_t i = 0; i < axisCount; i++) {
            size_t a = axesOff + (size_t)i * axisSize;
            if (a + 6 <= stat.length) [ids addObject:@(rd16(s + a + 4))];
        }
        for (uint16_t i = 0; i < valueCount; i++) {
            size_t o = valuesOff + (size_t)i * 2;
            if (o + 2 > stat.length) break;
            size_t v = valuesOff + rd16(s + o);
            if (v + 8 <= stat.length) [ids addObject:@(rd16(s + v + 6))];   // valueNameID, all formats
        }
        if (rd16(s + 2) >= 1 && stat.length >= 20) [ids addObject:@(rd16(s + 18))];   // elided fallback
    }
    return ids;
}

typedef struct { uint16_t platform, encoding, language, nameID; } FPNameKey;

// The source's name table plus the target's records for `ids` the source
// doesn't have (lara: get_base_records). Format 0.
static NSData *fp_merged_names(NSData *sourceName, NSData *targetName, NSSet<NSNumber *> *ids)
{
    NSMutableArray<NSArray *> *records = [NSMutableArray array];   // @[ key data, string data ]
    NSMutableSet<NSData *> *seen = [NSMutableSet set];
    void (^collect)(NSData *, BOOL) = ^(NSData *table, BOOL onlyNeeded) {
        if (table.length < 6) return;
        const uint8_t *n = table.bytes;
        uint16_t count = rd16(n + 2), storage = rd16(n + 4);
        for (uint16_t i = 0; i < count; i++) {
            size_t r = 6 + (size_t)i * 12;
            if (r + 12 > table.length) break;
            FPNameKey k = { rd16(n + r), rd16(n + r + 2), rd16(n + r + 4), rd16(n + r + 6) };
            uint16_t len = rd16(n + r + 8), off = rd16(n + r + 10);
            if ((size_t)storage + off + len > table.length) continue;
            if (onlyNeeded && ![ids containsObject:@(k.nameID)]) continue;
            NSData *key = [NSData dataWithBytes:&k length:sizeof(k)];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [records addObject:@[ key, [table subdataWithRange:NSMakeRange(storage + off, len)] ]];
        }
    };
    collect(sourceName, NO);
    collect(targetName, YES);
    [records sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        FPNameKey x, y;
        [a[0] getBytes:&x length:sizeof(x)];
        [b[0] getBytes:&y length:sizeof(y)];
        uint64_t kx = (uint64_t)x.platform << 48 | (uint64_t)x.encoding << 32 | (uint64_t)x.language << 16 | x.nameID;
        uint64_t ky = (uint64_t)y.platform << 48 | (uint64_t)y.encoding << 32 | (uint64_t)y.language << 16 | y.nameID;
        return kx < ky ? NSOrderedAscending : kx > ky ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableData *out = [NSMutableData data], *strings = [NSMutableData data];
    ap16(out, 0);
    ap16(out, (uint16_t)records.count);
    ap16(out, (uint16_t)(6 + records.count * 12));
    for (NSArray *r in records) {
        FPNameKey k;
        [r[0] getBytes:&k length:sizeof(k)];
        NSData *s = r[1];
        ap16(out, k.platform); ap16(out, k.encoding); ap16(out, k.language); ap16(out, k.nameID);
        ap16(out, (uint16_t)s.length); ap16(out, (uint16_t)strings.length);
        [strings appendData:s];
    }
    [out appendData:strings];
    return out;
}

NSString *fontpatch_family_name(NSData *font)
{
    NSString *why = nil;
    NSData *name = fp_tables(font, &why)[@"name"];
    if (name.length < 6) return nil;
    const uint8_t *n = name.bytes;
    uint16_t count = rd16(n + 2), storage = rd16(n + 4);
    for (NSNumber *wanted in @[ @1, @4 ]) {
        for (uint16_t i = 0; i < count; i++) {
            size_t r = 6 + (size_t)i * 12;
            if (r + 12 > name.length) break;
            uint16_t platform = rd16(n + r), nameID = rd16(n + r + 6), len = rd16(n + r + 8), off = rd16(n + r + 10);
            if (nameID != wanted.unsignedShortValue || (size_t)storage + off + len > name.length) continue;
            NSData *bytes = [name subdataWithRange:NSMakeRange(storage + off, len)];
            NSString *s = platform == 1 ? [[NSString alloc] initWithData:bytes encoding:NSMacOSRomanStringEncoding]
                                        : [[NSString alloc] initWithData:bytes encoding:NSUTF16BigEndianStringEncoding];
            if (s.length) return s;
        }
    }
    return nil;
}

#pragma mark - Scaling

// glyf/loca scaled by `f`, instructions dropped; loca in long format.
static BOOL fp_scale_glyphs(NSData *glyf, NSData *loca, uint16_t numGlyphs, BOOL longLoca, double f,
                            NSMutableData *outGlyf, NSMutableData *outLoca, NSString **why)
{
    const uint8_t *g = glyf.bytes, *l = loca.bytes;
    size_t entry = longLoca ? 4 : 2;
    if (loca.length < ((size_t)numGlyphs + 1) * entry) { *why = @"The font's glyph index (loca) is too short."; return NO; }
    for (uint16_t gi = 0; gi < numGlyphs; gi++) {
        size_t start = longLoca ? rd32(l + gi * 4) : (size_t)rd16(l + gi * 2) * 2;
        size_t end = longLoca ? rd32(l + (gi + 1) * 4) : (size_t)rd16(l + (gi + 1) * 2) * 2;
        ap32(outLoca, (uint32_t)outGlyf.length);
        if (end <= start) continue;                                 // empty glyph
        if (end > glyf.length || end - start < 10) { *why = @"A glyph runs past the end of the glyph table."; return NO; }
        const uint8_t *p = g + start;
        size_t len = end - start;
        int16_t contours = rds16(p);
        if (contours >= 0) {
            size_t q = 10 + (size_t)contours * 2;
            if (q + 2 > len) { *why = @"A glyph is damaged."; return NO; }
            uint16_t points = contours ? rd16(p + 10 + (contours - 1) * 2) + 1 : 0;
            q += 2 + rd16(p + q);                                   // skip instructions
            uint8_t *flags = malloc(points ? points : 1);
            int32_t *xs = malloc(sizeof(int32_t) * (points ? points : 1)), *ys = malloc(sizeof(int32_t) * (points ? points : 1));
            BOOL ok = YES;
            for (uint16_t i = 0; i < points && ok; ) {
                if (q >= len) { ok = NO; break; }
                uint8_t fl = p[q++];
                flags[i++] = fl;
                if (fl & 0x08) {
                    if (q >= len) { ok = NO; break; }
                    for (uint8_t r = p[q++]; r && i < points; r--) flags[i++] = fl;
                }
            }
            int32_t v = 0;
            for (uint16_t i = 0; i < points && ok; i++) {
                if (flags[i] & 0x02) { if (q + 1 > len) { ok = NO; break; } v += (flags[i] & 0x10) ? p[q] : -p[q]; q += 1; }
                else if (!(flags[i] & 0x10)) { if (q + 2 > len) { ok = NO; break; } v += rds16(p + q); q += 2; }
                xs[i] = v;
            }
            v = 0;
            for (uint16_t i = 0; i < points && ok; i++) {
                if (flags[i] & 0x04) { if (q + 1 > len) { ok = NO; break; } v += (flags[i] & 0x20) ? p[q] : -p[q]; q += 1; }
                else if (!(flags[i] & 0x20)) { if (q + 2 > len) { ok = NO; break; } v += rds16(p + q); q += 2; }
                ys[i] = v;
            }
            if (!ok) { free(flags); free(xs); free(ys); *why = @"A glyph outline is damaged."; return NO; }
            int16_t xMin = INT16_MAX, yMin = INT16_MAX, xMax = INT16_MIN, yMax = INT16_MIN;
            for (uint16_t i = 0; i < points; i++) {
                xs[i] = clamp16(xs[i] * f); ys[i] = clamp16(ys[i] * f);
                if (xs[i] < xMin) xMin = (int16_t)xs[i]; if (xs[i] > xMax) xMax = (int16_t)xs[i];
                if (ys[i] < yMin) yMin = (int16_t)ys[i]; if (ys[i] > yMax) yMax = (int16_t)ys[i];
            }
            if (!points) xMin = yMin = xMax = yMax = 0;
            ap16(outGlyf, (uint16_t)contours);
            ap16(outGlyf, (uint16_t)xMin); ap16(outGlyf, (uint16_t)yMin); ap16(outGlyf, (uint16_t)xMax); ap16(outGlyf, (uint16_t)yMax);
            [outGlyf appendBytes:p + 10 length:(size_t)contours * 2];   // end points
            ap16(outGlyf, 0);                                           // no instructions
            NSMutableData *fl = [NSMutableData data], *xd = [NSMutableData data], *yd = [NSMutableData data];
            int32_t px = 0, py = 0;
            for (uint16_t i = 0; i < points; i++) {
                uint8_t nf = flags[i] & (0x01 | (i == 0 ? 0x40 : 0));    // on-curve, overlap hint
                int32_t dx = xs[i] - px, dy = ys[i] - py;
                px = xs[i]; py = ys[i];
                if (dx == 0) nf |= 0x10;
                else if (dx >= -255 && dx <= 255) { nf |= 0x02 | (dx > 0 ? 0x10 : 0); uint8_t b = (uint8_t)abs(dx); [xd appendBytes:&b length:1]; }
                else ap16(xd, (uint16_t)(int16_t)dx);
                if (dy == 0) nf |= 0x20;
                else if (dy >= -255 && dy <= 255) { nf |= 0x04 | (dy > 0 ? 0x20 : 0); uint8_t b = (uint8_t)abs(dy); [yd appendBytes:&b length:1]; }
                else ap16(yd, (uint16_t)(int16_t)dy);
                [fl appendBytes:&nf length:1];
            }
            [outGlyf appendData:fl]; [outGlyf appendData:xd]; [outGlyf appendData:yd];
            free(flags); free(xs); free(ys);
        } else {
            // Composite: scale the bounding box and x/y offsets; keep point
            // anchors and transforms; drop instructions.
            ap16(outGlyf, (uint16_t)contours);
            for (int i = 0; i < 4; i++) ap16(outGlyf, (uint16_t)clamp16(rds16(p + 2 + i * 2) * f));
            size_t q = 10;
            uint16_t flags;
            do {
                if (q + 4 > len) { *why = @"A composite glyph is damaged."; return NO; }
                flags = rd16(p + q);
                uint16_t glyph = rd16(p + q + 2);
                q += 4;
                BOOL words = flags & 0x0001, xy = flags & 0x0002;
                int32_t a1, a2;
                if (words) { if (q + 4 > len) { *why = @"A composite glyph is damaged."; return NO; } a1 = xy ? rds16(p + q) : rd16(p + q); a2 = xy ? rds16(p + q + 2) : rd16(p + q + 2); q += 4; }
                else { if (q + 2 > len) { *why = @"A composite glyph is damaged."; return NO; } a1 = xy ? (int8_t)p[q] : p[q]; a2 = xy ? (int8_t)p[q + 1] : p[q + 1]; q += 2; }
                size_t transform = (flags & 0x0008) ? 2 : (flags & 0x0040) ? 4 : (flags & 0x0080) ? 8 : 0;
                if (q + transform > len) { *why = @"A composite glyph is damaged."; return NO; }
                uint16_t nf = flags & ~0x0100;                       // no instructions
                if (xy) {
                    nf |= 0x0001;
                    ap16(outGlyf, nf); ap16(outGlyf, glyph);
                    ap16(outGlyf, (uint16_t)clamp16(a1 * f)); ap16(outGlyf, (uint16_t)clamp16(a2 * f));
                } else {
                    ap16(outGlyf, nf); ap16(outGlyf, glyph);
                    if (words) { ap16(outGlyf, (uint16_t)a1); ap16(outGlyf, (uint16_t)a2); }
                    else { uint8_t b[2] = { (uint8_t)a1, (uint8_t)a2 }; [outGlyf appendBytes:b length:2]; }
                }
                [outGlyf appendBytes:p + q length:transform];
                q += transform;
            } while (flags & 0x0020);
        }
        while (outGlyf.length % 4) { uint8_t z = 0; [outGlyf appendBytes:&z length:1]; }
    }
    ap32(outLoca, (uint32_t)outGlyf.length);
    return YES;
}

static void fp_scale_fields(NSMutableData *table, const size_t *offsets, size_t count, double f, BOOL unsignedFields)
{
    uint8_t *b = table.mutableBytes;
    for (size_t i = 0; i < count; i++) {
        if (offsets[i] + 2 > table.length) continue;
        if (unsignedFields) { long v = lround(rd16(b + offsets[i]) * f); wr16(b + offsets[i], (uint16_t)(v < 0 ? 0 : v > 0xFFFF ? 0xFFFF : v)); }
        else wr16(b + offsets[i], (uint16_t)clamp16(rds16(b + offsets[i]) * f));
    }
}

#pragma mark - Assembly

static uint32_t fp_checksum(const uint8_t *b, size_t len)
{
    uint32_t sum = 0;
    for (size_t i = 0; i < len; i += 4) {
        uint8_t w[4] = {0};
        memcpy(w, b + i, MIN((size_t)4, len - i));
        sum += rd32(w);
    }
    return sum;
}

static NSData *fp_assemble(NSDictionary<NSString *, NSData *> *tables)
{
    NSArray<NSString *> *tags = [tables.allKeys sortedArrayUsingSelector:@selector(compare:)];
    uint16_t n = (uint16_t)tags.count, entrySel = 0, range = 1;
    while (range * 2 <= n) { range *= 2; entrySel++; }
    NSMutableData *out = [NSMutableData data];
    ap32(out, 0x00010000); ap16(out, n); ap16(out, range * 16); ap16(out, entrySel); ap16(out, n * 16 - range * 16);
    size_t dirAt = out.length;
    [out increaseLengthBy:(size_t)n * 16];
    size_t headAt = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSData *t = tables[tags[i]];
        size_t at = out.length;
        if ([tags[i] isEqualToString:@"head"]) headAt = at;
        [out appendData:t];
        while (out.length % 4) { uint8_t z = 0; [out appendBytes:&z length:1]; }
        uint8_t *r = (uint8_t *)out.mutableBytes + dirAt + i * 16;
        memcpy(r, tags[i].UTF8String, 4);
        wr32(r + 8, (uint32_t)at); wr32(r + 12, (uint32_t)t.length);
        wr32(r + 4, fp_checksum((uint8_t *)out.mutableBytes + at, t.length));
    }
    if (headAt) {
        uint8_t *b = out.mutableBytes;
        wr32(b + headAt + 8, 0);
        wr32(b + headAt + 8, 0xB1B0AFBA - fp_checksum(b, out.length));
    }
    return out;
}

#pragma mark - Adapt

NSData *fontpatch_adapt(NSData *target, NSData *source, NSString **errorOut, NSString **noteOut)
{
    __autoreleasing NSString *e = nil;
    __autoreleasing NSString *nNote = nil;
    if (!errorOut) errorOut = &e;
    if (!noteOut) noteOut = &nNote;
    NSString *why = nil;
    NSDictionary<NSString *, NSData *> *t = fp_tables(target, &why);
    if (!t) { *errorOut = [@"System font: " stringByAppendingString:why]; return nil; }
    NSDictionary<NSString *, NSData *> *s = fp_tables(source, &why);
    if (!s) { *errorOut = why; return nil; }
    for (NSString *tag in @[ @"head", @"hhea", @"hmtx", @"maxp", @"glyf", @"loca", @"cmap" ]) {
        if (!s[tag]) { *errorOut = [NSString stringWithFormat:@"The font has no %@ table.", tag]; return nil; }
    }
    if (t[@"head"].length < 54 || s[@"head"].length < 54 || s[@"maxp"].length < 6) { *errorOut = @"Damaged font header."; return nil; }

    uint16_t targetUPM = rd16((const uint8_t *)t[@"head"].bytes + 18), sourceUPM = rd16((const uint8_t *)s[@"head"].bytes + 18);
    uint16_t numGlyphs = rd16((const uint8_t *)s[@"maxp"].bytes + 4);
    BOOL longLoca = rds16((const uint8_t *)s[@"head"].bytes + 50) == 1;
    double f = sourceUPM ? (double)targetUPM / sourceUPM : 1;
    BOOL scale = sourceUPM && targetUPM && sourceUPM != targetUPM;

    NSMutableDictionary<NSString *, NSData *> *out = [NSMutableDictionary dictionary];
    // The system font's identity.
    for (NSString *tag in @[ @"fvar", @"avar", @"STAT", @"trak", @"meta" ]) if (t[tag]) out[tag] = t[tag];
    // The new font's glyphs and metrics.
    for (NSString *tag in @[ @"cmap", @"maxp", @"OS/2", @"post", @"GSUB", @"GDEF", @"GPOS", @"gasp" ]) if (s[tag]) out[tag] = s[tag];
    if (!out[@"gasp"] && t[@"gasp"]) out[@"gasp"] = t[@"gasp"];
    out[@"name"] = fp_merged_names(s[@"name"], t[@"name"], fp_axis_name_ids(t[@"fvar"], t[@"STAT"]));

    NSMutableData *head = [s[@"head"] mutableCopy], *hhea = [s[@"hhea"] mutableCopy], *hmtx = [s[@"hmtx"] mutableCopy];
    NSMutableData *glyf = [NSMutableData data], *loca = [NSMutableData data];
    if (!fp_scale_glyphs(s[@"glyf"], s[@"loca"], numGlyphs, longLoca, scale ? f : 1, glyf, loca, &why)) { *errorOut = why; return nil; }
    wr16((uint8_t *)head.mutableBytes + 50, 1);                    // long loca
    NSMutableArray *notes = [NSMutableArray arrayWithObject:@"adapted to the system font"];
    if (scale) {
        wr16((uint8_t *)head.mutableBytes + 18, targetUPM);
        const size_t headF[] = { 36, 38, 40, 42 };
        fp_scale_fields(head, headF, 4, f, NO);
        const size_t hheaS[] = { 4, 6, 8, 12, 14, 16, 22 }, hheaU[] = { 10 };
        fp_scale_fields(hhea, hheaS, 7, f, NO);
        fp_scale_fields(hhea, hheaU, 1, f, YES);
        uint16_t longMetrics = hhea.length >= 36 ? rd16((const uint8_t *)hhea.bytes + 34) : 0;
        uint8_t *m = hmtx.mutableBytes;
        for (size_t i = 0; i < numGlyphs; i++) {
            if (i < longMetrics) {
                size_t o = i * 4;
                if (o + 4 > hmtx.length) break;
                long adv = lround(rd16(m + o) * f);
                wr16(m + o, (uint16_t)(adv < 0 ? 0 : adv > 0xFFFF ? 0xFFFF : adv));
                wr16(m + o + 2, (uint16_t)clamp16(rds16(m + o + 2) * f));
            } else {
                size_t o = (size_t)longMetrics * 4 + (i - longMetrics) * 2;
                if (o + 2 > hmtx.length) break;
                wr16(m + o, (uint16_t)clamp16(rds16(m + o) * f));
            }
        }
        if (out[@"OS/2"]) {
            NSMutableData *os2 = [out[@"OS/2"] mutableCopy];
            const size_t os2S[] = { 2, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 68, 70, 72, 86, 88 }, os2U[] = { 74, 76 };
            fp_scale_fields(os2, os2S, sizeof(os2S) / sizeof(os2S[0]), f, NO);
            fp_scale_fields(os2, os2U, 2, f, YES);
            out[@"OS/2"] = os2;
        }
        if (out[@"post"]) {
            NSMutableData *post = [out[@"post"] mutableCopy];
            const size_t postS[] = { 8, 10 };
            fp_scale_fields(post, postS, 2, f, NO);
            out[@"post"] = post;
        }
        // Kerning and positioning values are in the old units: drop them
        // rather than kern at the wrong scale.
        if (out[@"GPOS"]) { [out removeObjectForKey:@"GPOS"]; [notes addObject:@"kerning dropped"]; }
        [notes addObject:[NSString stringWithFormat:@"scaled from %u to %u units", sourceUPM, targetUPM]];
    }
    // maxp: no instructions any more.
    if (out[@"maxp"].length >= 32 && rd32(out[@"maxp"].bytes) == 0x00010000) {
        NSMutableData *maxp = [out[@"maxp"] mutableCopy];
        wr16((uint8_t *)maxp.mutableBytes + 26, 0);
        out[@"maxp"] = maxp;
    }
    out[@"head"] = head; out[@"hhea"] = hhea; out[@"hmtx"] = hmtx; out[@"glyf"] = glyf; out[@"loca"] = loca;

    // An empty gvar for the system font's axes: every weight is the new glyphs.
    if (out[@"fvar"]) {
        uint16_t axes = rd16((const uint8_t *)out[@"fvar"].bytes + 8);
        NSMutableData *gvar = [NSMutableData data];
        uint32_t dataOff = 20 + ((uint32_t)numGlyphs + 1) * 4;
        ap16(gvar, 1); ap16(gvar, 0); ap16(gvar, axes); ap16(gvar, 0);
        ap32(gvar, 20); ap16(gvar, numGlyphs); ap16(gvar, 1); ap32(gvar, dataOff);
        [gvar increaseLengthBy:((size_t)numGlyphs + 1) * 4];
        out[@"gvar"] = gvar;
    }
    NSData *font = fp_assemble(out);
    *noteOut = [notes componentsJoinedByString:@", "];
    printf("[FONTPATCH] %u glyphs, %u -> %u units, %lu tables, %lu bytes (%s)\n", numGlyphs, sourceUPM, targetUPM,
           (unsigned long)out.count, (unsigned long)font.length, (*noteOut).UTF8String);
    return font;
}
