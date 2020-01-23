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
    [[[Shell alloc] init] start];
    
    ios_exit(0);
    
    return 0;
}
