#import <Foundation/Foundation.h>
#import <zlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#import "SBLArchiveExtractor.h"

static void require_condition(BOOL condition, NSString *message)
{
    if (condition) return;
    fprintf(stderr, "archive integrity test failed: %s\n", message.UTF8String);
    exit(1);
}

static void append16(NSMutableData *data, uint16_t value)
{
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void append32(NSMutableData *data, uint32_t value)
{
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8),
                       (uint8_t)(value >> 16), (uint8_t)(value >> 24)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static NSData *raw_deflate_stored_block(NSData *input)
{
    require_condition(input.length <= UINT16_MAX, @"fixture payload is too large");
    NSMutableData *output = [NSMutableData data];
    uint8_t finalStoredBlock = 0x01; // final block, stored (uncompressed) type
    [output appendBytes:&finalStoredBlock length:1];
    append16(output, (uint16_t)input.length);
    append16(output, (uint16_t)~input.length);
    [output appendData:input];
    return output;
}

static NSDictionary *entry(NSString *name, NSData *data, uint16_t method,
                            uint16_t flags, BOOL descriptorSignature,
                            BOOL corruptPayload)
{
    return @{@"name": name,
             @"data": data,
             @"method": @(method),
             @"flags": @(flags),
             @"descriptorSignature": @(descriptorSignature),
             @"corruptPayload": @(corruptPayload)};
}

static NSData *make_zip(NSArray<NSDictionary *> *entries)
{
    NSMutableData *zip = [NSMutableData data];
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSDictionary *spec in entries) {
        NSString *name = spec[@"name"];
        NSData *data = spec[@"data"];
        uint16_t method = [spec[@"method"] unsignedShortValue];
        uint16_t flags = [spec[@"flags"] unsignedShortValue];
        BOOL hasDescriptor = (flags & (1u << 3)) != 0;
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        NSData *compressed = method == 8 ? raw_deflate_stored_block(data) : data;
        uint32_t crc = (uint32_t)crc32(crc32(0L, Z_NULL, 0), data.bytes, (uInt)data.length);
        NSUInteger localOffset = zip.length;
        uint32_t localCRC = hasDescriptor ? 0 : crc;
        uint32_t localCompressedSize = hasDescriptor ? 0 : (uint32_t)compressed.length;
        uint32_t localUncompressedSize = hasDescriptor ? 0 : (uint32_t)data.length;

        append32(zip, 0x04034b50);
        append16(zip, 20);
        append16(zip, flags);
        append16(zip, method);
        append16(zip, 0);
        append16(zip, 0);
        append32(zip, localCRC);
        append32(zip, localCompressedSize);
        append32(zip, localUncompressedSize);
        append16(zip, (uint16_t)nameData.length);
        append16(zip, 0);
        [zip appendData:nameData];
        NSUInteger payloadOffset = zip.length;
        [zip appendData:compressed];
        if ([spec[@"corruptPayload"] boolValue]) {
            require_condition(compressed.length > 0, @"corrupt fixture has no payload");
            NSUInteger byteToCorrupt = method == 8 ? payloadOffset + 5 : payloadOffset;
            ((uint8_t *)zip.mutableBytes)[byteToCorrupt] ^= 0x20;
        }
        if (hasDescriptor) {
            if ([spec[@"descriptorSignature"] boolValue]) append32(zip, 0x08074b50);
            append32(zip, crc);
            append32(zip, (uint32_t)compressed.length);
            append32(zip, (uint32_t)data.length);
        }
        [records addObject:@{ @"nameData": nameData,
                              @"data": data,
                              @"method": @(method),
                              @"flags": @(flags),
                              @"crc": @(crc),
                              @"compressedSize": @(compressed.length),
                              @"localOffset": @(localOffset) }];
    }

    NSUInteger centralOffset = zip.length;
    for (NSDictionary *record in records) {
        NSData *nameData = record[@"nameData"];
        uint16_t method = [record[@"method"] unsignedShortValue];
        uint16_t flags = [record[@"flags"] unsignedShortValue];
        append32(zip, 0x02014b50);
        append16(zip, 20); // version made by
        append16(zip, 20); // version needed
        append16(zip, flags);
        append16(zip, method);
        append16(zip, 0);
        append16(zip, 0);
        append32(zip, [record[@"crc"] unsignedIntValue]);
        append32(zip, [record[@"compressedSize"] unsignedIntValue]);
        append32(zip, (uint32_t)[record[@"data"] length]);
        append16(zip, (uint16_t)nameData.length);
        append16(zip, 0);
        append16(zip, 0);
        append16(zip, 0);
        append16(zip, 0);
        append32(zip, 0);
        append32(zip, [record[@"localOffset"] unsignedIntValue]);
        [zip appendData:nameData];
    }
    NSUInteger centralSize = zip.length - centralOffset;
    append32(zip, 0x06054b50);
    append16(zip, 0);
    append16(zip, 0);
    append16(zip, (uint16_t)records.count);
    append16(zip, (uint16_t)records.count);
    append32(zip, (uint32_t)centralSize);
    append32(zip, (uint32_t)centralOffset);
    append16(zip, 0);
    return zip;
}

static NSString *make_temp_root(void)
{
    char template[] = "/tmp/cyanide-archive-integrity-XXXXXX";
    char *path = mkdtemp(template);
    require_condition(path != NULL, @"could not create temporary fixture directory");
    return [NSString stringWithUTF8String:path];
}

static void write_archive(NSData *archive, NSString *root, NSString *name)
{
    NSString *path = [root stringByAppendingPathComponent:name];
    require_condition([archive writeToFile:path atomically:YES],
                      [NSString stringWithFormat:@"could not write %@", name]);
}

static void expect_success(NSData *archive, NSString *root, NSString *caseName,
                           NSString *entryName, NSData *expected)
{
    NSString *archiveName = [caseName stringByAppendingString:@".zip"];
    NSString *destination = [root stringByAppendingPathComponent:
                              [caseName stringByAppendingString:@"-output"]];
    write_archive(archive, root, archiveName);
    NSError *error = nil;
    BOOL ok = SBLExtractArchiveToDirectory([NSURL fileURLWithPath:
                                            [root stringByAppendingPathComponent:archiveName]],
                                           destination, &error);
    require_condition(ok, [NSString stringWithFormat:@"%@ should extract: %@", caseName,
                            error.localizedDescription]);
    NSData *actual = [NSData dataWithContentsOfFile:
                      [destination stringByAppendingPathComponent:entryName]];
    require_condition([actual isEqualToData:expected],
                      [NSString stringWithFormat:@"%@ output mismatch", caseName]);
}

static void expect_failure(NSData *archive, NSString *root, NSString *caseName,
                           BOOL seedEmptyDestination)
{
    NSString *archiveName = [caseName stringByAppendingString:@".zip"];
    NSString *destination = [root stringByAppendingPathComponent:
                              [caseName stringByAppendingString:@"-output"]];
    write_archive(archive, root, archiveName);
    if (seedEmptyDestination) {
        require_condition([[NSFileManager defaultManager] createDirectoryAtPath:destination
                                                       withIntermediateDirectories:YES
                                                                        attributes:nil
                                                                             error:nil],
                          @"could not seed empty destination");
    }
    NSError *error = nil;
    BOOL ok = SBLExtractArchiveToDirectory([NSURL fileURLWithPath:
                                            [root stringByAppendingPathComponent:archiveName]],
                                           destination, &error);
    require_condition(!ok, [NSString stringWithFormat:@"%@ should be rejected", caseName]);
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:destination];
    require_condition(exists == seedEmptyDestination,
                      [NSString stringWithFormat:@"%@ changed the original destination", caseName]);
    if (exists) require_condition([[NSFileManager defaultManager] contentsOfDirectoryAtPath:destination error:nil].count == 0,
                                 @"failure exposed a partial extraction");
}

int main(void)
{
    @autoreleasepool {
        NSString *root = make_temp_root();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSData *storedData = [@"stored archive payload" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *deflatedData = [@"deflated archive payload with the same output size" dataUsingEncoding:NSUTF8StringEncoding];

        expect_success(make_zip(@[entry(@"stored.txt", storedData, 0, 0, NO, NO)]),
                       root, @"valid-stored", @"stored.txt", storedData);
        expect_success(make_zip(@[entry(@"deflated.txt", deflatedData, 8, 0, NO, NO)]),
                       root, @"valid-deflated", @"deflated.txt", deflatedData);

        expect_success(make_zip(@[entry(@"levels.txt", deflatedData, 8, 6, NO, NO)]),
                       root, @"deflate-level-options", @"levels.txt", deflatedData);
        expect_success(make_zip(@[entry(@"empty.txt", [NSData data], 8, 0, NO, NO)]),
                       root, @"empty-deflated", @"empty.txt", [NSData data]);
        expect_failure(make_zip(@[entry(@"not-a-file/", storedData, 0, 0, NO, NO),
                                 entry(@"valid.txt", storedData, 0, 0, NO, NO)]),
                       root, @"directory-payload", NO);

        expect_failure(make_zip(@[entry(@"stored.txt", storedData, 0, 0, NO, YES)]),
                       root, @"corrupt-stored", NO);
        expect_failure(make_zip(@[entry(@"deflated.txt", deflatedData, 8, 0, NO, YES)]),
                       root, @"corrupt-deflated", NO);
        expect_failure(make_zip(@[entry(@"encrypted.txt", storedData, 0, 1, NO, NO)]),
                       root, @"encrypted", NO);
        expect_failure(make_zip(@[entry(@"unsupported.txt", storedData, 0, 2, NO, NO)]),
                       root, @"unsupported-flags", NO);

        NSData *descriptorData = [@"ordinary descriptor payload" dataUsingEncoding:NSUTF8StringEncoding];
        expect_success(make_zip(@[entry(@"descriptor-signed.txt", descriptorData, 8,
                                         1u << 3, YES, NO)]),
                       root, @"descriptor-signed", @"descriptor-signed.txt", descriptorData);
        expect_success(make_zip(@[entry(@"descriptor-unsigned.txt", descriptorData, 0,
                                         1u << 3, NO, NO)]),
                       root, @"descriptor-unsigned", @"descriptor-unsigned.txt", descriptorData);

        NSString *utf8Name = @"utf8-✓.txt";
        NSData *utf8Data = [@"UTF-8 archive payload" dataUsingEncoding:NSUTF8StringEncoding];
        expect_success(make_zip(@[entry(utf8Name, utf8Data, 8,
                                         (1u << 3) | (1u << 11), YES, NO)]),
                       root, @"utf8-descriptor", utf8Name, utf8Data);

        NSData *firstData = [@"first entry" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *secondData = [@"second entry" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *rollbackArchive = make_zip(@[
            entry(@"first.txt", firstData, 0, 0, NO, NO),
            entry(@"second.txt", secondData, 0, 0, NO, YES),
        ]);
        expect_failure(rollbackArchive, root, @"rollback", YES);
        NSArray *leftovers = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *name in leftovers) {
            require_condition(![name hasPrefix:@".rollback-output.extract-"],
                              @"rollback left a staging directory behind");
        }

        [fm removeItemAtPath:root error:nil];
        puts("archive integrity native fixtures: PASS");
    }
    return 0;
}
