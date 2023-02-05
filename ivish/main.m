//
//  main.m
//  ivish
//
//  Created by Terry Chou on 1/9/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ios_error.h"
#import <ivish/ivish-Swift.h>


int ivish_main(int argc, char *argv[])
{
    int ret = 0;
    Shell *shell = [[Shell alloc] init];
    if (argc > 1) {
        ret = [shell runWithArgc:argc argv:argv];
    } else { // start interactive
        ret = [shell start];
    }
    ios_exit(ret);
    
    return ret;
}

int ivish_run_as_root_cmd(NSString *cmd, FILE *in_file, FILE *out_file, FILE *err_file, void *callbacks, int (^runner)(NSString *, const void *))
{
    return [Shell runRootCommand:cmd
                          inFile:in_file
                         outFile:out_file
                         errFile:err_file
                       callbacks:callbacks
                          runner:runner];
}
