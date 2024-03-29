//
//  ivish.h
//  ivish
//
//  Created by Terry Chou on 1/9/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ivishcallbacks.h"

//! Project version number for ivish.
FOUNDATION_EXPORT double ivishVersionNumber;

//! Project version string for ivish.
FOUNDATION_EXPORT const unsigned char ivishVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <ivish/PublicHeader.h>

int ivish_run_as_root_cmd(NSString *cmd, FILE *in_file, FILE *out_file, FILE *err_file, void *callbacks, int (^runner)(NSString *, const void *));
