//
//  CmdLineTokenizer.swift
//  ivish
//
//  Created by Terry Chou on 2022/12/15.
//  Copyright © 2022 Boogaloo. All rights reserved.
//

import Foundation

final class CmdLineTokenizer {
    typealias Element = String.Element
    typealias Handler = (Element, CmdLineTokenizer) throws -> Bool
    let line: String
    var rest = ""
    var accum: String?
    var escaping: Escaping?
    var tokenStartAt: String.Index?
    var tokenEndAt: String.Index?
    var soFarDelimitedTokens = 0
    var delimiters = [DelimiterInfo]()
    var results: [Token]?
    var isSubescaping = false
    var unfinishedEscape: EscapeInfo?

    init(line: String) {
        self.line = line
    }
}

extension CmdLineTokenizer {
    enum Escaping: String {
        case singleQuote = "'"
        case doubleQuote = "\""
        case backslash = "\\"

        var handler: Handler {
            let ret: Handler
            switch self {
            case .singleQuote: ret = self.singleQuoteHandle
            case .doubleQuote: ret = self.doubleQuoteHandle
            case .backslash: ret = self.backslashHandle
            }

            return ret
        }

        private func singleQuoteHandle(
            elem: Element,
            tokenizer: CmdLineTokenizer) throws -> Bool {
            var done = false
            if elem == "'" {
                // done escaping
                done = true
            } else {
                tokenizer.accum?.append(elem)
            }

            return done
        }

        private func doubleQuoteHandle(
            elem: Element,
            tokenizer: CmdLineTokenizer) throws -> Bool {
            var done = false
            if elem == "\"" || elem == "\\" {
                if tokenizer.isSubescaping {
                    // escaped double quote
                    tokenizer.accum!.append(elem)
                    tokenizer.isSubescaping = false
                } else {
                    if elem == "\"" {
                        // done escaping
                        done = true
                    } else {
                        // mark escaping for next char
                        tokenizer.isSubescaping = true
                    }
                }
            } else {
                if tokenizer.isSubescaping {
                    tokenizer.accum?.append("\\")
                    tokenizer.isSubescaping = false
                }
                tokenizer.accum?.append(elem)
            }

            return done
        }

        private func backslashHandle(
            elem: Element,
            tokenizer: CmdLineTokenizer) throws -> Bool {
            tokenizer.accum?.append(elem)

            return true
        }
    }

//    enum ParseError: Error, Equatable {
//        case unfinished(String)
//    }

    private func harvest() {
        guard let a = self.accum else { return }
        let token = Token(startAt: self.tokenStartAt!,
                          endAt: self.tokenEndAt!,
                          content: a)
        self.results?.append(token)
        self.accum = nil
    }

    private func run(count: Int) throws {
        self.results = []
        var index = self.line.startIndex
        var escapeAt = self.line.startIndex
        var lastTokenStartAt: String.Index?
        while index != self.line.endIndex {
            let element = self.line[index]
            var startEscaping = false
            let wasNotToken = self.accum == nil
            try self.handle(element: element,
                            at: index,
                            startEscaping: &startEscaping)
            let isTokenStart = wasNotToken && self.accum != nil
            if startEscaping {
                escapeAt = index
            }
            if isTokenStart {
                lastTokenStartAt = index
                self.tokenStartAt = index
            }
            // record possible token end index
            if self.accum != nil {
                self.tokenEndAt = index
            }
            if count > 0 && self.results!.count == count {
                // collected enough
                break
            }
            index = self.line.index(after: index)
        }
        var restStartAt: String.Index?
        if let esc = self.escaping {
            // unfinished token
            self.unfinishedEscape = .init(startAt: escapeAt,
                                          escape: esc)
            restStartAt = lastTokenStartAt
        } else {
            self.harvest()
        }
        self.rest = String(self.line[(restStartAt ?? index)...])
    }

    private func prepareAccum() {
        if self.accum == nil {
            self.accum = ""
        }
    }
    
    private func collectDelimiter(_ delimiter: Delimiter, at index: String.Index) {
        // also do harvest
        self.harvest()
        // collect delimiter, do not treat delimiter as tokens
        let upper = self.results?.count ?? 0
        let info = DelimiterInfo(delimiter: delimiter,
                                 index: index,
                                 soFarTokensRange: self.soFarDelimitedTokens..<upper)
        self.soFarDelimitedTokens = upper
        self.delimiters.append(info)
    }

    private func handle(element: Element,
                        at index: String.Index,
                        startEscaping: inout Bool) throws {
        if let esc = self.escaping {
            // escaping
            if try esc.handler(element, self) {
                // done current escaping
                self.escaping = nil
            }
        } else if let newEsc = Escaping(rawValue: String(element)) {
            // start a new escaping
            self.escaping = newEsc
            startEscaping = true
            self.prepareAccum()
        } else if element.isWhitespace {
            // skip whitespace and harvest possible token
            self.harvest()
        } else if let delimiter = Delimiter(rawValue: element) {
            self.collectDelimiter(delimiter, at: index)
        } else {
            // accumulate others
            self.prepareAccum()
            self.accum!.append(element)
        }
    }
    
    struct EscapeInfo {
        let startAt: String.Index
        let escape: Escaping
    }
    
    struct Result {
        let line: String
        let tokens: [Token]
        let delimiters: [DelimiterInfo]
        let rest: String
        let unfinished: EscapeInfo?
    }

    /// tokenize the line provided in initialization
    /// if a greater-than-zero `count` is given
    /// only try to tokenize the first `count` tokens
    func tokenize(count: Int=0) throws -> Result {
        try self.run(count: count)
        
        return .init(line: self.line,
                     tokens: self.results ?? [],
                     delimiters: self.delimiters,
                     rest: self.rest,
                     unfinished: self.unfinishedEscape)
    }
}

extension CmdLineTokenizer {
    struct Token {
        let startAt: String.Index
        let endAt: String.Index
        let content: String
    }
    
    enum Delimiter: Character {
        case pipe = "|"    // pipe
        case command = ";" // command separator
        
        var str: String {
            return String(self.rawValue)
        }
    }
    
    struct DelimiterInfo {
        let delimiter: Delimiter
        let index: String.Index
        let soFarTokensRange: Range<Int>
        
        var leftIsEmpty: Bool {
            return self.soFarTokensRange.isEmpty
        }
    }
}

extension CmdLineTokenizer.Result {
    func token(at index: Int) -> String? {
        var ret: String?
        if self.tokens.indices.contains(index) {
            ret = self.tokens[index].content
        }
        
        return ret
    }
    
    typealias DelimiterInfo = CmdLineTokenizer.DelimiterInfo
    typealias SubcmdLineEnumerator = (String, DelimiterInfo?, inout Bool) -> Void
    func enumerateSubcmdLines(_ enumerator: SubcmdLineEnumerator) {
        var stop = false
        var startIndex = self.line.startIndex
        for del in self.delimiters {
            stop = false
            let subcmdLine = String(self.line[startIndex..<del.index])
            startIndex = self.line.index(after: del.index)
            enumerator(subcmdLine, del, &stop)
            if stop {
                break
            }
        }
        if !stop {
            let lastSubcmdLine = String(self.line[startIndex...])
            enumerator(lastSubcmdLine, nil, &stop)
        }
    }
    
    /// enumerate sublines that are delimited by any of `delimiters`
    typealias Delimiter = CmdLineTokenizer.Delimiter
    /// delimited enumerator: (subline, delimiter info, stop enumerating)
    typealias DelimitedEnumerator = (String, DelimiterInfo?, inout Bool) throws -> Void
    func enumerateDelimited(delimiters: Set<Delimiter>,
                            enumerator: DelimitedEnumerator) rethrows {
        var stop = false
        var startIndex = self.line.startIndex
        for del in self.delimiters {
            if !delimiters.contains(del.delimiter) {
                continue
            }
            stop = false
            let subLine = String(self.line[startIndex..<del.index])
            startIndex = self.line.index(after: del.index)
            try enumerator(subLine, del, &stop)
            if stop {
                break
            }
        }
        if !stop {
            let lastSubLine = String(self.line[startIndex...])
            try enumerator(lastSubLine, nil, &stop)
        }
    }
    
    private func tokensRange(for delimiter: DelimiterInfo?) -> Range<Int> {
        let range: Range<Int>
        if let d = delimiter {
            range = d.soFarTokensRange
        } else {
            var startIdx = 0
            let endIdx = self.tokens.count
            if let ld = self.delimiters.last {
                startIdx = ld.soFarTokensRange.upperBound
            }
            range = startIdx..<endIdx
        }
        
        return range
    }
    
    /// pick the tokens delimited by the given `delimiter`
    /// if `delimiter` is nil, it means the last part
    typealias Token = CmdLineTokenizer.Token
    func tokens(for delimiter: DelimiterInfo?) -> [Token] {
        return Array(self.tokens[self.tokensRange(for: delimiter)])
    }
    
    /// validate existing delimiters
    ///
    /// return invalid ones
    func invalidDelimiters() -> [DelimiterInfo] {
        var ret = [DelimiterInfo]()
        let count = self.delimiters.count
        if count > 1 {
            for idx in 0..<(count - 1) {
                let current = self.delimiters[idx]
                let next = self.delimiters[idx + 1]
                if !self.validate(delimiter: current, next: next) {
                    ret.append(current)
                }
            }
        }
        // handle the possible last one
        if let ld = self.delimiters.last,
           !self.validate(delimiter: ld, next: nil) {
            ret.append(ld)
        }
        
        return ret
    }
    
    private typealias DelimiterValidator = (DelimiterInfo, DelimiterInfo?) -> Bool
    private func validate(delimiter: DelimiterInfo, next: DelimiterInfo?) -> Bool {
        let validator: DelimiterValidator
        switch delimiter.delimiter {
        case .pipe: validator = self.validatePipe(_:next:)
        case .command: validator = self.validateCommandSeparator(_:next:)
        }
        
        return validator(delimiter, next)
    }
    
    private func validatePipe(_ delimiter: DelimiterInfo,
                              next: DelimiterInfo?) -> Bool {
        // a pipe is invalid if any of its sides is empty (no tokens)
        var ret = false
        if !delimiter.leftIsEmpty { // left is not empty
            if let nd = next { // has next delimiter
                if !nd.leftIsEmpty {
                    // right is not empty
                    ret = true
                }
            } else if !delimiter.soFarTokensRange.contains(self.tokens.count - 1) {
                // this is the last delimiter, and right is not empty
                ret = true
            }
        }
        
        return ret
    }
    
    private func validateCommandSeparator(_ delimiter: DelimiterInfo,
                                          next: DelimiterInfo?) -> Bool {
        // a command separator is invalid if its left is empty
        var ret = false
        if !delimiter.leftIsEmpty {
            ret = true
        }
        
        return ret
    }
}
