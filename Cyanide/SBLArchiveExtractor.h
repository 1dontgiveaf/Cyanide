//
//  SBLArchiveExtractor.h
//  Cyanide
//  Adapted from https://github.com/d1y/cyanide-ios (AGPL-3.0).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The destination is owned by the extractor: failed or cancelled extraction
// removes it so callers cannot accidentally import a partial tree. It must not
// exist yet (or be an empty directory); a non-empty destination is refused.
BOOL SBLExtractArchiveToDirectory(NSURL *url, NSString *destination, NSError **error);

// `progress` may be cancelled by the caller. Work is still synchronous from
// the caller's perspective, so callers that handle user-selected documents
// should invoke this API from a background queue while retaining any
// security-scoped access until it returns.
BOOL SBLExtractArchiveToDirectoryWithProgress(NSURL *url,
                                              NSString *destination,
                                              NSProgress * _Nullable progress,
                                              NSError **error);

// Budgets shared by archive extraction and the folder imports that consume its
// output (or a picked folder directly), so one asset is bounded the same way
// whichever path it arrives by.
extern const uint64_t SBLMaxArchiveInputBytes;   // compressed archive file
extern const uint64_t SBLMaxImportTotalBytes;    // all files of one import
extern const NSUInteger SBLMaxImportFileCount;   // candidate files of one import
extern const uint64_t SBLMaxImageFileBytes;      // one image file
extern const NSUInteger SBLMaxImagePixelSide;    // pixels per side of one image

// Image preflight: a regular file (symlinks are not followed), non-empty, at
// most `maxBytes`, whose ImageIO header reports pixel dimensions within
// SBLMaxImagePixelSide. Nothing is decoded. *sizeOut receives the byte size.
BOOL SBLImageFilePassesPreflight(NSString *path, uint64_t maxBytes,
                                 uint64_t * _Nullable sizeOut);
// The same pixel check for bytes already in memory.
BOOL SBLImageDataPassesPixelPreflight(NSData *data);

NS_ASSUME_NONNULL_END
