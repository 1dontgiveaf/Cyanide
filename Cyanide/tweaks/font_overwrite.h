//
//  font_overwrite.h
//  Cyanide
//
//  Settings → Lara → Font Overwrite. Idea from lara by rooootdev: replace a
//  system font in memory (the file cache), so apps loading it after a respring
//  get another font; the sealed system volume itself never changes and a
//  reboot brings the original back. lara makes its read-only mapping of the
//  font writable by patching the VM map entry's protection; Cyanide instead
//  maps the file's own VM object a second time, writable, through the same
//  path App Decrypt and RemoteCall use (vm_map_object_range).
//

#import <Foundation/Foundation.h>
#import <stdbool.h>

// Test, before any font: flips the last byte of a rarely used font in the
// file cache, reads it back through a fresh descriptor and restores it right
// away. Shows whether this device allows the write at all. Needs kernel
// access. *result: what happened, for the screen.
bool fontow_selftest(NSString **result);
