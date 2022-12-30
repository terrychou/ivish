//
//  Env.swift
//  ivish
//
//  Created by Terry Chou on 2022/12/20.
//  Copyright © 2022 Boogaloo. All rights reserved.
//

import Foundation


extension String {
    /// env variable name for color value (0-255)
    /// for displaying the hint for unfinished quote
    static let envUnfinishedQuoteHintColor = "UNFINISHED_QUOTE_HINT_COLOR"
    /// for displaying the hint for invalid pipe delimiter
    static let envInvalidPipeDelimiter = "INVALID_PIPE_DELIMITER_HINT_COLOR"
    /// for displaying the hint for invalid command separator
    static let envInvalidCommandSeparator = "INVALID_COMMAND_SEPARATOR_HINT_COLOR"
}

extension String {
    /// get the value of the env variable with `self` as name
    ///
    /// return `nil` if no env variable with the name not found
    func getEnvValue() -> String? {
        return getenv(self).map {
            .init(cString: $0)
        } ?? Env.defaultEnvValues[self]
    }
    
    /// set the `value` to the env variable with `self` as name
    ///
    /// if `value` is `nil`, unset the related env variable;
    /// otherwise, set the value
    ///
    /// when set, if an env variable already exists, whether to
    /// update its value depends on `overwrite`
    ///
    /// return true if the env variable successfully set or unset
    func setEnvValue(_ value: String?, overwrite: Bool=true) -> Bool {
        let ret: Int32
        if let v = value {
            ret = setenv(self, v, overwrite ? 1 : 0)
        } else {
            ret = unsetenv(self)
        }
        
        return ret == 0
    }
    
    /// get the integer value of the env variable with `self` as
    /// name
    ///
    /// return `nil` if the env not found or its value is not
    /// a valid integer
    func getEnvIntValue() -> Int? {
        return self.getEnvValue().flatMap(Int.init)
    }
}

struct Env {
    /// get the env value for `name`, or its default value
    static func getValue(for name: String) -> String? {
        return name.getEnvValue()
    }
    
    static func getIntValue(for name: String) -> Int? {
        return name.getEnvIntValue()
    }
    
    static func setValue(_ value: String?, for name: String, overwrite: Bool=true) -> Bool {
        return name.setEnvValue(value, overwrite: overwrite)
    }
}

extension Env {
    static let defaultEnvValues: [String: String] = [
        .envUnfinishedQuoteHintColor: "178",
        .envInvalidPipeDelimiter: "178",
        .envInvalidCommandSeparator: "178",
    ]
}
