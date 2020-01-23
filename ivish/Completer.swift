//
//  Completer.swift
//  ivish
//
//  Created by Terry Chou on 1/18/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//

import Foundation


internal struct Completer {
    let helper: CompletionHelper
}

internal extension Completer {
    private typealias Worker = (String) -> [String]
    
    private func completions(with line: String,
                             allowEmptyPattern: Bool) -> Completion {
        let info = CompletionInfo(line: line)
        let worker: Worker
        switch info.type {
        case .command:
            worker = self.commands
        case .parameters:
            worker = self.parameters
        case .filename:
            worker = self.filenames
        }
        let ret: Completion
        if !info.pattern.isEmpty || allowEmptyPattern {
            ret = Completion(info: info,
                             candidates: worker(info.pattern))
        } else {
            ret = Completion(info: info, candidates: [])
        }
        
        return ret
    }
    
    private func commands(for pattern: String) -> [String] {
        return self.helper.availableCommands(pattern)
    }
    
    private func parameters(for pattern: String) -> [String] {
        return []
    }
    
    private func filenames(for pattern: String) -> [String] {
        return self.helper.filenames(pattern)
    }
    
    func hint(_ line: String) -> (String?, AnsiCode?) {
        let c = self.completions(
            with: line,
            allowEmptyPattern: false)
        var hint: String?
        if let cand = c.candidates.first {
            let len = cand.count - c.info.pattern.count
            if len >= 0 {
                hint = c.info.complete(String(cand.suffix(len)))
            }
        }
        
        return (hint, nil)
    }
    
    func complete(_ line: String) -> (Completion, String?) {
        let c = self.completions(
            with: line,
            allowEmptyPattern: true)
        var new: String?
        let pattern = c.info.pattern
        if let cp = c.candidates.commonPrefix(starter: pattern),
            cp != pattern {
            new = cp
        }
        
        return (c, new)
    }
}

internal struct CompletionHelper {
    let availableCommands: (String) -> [String]
    let filenames: (String) -> [String]
}

private extension Array where Element == String {
    func commonPrefix(starter: String) -> String? {
        // caller should ensure *starter* is a common prefix already
        guard !starter.isEmpty && self.count > 0 else { return nil }
        guard self.count > 1 else { return self[0] }
        var ret = starter[...]
        done: while true {
            if self[0].count > ret.count {
                ret = self[0][...ret.endIndex]
            } else {
                break
            }
            for s in self {
                if !s.hasPrefix(ret) {
                    ret = ret.dropLast(1)
                    break done
                }
            }
        }
        
        return String(ret)
    }
}

internal enum CompletionType {
    case command
    case parameters
    case filename
}

public struct CompletionInfo {
    let type: CompletionType
    let pattern: String
    let quoting: Character?
}

public extension CompletionInfo {
    init(line: String) {
        var pattern = ""
        var type: CompletionType = .command
        var quote: Character?
        var backslashed = false
        
        for c in line {
            if backslashed {
                // the previous is backslash
                pattern.append(c)
                backslashed = false
            } else if c == "\\" {
                backslashed = true
            } else if let q = quote {
                // within a quote
                if c == q {
                    pattern = ""
                    quote = nil
                } else {
                    pattern.append(c)
                }
            } else if c == "\"" || c == "'" {
                // start quote
                quote = c
                continue
            } else if c.isWhitespace {
                // skip whitespaces
                if !pattern.isEmpty {
                    // should change type now
                    pattern = ""
                    type = .filename
                }
                continue
            } else if c == "|" {
                type = .command
                pattern = ""
            } else if c == "-" {
                type = .parameters
                pattern = "-"
            } else {
                pattern.append(c)
            }
        }
        self.init(type: type,
                  pattern: pattern,
                  quoting: quote)
    }
    
    func complete(_ content: String) -> String {
        var ret = ""
        var backslashed = false
        for c in content {
            if backslashed {
                ret.append(c)
                backslashed = false
            } else if c == "\\" {
                ret.append(c)
                backslashed = true
            } else if c == self.quoting {
                break
            } else if c.isWhitespace {
                if self.quoting == nil {
                    // need to escape whitespace if not quoted
                    ret.append("\\")
                }
                ret.append(c)
            } else {
                ret.append(c)
            }
        }
        if let q = self.quoting {
            ret.append(q)
        }
        
        return ret
    }
}

public struct Completion {
    let info: CompletionInfo
    let candidates: [String]
}
