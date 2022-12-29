//
//  Quotes.swift
//  ivish
//
//  Created by Terry Chou on 2022/12/19.
//  Copyright © 2022 Boogaloo. All rights reserved.
//

import Foundation


extension String {
    /// the shell single-quoted version
    /// referred bash sh_single_quote function
    var shellSingleQuoted: String {
        var ret = ""
        if self == "'" {
            ret = "\\'"
        } else {
            ret += "'"
            for c in self {
                ret += String(c)
                if c == "'" {
                    // insert escaped single quote
                    // and start new quoted string
                    ret += "\\''"
                }
            }
            ret += "'"
        }
        
        return ret
    }
}
