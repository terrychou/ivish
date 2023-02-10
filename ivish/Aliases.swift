//
//  Aliases.swift
//  ivish
//
//  Created by Terry Chou on 2022/12/13.
//  Copyright © 2022 Boogaloo. All rights reserved.
//

import Foundation

final class Aliases {
    typealias Pool = [String: String]
    private var pool = Pool()
}

extension Aliases {
    /// add an alias into the pool
    ///
    /// `name`: the alias name
    /// `replacement`: the replacement text for the alias
    ///
    /// if one alias with the same name already exists,
    /// it will be overwritten.
    func add(name: String, replacement: String) {
        self.pool[name] = replacement
    }
    
    /// remove an alias from the pool
    ///
    /// `name`: the alias name to remove
    ///
    /// return `false` if no aliases with the name found
    @discardableResult
    func remove(name: String) -> Bool {
        var found = false
        if self.pool[name] != nil {
            self.pool[name] = nil
            found = true
        }
        
        return found
    }
    
    func alias(withName name: String) -> String? {
        return self.pool[name]
    }
    
    private typealias TransHistory = Set<String>
    /// translate alias with `name`
    ///
    /// another alias may appear in one replacement text
    /// the translation would go on until:
    /// 1) one replacement text without an alias found; or
    /// 2) the new alias is already in the translation history
    ///
    /// if the replacement ends with a whitespace char
    /// then try to translate the next alias if any
    ///
    /// return (replacement, shouldTranslateNextName)
    private func translate(name: String, history: inout TransHistory) -> (String, Bool) {
        var ret = name
        var shouldTransNext = false
        if !history.contains(name),
           let rep = self.alias(withName: name) {
            if history.isEmpty, let lc = rep.last, lc.isWhitespace {
                shouldTransNext = true
            }
            history.insert(name) // make it into history
            ret = self.translate(cmdline: rep, history: &history)
        }
        
        return (ret, shouldTransNext)
    }
    
    private func translate(cmdline: String, history: inout TransHistory) -> String {
        var ret = cmdline
        let (name, rest) = cmdline.bisected()
        if !name.isEmpty {
            let (replacement, shouldTransNext) = self.translate(name: name, history: &history)
            if shouldTransNext {
                // if replacement ends with a whitespace char
                // then try to parse the next name
                var nextHistory = TransHistory()
                ret = replacement + " " + self.translate(cmdline: rest, history: &nextHistory)
            } else {
                ret = replacement + rest
            }
        }
        
        return ret
    }
    
    private func translateCmdline(_ line: String) -> String? {
        var history = TransHistory()
        let translated = self.translate(cmdline: line, history: &history)
        
        return history.isEmpty ? nil : translated
    }
    
    /// translate the given command line according to the pool
    ///
    /// `cmdline`: the command line to translate
    ///
    /// return the translated result, or `nil` if no alias found
    func translate(cmdline: String) -> String? {
        let result = try! CmdLineTokenizer(line: cmdline).tokenize()
        var ret = ""
        var didTranslate = false
        let delimiters = Set(CmdLineTokenizer.Delimiter.allCases)
        result.enumerateDelimited(delimiters: delimiters) { line, delimiter, _ in
            let translated: String
            if let trans = self.translateCmdline(line) {
                didTranslate = true
                translated = trans
            } else {
                translated = line
            }
            ret += translated + (delimiter?.delimiter.str ?? "")
        }
        
        return didTranslate ? ret : nil
    }
    
    /// import aliases from another aliases pool
    func `import`(from aliases: Aliases) {
        self.pool.merge(aliases.pool, uniquingKeysWith: { $1 })
    }
}

private extension String {
    func bisected() -> (String, String) {
        let tokenizer = CmdLineTokenizer(line: self)
        let result = try! tokenizer.tokenize(count: 1)
        var left = ""
        if let tk = result.token(at: 0) {
            left = tk
        }
        let right = result.rest
        
        return (left, right)
    }
}

extension Aliases {
    static func isValidAliasName(_ name: String) -> Bool {
        return !name.contains { c in
            CharacterSet(charactersIn: "\(c)")
                .isSubset(of: .illegalAliasName)
        }
    }
    
    struct Alias {
        let name: String
        let replacement: String?
    }
    
    /// try and parse `str` as (name, replacement) pair
    /// divide the string by the first "="
    /// if the name is empty, then the whole string is treated as
    /// an alias name
    static func parseAlias(from str: String) -> Alias {
        var index = str.startIndex
        while index != str.endIndex {
            if str[index] == "=" {
                break
            }
            index = str.index(after: index)
        }
        let name: String
        var replacement: String?
        if index != str.startIndex &&
            index != str.endIndex &&
            str[index] == "=" {
            // name-replacement pair
            name = String(str[..<index])
            replacement = String(str[str.index(after: index)...])
        } else {
            // just a name
            name = str
        }
        
        return .init(name: name, replacement: replacement)
    }
    
    private func reusableAlias(name: String,
                               replacement: String,
                               cmdName: String?) -> String {
        let dashSentinel = name.first == "-" ? "-- " : ""
        let cmdName = cmdName.map { $0 + " " } ?? ""
        
        return "\(cmdName)\(dashSentinel)\(name)=\(replacement.shellSingleQuoted)"
    }
    
    /// find and return an alias line which can be reused
    /// `nil` if no alias with `name` found
    ///
    /// if a non-nil `cmdName` is given, prepend it
    ///
    /// referred bash print_alias function
    func reusableAlias(for name: String, cmdName: String?=nil) -> String? {
        var ret: String?
        if let rep = self.pool[name] {
            ret = self.reusableAlias(name: name,
                                     replacement: rep,
                                     cmdName: cmdName)
        }
        
        return ret
    }
    
    /// return all existing alias names
    func allNames() -> [String] {
        return Array(self.pool.keys)
    }
    
    /// try and add an alias with `name` and `replacement`
    /// if `name` is invalid, return the error message
    func tryAddAlias(name: String, replacement: String) -> String? {
        var ret: String?
        if Self.isValidAliasName(name) {
            self.add(name: name, replacement: replacement)
        } else {
            ret = "`\(name)': invalid alias name"
        }
        
        return ret
    }
}
