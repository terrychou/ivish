//
//  ivishcallbacks.h
//  ivish
//
//  Created by Terry Chou on 1/16/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//


#ifndef ivishcallbacks_h
#define ivishcallbacks_h

#import <Foundation/Foundation.h>

typedef struct {
    NSArray<NSString *>* _Nonnull (* _Nullable available_commands)(NSString * _Nullable);
    void (* _Nullable run_ex_command)(NSString * _Nonnull);
    int (* _Nullable cells_caculator)(int);
    NSArray<NSString *>* _Nonnull (* _Nullable expand_filenames)(NSString * _Nonnull);
} ivish_callbacks_t;

#endif /* ivishcallbacks_h */
