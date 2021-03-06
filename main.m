/*
 Copyright (c) 2017-2018, Sveinbjorn Thordarson <sveinbjorn@sveinbjorn.org>
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 
 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.
 
 2. Redistributions in binary form must reproduce the above copyright notice, this
 list of conditions and the following disclaimer in the documentation and/or other
 materials provided with the distribution.
 
 3. Neither the name of the copyright holder nor the names of its contributors may
 be used to endorse or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
*/

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <err.h>
#include <string.h>
#include <unistd.h>
#include <sysexits.h>
#include <getopt.h>
#include <sys/attr.h>
#include <sys/param.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>

struct packed_name_attr {
    u_int32_t               size;           // Of the remaining fields
    struct attrreference    ref;            // Offset/length of name itself
    char                    name[PATH_MAX];
};

struct packed_attr_ref {
    u_int32_t               size;           // Of the remaining fields
    struct attrreference    ref;            // Offset/length of attr itself
};

struct packed_result {
    u_int32_t           size;               // Including size field itself
    struct fsid         fs_id;
    struct fsobj_id     obj_id;
};
typedef struct packed_result packed_result;
typedef struct packed_result *packed_result_p;

#define MAX_MATCHES         10
#define MAX_EBUSY_RETRIES   5
#define DEFAULT_VOLUME      @"/"

static void start_searchfs_search(const char *volpath, const char *match_string);
static ssize_t fsgetpath_compat(char * buf, size_t buflen, fsid_t * fsid, uint64_t obj_id);
static ssize_t fsgetpath_legacy(char *buf, size_t buflen, fsid_t *fsid, uint64_t obj_id);
BOOL is_mount_path (NSString *path);
void print_usage (void);

static const char optstring[] = "v:dfeh";

static struct option long_options[] = {
    {"volume",                  required_argument,      0,  'v'},
    {"dirs-only",               no_argument,            0,  'd'},
    {"files-only",              no_argument,            0,  'f'},
    {"exact-match-only",        no_argument,            0,  'e'},
    {"help",                    no_argument,            0,  'h'},
    {0,                         0,                      0,    0}
};

static BOOL dirsOnly = NO;
static BOOL filesOnly = NO;
static BOOL exactMatchOnly = NO;

#pragma mark -

int main (int argc, const char * argv[]) {
    NSString *volumePath = DEFAULT_VOLUME;
    
    // Parse getopt
    int optch;
    int long_index = 0;
    while ((optch = getopt_long(argc, (char *const *)argv, optstring, long_options, &long_index)) != -1) {
        switch (optch) {

            case 'v':
                volumePath = [@(optarg) stringByResolvingSymlinksInPath];
                break;

            case 'd':
                dirsOnly = YES;
                break;
                
            case 'f':
                filesOnly = YES;
                break;
                
            case 'e':
                exactMatchOnly = YES;
                break;
                
            case 'h':
            default:
            {
                print_usage();
                exit(EX_OK);
            }
                break;
        }
    }

    // Verify that path is the mount path for a file system
    if (![volumePath isEqualToString:DEFAULT_VOLUME] && !is_mount_path(volumePath)) {
        fprintf(stderr, "Not a volume mount path: %s\n", [volumePath cStringUsingEncoding:NSUTF8StringEncoding]);
        print_usage();
        exit(EX_USAGE);
    }
    
    if (optind >= argc) {
        fprintf(stderr, "Missing argument\n");
        print_usage();
        exit(EX_USAGE);
    }
    
    // Do search
    const char *search_string = argv[optind];
    start_searchfs_search([volumePath cStringUsingEncoding:NSUTF8StringEncoding], search_string);
    
    return EX_OK;
}

#pragma mark -

static void start_searchfs_search (const char *volpath, const char *match_string) {
    int                     err = 0;
    int                     items_found = 0;
    int                     ebusy_count = 0;
    unsigned long           matches;
    unsigned int            search_options;
    struct fssearchblock    search_blk;
    struct attrlist         return_list;
    struct searchstate      search_state;
    struct packed_name_attr info1;
    struct packed_attr_ref  info2;
    packed_result           result_buffer[MAX_MATCHES];
    
catalogue_changed:
    items_found = 0; // Set this here in case we're completely restarting
    search_blk.searchattrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    search_blk.searchattrs.reserved = 0;
    search_blk.searchattrs.commonattr = ATTR_CMN_NAME;
    search_blk.searchattrs.volattr = 0;
    search_blk.searchattrs.dirattr = 0;
    search_blk.searchattrs.fileattr = 0;
    search_blk.searchattrs.forkattr = 0;
    
    // Set up the attributes we want for all returned matches.
    search_blk.returnattrs = &return_list;
    return_list.bitmapcount = ATTR_BIT_MAP_COUNT;
    return_list.reserved = 0;
    return_list.commonattr = ATTR_CMN_FSID | ATTR_CMN_OBJID;
    return_list.volattr = 0;
    return_list.dirattr = 0;
    return_list.fileattr = 0;
    return_list.forkattr = 0;

    // Allocate a buffer for returned matches
    search_blk.returnbuffer = result_buffer;
    search_blk.returnbuffersize = sizeof(result_buffer);
    
    // Pack the searchparams1 into a buffer
    // NOTE: A name appears only in searchparams1
    strcpy(info1.name, match_string);
    info1.ref.attr_dataoffset = sizeof(struct attrreference);
    info1.ref.attr_length = (u_int32_t)strlen(info1.name) + 1;
    info1.size = sizeof(struct attrreference) + info1.ref.attr_length;
    search_blk.searchparams1 = &info1;
    search_blk.sizeofsearchparams1 = info1.size + sizeof(u_int32_t);
    
    // Pack the searchparams2 into a buffer
    info2.size = sizeof(struct attrreference);
    info2.ref.attr_dataoffset = sizeof(struct attrreference);
    info2.ref.attr_length = 0;
    search_blk.searchparams2 = &info2;
    search_blk.sizeofsearchparams2 = sizeof(info2);
    
    // Maximum number of matches we want
    search_blk.maxmatches = MAX_MATCHES;
    
    // Maximum time to search, per call
    search_blk.timelimit.tv_sec = 1;
    search_blk.timelimit.tv_usec = 0;
    
    search_options = (SRCHFS_START | SRCHFS_MATCHPARTIALNAMES |
                         SRCHFS_MATCHFILES | SRCHFS_MATCHDIRS);
    do {
        char *my_end_ptr;
        char *my_ptr;
        
        err = searchfs(volpath, &search_blk, &matches, 0, search_options, &search_state);
        if (err == -1) {
            err = errno;
        }
        
        if ((err == 0 || err == EAGAIN) && matches > 0) {
            // Unpack the results
            my_ptr = (char *)&result_buffer[0];
            my_end_ptr = (my_ptr + sizeof(result_buffer));
            for (int i = 0; i < matches; ++i) {
                packed_result_p result_p = (packed_result_p)my_ptr;
                items_found++;
                
                // Call private SPI fsgetpath to get path string for file system object ID
                char path_buf[PATH_MAX];
                ssize_t size = fsgetpath_compat((char *)&path_buf,
                                                sizeof(path_buf),
                                                &result_p->fs_id,
                                                (uint64_t)result_p->obj_id.fid_objno |
                                                ((uint64_t)result_p->obj_id.fid_generation << 32));
                if (size > -1) {
                    printf("%s\n", path_buf);
                } else {
                    fprintf(stderr, "Unable to get path for object ID: %d", result_p->obj_id.fid_objno);
                }
                
                my_ptr = (my_ptr + result_p->size);
                if (my_ptr > my_end_ptr) {
                    break;
                }
            }
        }
        
        // EBUSY indicates catalogue change; retry a few times.
        if ((err == EBUSY) && (ebusy_count++ < MAX_EBUSY_RETRIES)) {
            //fprintf(stderr, "Busy, retrying");
            goto catalogue_changed;
        }
        if (!(err == 0 || err == EAGAIN)) {
            printf("searchfs failed with error %d - \"%s\"\n", err, strerror(err));
        }
        search_options &= ~SRCHFS_START;

    } while (err == EAGAIN);
}

#pragma mark - fsgetpath compatibility shim

// fsgetpath was introduced in macOS 10.13.  To support older systems, we use a
// compatibility shim that relies on the volfs support in older versions of the OS
// See https://forums.developer.apple.com/thread/103162

static ssize_t fsgetpath_compat (char *buf, size_t buflen, fsid_t *fsid, uint64_t obj_id) {
    if (__builtin_available(macOS 10.13, *)) {
        return fsgetpath(buf, buflen, fsid, obj_id);
    } else {
        return fsgetpath_legacy(buf, buflen, fsid, obj_id);
    }
}

static ssize_t fsgetpath_legacy (char *buf, size_t buflen, fsid_t *fsid, uint64_t obj_id) {
    char volfsPath[64];  // 8 for `/.vol//\0`, 10 for `fsid->val[0]`, 20 for `obj_id`, rounded up for paranoia
    
    snprintf(volfsPath, sizeof(volfsPath), "/.vol/%ld/%llu", (long)fsid->val[0], (unsigned long long)obj_id);
    
    struct {
        uint32_t            length;
        attrreference_t     pathRef;
        char                buffer[MAXPATHLEN];
    } __attribute__((aligned(4), packed)) attrBuf;
    
    struct attrlist attrList;
    memset(&attrList, 0, sizeof(attrList));
    attrList.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrList.commonattr = ATTR_CMN_FULLPATH;
    
    int success = getattrlist(volfsPath, &attrList, &attrBuf, sizeof(attrBuf), 0) == 0;
    if (!success) {
        return -1;
    }
    
    if (attrBuf.pathRef.attr_length > buflen) {
        errno = ENOSPC;
        return -1;
    }
    
    strlcpy(buf, ((const char *)&attrBuf.pathRef) + attrBuf.pathRef.attr_dataoffset, buflen);
    
    return attrBuf.pathRef.attr_length;
}

#pragma mark - util

BOOL is_mount_path (NSString *path) {
    NSArray *mountPaths = [[NSFileManager defaultManager] mountedVolumeURLsIncludingResourceValuesForKeys:nil options:0];
    for (NSURL *mountPathURL in mountPaths) {
        if ([path isEqualToString:[mountPathURL path]]) {
            return YES;
        }
    }

    return NO;
}

void print_usage (void) {
    fprintf(stderr, "usage: searchfs [-dfeh] [-v mount_point] search_term\n");
}

