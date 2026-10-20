//
//  FileBrowserViewController.h
//  Cyanide
//
//  Filesystem browser, read-only until changes are enabled with its lock
//  button. Works outside the app container once the sandbox is lifted
//  (settings_unlock_filesystem_async); still bound by Unix permissions, since
//  the app runs as mobile.
//

#import <UIKit/UIKit.h>
#include <sys/stat.h>

// Whether the user has enabled changes (lock button) for this app launch.
BOOL filebrowser_write_enabled(void);
// Share sheet (AirDrop, Mail, Files …) for a COPY of a file in a per-share
// temp folder, never the original. `preloaded` shares those bytes instead of
// reading `path`. `source` anchors the popover (bar item or view). Up to 64 MB.
// `finished` runs on main once the copy is ready or failed.
void filebrowser_share_file(UIViewController *presenter, NSString *path, BOOL viaRoot, NSData *preloaded,
                            id source, void (^finished)(void));
// Call after any accepted change on disk, so open folders refresh.
void filebrowser_note_filesystem_changed(void);
// Serial queue for every file change (saves included), in request order.
dispatch_queue_t filebrowser_file_queue(void);

// Identity of an opened file (fstat on the descriptor that was read).
typedef struct {
    BOOL valid;
    dev_t dev;
    ino_t ino;
    off_t size;
    struct timespec mtime;
} FBFileIdentity;
FBFileIdentity filebrowser_identity_fd(int fd);

// Reads fd to EOF (max maxBytes). nil on any read error — never a partial
// read passed off as the whole file.
NSData *filebrowser_read_fd(int fd, NSUInteger maxBytes, BOOL *truncated, int *errOut);

// Conflict-checked save over the file opened as `expected` with contents
// `loaded`; backs up the current contents first and restores them if the
// write fails. Runs file I/O: call off the main thread.
// FBSaveUncertain: the new bytes were written but the result could not be
// verified (post-write read/stat failed); the backup is kept and `message`
// names it. Do not treat it as saved, and do not offer a blind overwrite.
typedef NS_ENUM(NSInteger, FBSaveResult) { FBSaveOK, FBSaveConflict, FBSaveFailed, FBSaveUncertain };
FBSaveResult filebrowser_save(NSString *path, NSData *data, FBFileIdentity expected, NSData *loaded,
                              BOOL force, FBFileIdentity *newIdentity, NSString **message);

// Opens a regular file (never a FIFO/device/socket) for reading; -1 otherwise.
int filebrowser_open_regular(NSString *path);

@interface FileBrowserViewController : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end
